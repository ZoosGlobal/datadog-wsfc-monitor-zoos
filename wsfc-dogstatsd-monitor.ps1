#Requires -Version 5.1
<#
.SYNOPSIS
    WSFC Health Monitor - Collects Windows Server Failover Cluster health metrics
    and submits them as gauges to the Datadog DogStatsD listener every 60 seconds.

.DESCRIPTION
    Monitors the following WSFC aspects:
      * Cluster overall health           -> wsfc.cluster.health
      * Cluster node health              -> wsfc.node.health / wsfc.node.state
      * Quorum type, state, witness      -> wsfc.quorum.witness.health (+ tags)
      * Cluster network health           -> wsfc.network.health / wsfc.network.state
      * Cluster network interface health -> wsfc.network_interface.health / wsfc.network_interface.state

    Prerequisites on the Windows node:
      1. Failover Clustering feature installed:
            Install-WindowsFeature -Name Failover-Clustering -IncludeManagementTools
      2. Failover Clustering PowerShell tools (RSAT):
            Install-WindowsFeature -Name RSAT-Clustering-PowerShell
      3. Datadog Agent running with DogStatsD enabled (default port 8125)
      4. Script run as Local Administrator or account with WMI + Cluster read access

.PARAMETER DogStatsDHost
    IP or hostname where the Datadog Agent DogStatsD listener is running.
    Default: 127.0.0.1

.PARAMETER DogStatsDPort
    UDP port of the DogStatsD listener.
    Default: 8125

.PARAMETER ComputerName
    Optional remote cluster node to query. If omitted, queries the local node.

.PARAMETER RunOnce
    Execute a single collection cycle and exit (useful for testing/debugging).

.EXAMPLE
    .\wsfc-dogstatsd-monitor.ps1                          # run continuously
    .\wsfc-dogstatsd-monitor.ps1 -RunOnce -Verbose        # test once
    .\wsfc-dogstatsd-monitor.ps1 -ComputerName NODE02     # remote node
#>

[CmdletBinding()]
param(
    [string] $DogStatsDHost = '127.0.0.1',
    [int]    $DogStatsDPort = 8125,
    [string] $ComputerName  = '',
    [switch] $RunOnce
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# =============================================================================
# SECTION 0 - Pre-Flight Checks
# -----------------------------------------------------------------------------
# Validates required Windows features before starting the collection loop.
# Exits with actionable error messages if prerequisites are missing.
# =============================================================================

function Test-Prerequisites {
    $pass = $true
    Write-Host "`n[Pre-Flight] Checking prerequisites..." -ForegroundColor Cyan

    # Check 1 - ROOT\MSCluster WMI namespace
    try {
        $null = Get-CimInstance -Namespace ROOT\MSCluster `
                                -ClassName  MSCluster_Cluster `
                                -ErrorAction Stop |
                Select-Object -First 1
        Write-Host "  [OK] ROOT\MSCluster WMI namespace is available." -ForegroundColor Green
    }
    catch {
        Write-Host "  [FAIL] ROOT\MSCluster WMI namespace not found." -ForegroundColor Red
        Write-Host "         Fix: Install-WindowsFeature -Name Failover-Clustering -IncludeManagementTools" -ForegroundColor Yellow
        $pass = $false
    }

    # Check 2 - FailoverClusters PowerShell module
    if (Get-Module -ListAvailable -Name FailoverClusters) {
        Write-Host "  [OK] FailoverClusters PowerShell module is available." -ForegroundColor Green
    }
    else {
        Write-Host "  [FAIL] FailoverClusters PowerShell module not found." -ForegroundColor Red
        Write-Host "         Fix: Install-WindowsFeature -Name RSAT-Clustering-PowerShell" -ForegroundColor Yellow
        $pass = $false
    }

    # Check 3 - Cluster Service running
    $svc = Get-Service -Name ClusSvc -ErrorAction SilentlyContinue
    if ($null -eq $svc) {
        Write-Host "  [FAIL] Cluster Service (ClusSvc) not found - node may not be a cluster member." -ForegroundColor Red
        $pass = $false
    }
    elseif ($svc.Status -ne 'Running') {
        Write-Host "  [WARN] Cluster Service (ClusSvc) is NOT running (Status: $($svc.Status))." -ForegroundColor Yellow
        Write-Host "         Fix: Start-Service ClusSvc" -ForegroundColor White
        $pass = $false
    }
    else {
        Write-Host "  [OK] Cluster Service (ClusSvc) is running." -ForegroundColor Green
    }

    Write-Host ""
    return $pass
}

# =============================================================================
# SECTION 1 - DogStatsD UDP Helper
# -----------------------------------------------------------------------------
# Creates ONE persistent UDP socket at startup (reused every 60s cycle).
#
# NOTE: Parameter is $Hostname (NOT $Host).
#       $Host is a reserved PowerShell automatic variable and cannot be
#       used as a parameter name — it causes "read-only or constant" error.
#
# Wire format: <metric.name>:<value>|g|#tag1:val1,tag2:val2
# =============================================================================

function Initialize-DogStatsDClient {
    param(
        [string] $Hostname,
        [int]    $Port
    )
    $Script:UdpClient         = [System.Net.Sockets.UdpClient]::new()
    $Script:DogStatsDEndpoint = [System.Net.IPEndPoint]::new(
        [System.Net.IPAddress]::Parse($Hostname), $Port
    )
    Write-Host "[WSFC Monitor] DogStatsD target: ${Hostname}:${Port}" -ForegroundColor Cyan
}

function Send-Metric {
    param(
        [Parameter(Mandatory)][string]    $Name,
        [Parameter(Mandatory)][double]    $Value,
        [Parameter()]        [hashtable] $Tags = @{}
    )

    $tagSegment = ''
    if ($Tags.Count -gt 0) {
        $tagParts = foreach ($kv in $Tags.GetEnumerator()) {
            $k = ($kv.Key   -replace '[^a-zA-Z0-9_\-./]', '_').ToLower()
            $v = ($kv.Value -replace '[^a-zA-Z0-9_\-./]', '_').ToLower()
            "${k}:${v}"
        }
        $tagSegment = '|#' + ($tagParts -join ',')
    }

    $payload = "${Name}:${Value}|g${tagSegment}"
    $bytes   = [System.Text.Encoding]::UTF8.GetBytes($payload)

    try {
        $Script:UdpClient.Send($bytes, $bytes.Length, $Script:DogStatsDEndpoint) | Out-Null
        Write-Verbose "  >> $payload"
    }
    catch {
        Write-Warning "[Send-Metric] Failed to send '${Name}': $($_.Exception.Message)"
    }
}

# =============================================================================
# SECTION 2 - State Code Lookup Maps
# -----------------------------------------------------------------------------
# NODE STATES       0=Up | 1=Down | 2=Paused | 3=Joining
# RESOURCE STATES   3=Online | 4=Offline | 128=Failed | ...
# NETWORK STATES    0=Down | 1=PartiallyUp | 2=Up | 3=Unreachable
# NIC STATES        0=Unknown | 1=Unavailable | 2=Failed | 3=Unreachable | 4=Up
# =============================================================================

$NodeStateMap    = @{ 0='up'; 1='down'; 2='paused'; 3='joining' }

$ResStateMap     = @{
    0='unknown';   1='inherited';         2='initializing'
    3='online';    4='offline';           128='failed'
    129='pending'; 130='offline_pending'; 131='online_pending'
}

$NetworkStateMap = @{ 0='down'; 1='partially_up'; 2='up'; 3='unreachable' }

$NicStateMap     = @{ 0='unknown'; 1='unavailable'; 2='failed'; 3='unreachable'; 4='up' }

# =============================================================================
# SECTION 3 - Data Collection: Cluster, Nodes, Quorum  (WMI / CIM)
# -----------------------------------------------------------------------------
# FIX: IsCoreGroup property is not present on all Windows Server versions.
#      Now uses a three-level fallback to identify the Core Cluster Group:
#        1. Try IsCoreGroup property (WS2016+)
#        2. Try GroupType -eq 1 (CoreCluster enum value)
#        3. Fall back to name match: group named "Cluster Group" (default name)
# =============================================================================

function Get-ClusterCimData {
    param([string] $ComputerName = '')

    $cimSession = $null
    $cimArgs    = @{}

    try {
        if ($ComputerName -and $ComputerName -ne '') {
            $cimSession         = New-CimSession -ComputerName $ComputerName -ErrorAction Stop
            $cimArgs.CimSession = $cimSession
        }

        # Query 1 - Cluster name + quorum type
        $cluster = Get-CimInstance -Namespace ROOT\MSCluster `
                                   -ClassName  MSCluster_Cluster @cimArgs |
                   Select-Object -First 1 Name, QuorumType, QuorumTypeValue

        if (-not $cluster) {
            Write-Warning '[Get-ClusterCimData] No cluster found on this node.'
            return $null
        }

        # Query 2 - All nodes and their states
        $nodes = Get-CimInstance -Namespace ROOT\MSCluster `
                                 -ClassName  MSCluster_Node @cimArgs

        # Query 3 - Resource groups (to identify Core Cluster Group)
        $groups = Get-CimInstance -Namespace ROOT\MSCluster `
                                  -ClassName  MSCluster_ResourceGroup @cimArgs

        # Query 4 - All resources (to find quorum witness resource)
        $resources = Get-CimInstance -Namespace ROOT\MSCluster `
                                     -ClassName  MSCluster_Resource @cimArgs |
                     Select-Object Name, ResourceType, State, OwnerGroup, OwnerNode

        # Derived - Cluster is Up if at least one node is Up(0) or Joining(3)
        $clusterIsUp = [bool]($nodes | Where-Object { $_.State -in @(0, 3) })

        # ── Witness detection ────────────────────────────────────────────────
        $witness = switch -Wildcard ($cluster.QuorumType) {
            '*File Share*' {
                $resources | Where-Object { $_.ResourceType -like '*File Share Witness*' } |
                Select-Object -First 1
            }
            '*Disk*' {
                $resources | Where-Object {
                    $_.ResourceType -like '*Physical Disk*' -and
                    ($_.OwnerGroup -like '*Cluster*' -or $_.OwnerGroup -like '*Core*')
                } | Select-Object -First 1
            }
            '*Cloud*' {
                $resources | Where-Object { $_.ResourceType -like '*Cloud Witness*' } |
                Select-Object -First 1
            }
            default {
                $resources | Where-Object { $_.ResourceType -like '*Witness*' } |
                Select-Object -First 1
            }
        }

        $wState = 'none'; $wType = 'none'; $wName = 'none'; $wOwner = 'none'
        if ($null -ne $witness) {
            $wCode  = [int]$witness.State
            $wState = if ($ResStateMap.ContainsKey($wCode)) { $ResStateMap[$wCode] } else { 'unknown' }
            $wType  = ($witness.ResourceType -replace '\s+','_').ToLower()
            $wName  = $witness.Name -replace '[^a-zA-Z0-9_\-]','_'
            $wOwner = if ($witness.OwnerNode) {
                ($witness.OwnerNode -replace '[^a-zA-Z0-9_\-]','_').ToLower()
            } else { 'none' }
        }

        # ── Core Cluster Group detection (three-level fallback) ──────────────
        #
        # Level 1: IsCoreGroup property (available on WS2016+)
        #   - Most reliable when available
        #
        # Level 2: GroupType -eq 1
        #   - GroupType 1 = CoreCluster in MSCluster_ResourceGroup
        #   - Available on older Windows Server versions
        #
        # Level 3: Name match
        #   - Default name of Core Group is always "Cluster Group"
        #   - Fallback for environments where neither property exists
        #
        $coreGroup = $null

        # Level 1 - try IsCoreGroup
        try {
            $coreGroup = $groups | Where-Object { $_.IsCoreGroup -eq $true } |
                         Select-Object -First 1
        }
        catch {
            Write-Verbose '[Get-ClusterCimData] IsCoreGroup property not available, trying GroupType.'
        }

        # Level 2 - try GroupType
        if ($null -eq $coreGroup) {
            try {
                $coreGroup = $groups | Where-Object { [int]$_.GroupType -eq 1 } |
                             Select-Object -First 1
            }
            catch {
                Write-Verbose '[Get-ClusterCimData] GroupType property not available, falling back to name match.'
            }
        }

        # Level 3 - name-based fallback
        if ($null -eq $coreGroup) {
            $coreGroup = $groups | Where-Object {
                $_.Name -like '*Cluster Group*' -or $_.Name -like '*Core*'
            } | Select-Object -First 1
        }

        $coreGroupState = 'not_found'
        if ($null -ne $coreGroup) {
            $cgCode         = [int]$coreGroup.State
            $coreGroupState = if ($ResStateMap.ContainsKey($cgCode)) { $ResStateMap[$cgCode] } else { 'unknown' }
        }

        return [pscustomobject]@{
            ClusterName     = $cluster.Name
            ClusterIsUp     = $clusterIsUp
            QuorumType      = ($cluster.QuorumType -replace '\s+','_').ToLower()
            QuorumTypeValue = [int]$cluster.QuorumTypeValue
            WitnessState    = $wState
            WitnessType     = $wType
            WitnessName     = $wName
            WitnessOwner    = $wOwner
            CoreGroupState  = $coreGroupState
            NodesUp         = ($nodes | Where-Object { $_.State -eq 0 }).Count
            NodesDown       = ($nodes | Where-Object { $_.State -eq 1 }).Count
            NodesPaused     = ($nodes | Where-Object { $_.State -eq 2 }).Count
            Nodes           = $nodes
        }
    }
    catch {
        Write-Warning "[Get-ClusterCimData] $($_.Exception.Message)"
        return $null
    }
    finally {
        if ($cimSession) { $cimSession | Remove-CimSession -ErrorAction SilentlyContinue }
    }
}

# =============================================================================
# SECTION 4 - Data Collection: Networks & Interfaces  (FailoverClusters module)
# -----------------------------------------------------------------------------
# FIX 1: Get-ClusterNetworkInterface pipeline crash
#   On some Windows Server / cluster versions, accessing $_.Node.Name and
#   $_.Network.Name inside ForEach-Object throws "property Name not found"
#   which stops the entire pipeline with "The pipeline has been stopped."
#   Fix: Use a safe helper function (Get-PropertyValue) that handles all cases:
#     - Object with .Name property  (newer versions)
#     - Plain string value           (older versions)
#     - Null / missing               (graceful fallback)
#
# FIX 2: Cluster name resolution
#   Get-Cluster returns a Cluster object. Wrapping in try/catch and using
#   multiple fallback property names for safety.
# =============================================================================

# Safe property reader - handles object, string, and missing property cases
function Get-PropertyValue {
    param(
        [object] $Obj,
        [string[]] $PropertyNames,   # try these property names in order
        [string] $Fallback = 'unknown'
    )
    foreach ($prop in $PropertyNames) {
        try {
            $val = $Obj.$prop
            if ($null -ne $val -and "$val" -ne '') {
                return "$val"
            }
        }
        catch { <# property doesn't exist on this object type, try next #> }
    }
    return $Fallback
}

function Get-ClusterNetworkData {
    param([string] $ComputerName = '')

    try {
        Import-Module FailoverClusters -ErrorAction Stop

        $clusterArgs = @{}
        if ($ComputerName -and $ComputerName -ne '') { $clusterArgs.Cluster = $ComputerName }

        # Get cluster name safely
        $clusterObj  = Get-Cluster @clusterArgs -ErrorAction Stop | Select-Object -First 1
        $clusterName = Get-PropertyValue -Obj $clusterObj -PropertyNames 'Name' -Fallback 'unknown-cluster'

        # ── Network segments ──────────────────────────────────────────────────
        $networks = Get-ClusterNetwork @clusterArgs -ErrorAction SilentlyContinue |
                    ForEach-Object {
                        $stateInt = try { [int]$_.State } catch { -1 }
                        [pscustomobject]@{
                            Name       = [string]$_.Name
                            StateCode  = $stateInt
                            StateLabel = if ($NetworkStateMap.ContainsKey($stateInt)) { $NetworkStateMap[$stateInt] } else { 'unknown' }
                            Role       = try { ($_.Role).ToString().ToLower() } catch { 'unknown' }
                            Metric     = try { [int]$_.Metric } catch { 0 }
                        }
                    }

        # ── Network interfaces ────────────────────────────────────────────────
        # FIX: .Node and .Network can be either:
        #   (a) An embedded cluster object with a .Name property  → use .Node.Name
        #   (b) A plain string                                    → use directly
        # Get-PropertyValue handles both cases safely without crashing the pipeline.
        $interfaces = Get-ClusterNetworkInterface @clusterArgs -ErrorAction SilentlyContinue |
                      ForEach-Object {
                          $stateInt = try { [int]$_.State } catch { -1 }

                          # Resolve node name - try .Node.Name (object) then .Node (string)
                          $nodeName = try {
                              $n = $_.Node
                              if ($n -is [string]) { $n }
                              else { Get-PropertyValue -Obj $n -PropertyNames 'Name' -Fallback 'unknown' }
                          } catch { 'unknown' }

                          # Resolve network name - try .Network.Name (object) then .Network (string)
                          $networkName = try {
                              $nw = $_.Network
                              if ($nw -is [string]) { $nw }
                              else { Get-PropertyValue -Obj $nw -PropertyNames 'Name' -Fallback 'unknown' }
                          } catch { 'unknown' }

                          [pscustomobject]@{
                              Name       = [string]$_.Name
                              Node       = $nodeName
                              Network    = $networkName
                              Adapter    = try { [string]$_.Adapter } catch { 'unknown' }
                              StateCode  = $stateInt
                              StateLabel = if ($NicStateMap.ContainsKey($stateInt)) { $NicStateMap[$stateInt] } else { 'unknown' }
                          }
                      }

        return [pscustomobject]@{
            ClusterName = $clusterName
            Networks    = @($networks)
            Interfaces  = @($interfaces)
        }
    }
    catch {
        Write-Warning "[Get-ClusterNetworkData] $($_.Exception.Message)"
        return $null
    }
}

# =============================================================================
# SECTION 5 - Metric Submission
# -----------------------------------------------------------------------------
# Converts collected data into Datadog gauge metrics and sends via DogStatsD.
#
# Two metrics per component:
#   wsfc.*.health -> binary 1/0   - used by Datadog monitors (threshold < 1 = alert)
#   wsfc.*.state  -> raw int code - used in dashboards for trend/state-change graphs
#
# Quorum context (type, witness details) carried as tags on wsfc.quorum.witness.health
# rather than separate metrics - keeps custom metric count low while retaining
# full filterability in Datadog dashboards.
# =============================================================================

function Submit-WSFCMetrics {
    param([string] $ComputerName = '')

    Write-Host "[$([datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))] Collecting WSFC metrics..." -ForegroundColor DarkCyan

    # ── 5A: Cluster, Node, Quorum ─────────────────────────────────────────────
    $clusterData = Get-ClusterCimData -ComputerName $ComputerName

    if ($null -ne $clusterData) {
        $cn = ($clusterData.ClusterName -replace '[^a-zA-Z0-9_\-]','_').ToLower()

        $clusterTags = @{
            cluster_name     = $cn
            quorum_type      = $clusterData.QuorumType
            core_group_state = $clusterData.CoreGroupState
        }

        # wsfc.cluster.health - 1=Up (>=1 node Up/Joining), 0=Down
        Send-Metric -Name 'wsfc.cluster.health' `
                    -Value ([int][bool]$clusterData.ClusterIsUp) `
                    -Tags  $clusterTags

        # wsfc.cluster.nodes.up / down / paused
        Send-Metric -Name 'wsfc.cluster.nodes.up'     -Value $clusterData.NodesUp     -Tags $clusterTags
        Send-Metric -Name 'wsfc.cluster.nodes.down'   -Value $clusterData.NodesDown   -Tags $clusterTags
        Send-Metric -Name 'wsfc.cluster.nodes.paused' -Value $clusterData.NodesPaused -Tags $clusterTags

        # wsfc.quorum.witness.health - 1=Online, 0=Offline/Failed/None
        $witnessHealth = if ($clusterData.WitnessState -eq 'online') { 1 } else { 0 }
        Send-Metric -Name 'wsfc.quorum.witness.health' `
                    -Value $witnessHealth `
                    -Tags  @{
                        cluster_name       = $cn
                        quorum_type        = $clusterData.QuorumType
                        quorum_type_value  = [string]$clusterData.QuorumTypeValue
                        witness_type       = $clusterData.WitnessType
                        witness_name       = $clusterData.WitnessName
                        witness_state      = $clusterData.WitnessState
                        witness_owner_node = $clusterData.WitnessOwner
                    }

        # wsfc.node.health + wsfc.node.state - per node
        foreach ($node in $clusterData.Nodes) {
            $stateCode  = [int]$node.State
            $stateLabel = if ($NodeStateMap.ContainsKey($stateCode)) { $NodeStateMap[$stateCode] } else { 'unknown' }
            $nodeName   = ($node.Name -replace '[^a-zA-Z0-9_\-]','_').ToLower()

            $nodeTags = @{
                cluster_name = $cn
                node_name    = $nodeName
                node_state   = $stateLabel
            }

            Send-Metric -Name 'wsfc.node.health' -Value ([int]($stateCode -eq 0)) -Tags $nodeTags
            Send-Metric -Name 'wsfc.node.state'  -Value $stateCode                -Tags $nodeTags
        }
    }

    # ── 5B: Network, Interface ────────────────────────────────────────────────
    $netData = Get-ClusterNetworkData -ComputerName $ComputerName

    if ($null -ne $netData) {
        $cn = ($netData.ClusterName -replace '[^a-zA-Z0-9_\-]','_').ToLower()

        foreach ($net in $netData.Networks) {
            $netName = ($net.Name -replace '[^a-zA-Z0-9_\-]','_').ToLower()
            $netTags = @{
                cluster_name  = $cn
                network_name  = $netName
                network_role  = $net.Role
                network_state = $net.StateLabel
            }
            Send-Metric -Name 'wsfc.network.health' -Value ([int]($net.StateCode -eq 2)) -Tags $netTags
            Send-Metric -Name 'wsfc.network.state'  -Value $net.StateCode               -Tags $netTags
            Send-Metric -Name 'wsfc.network.metric' -Value $net.Metric                  -Tags $netTags
        }

        foreach ($nic in $netData.Interfaces) {
            $nicName   = ($nic.Name    -replace '[^a-zA-Z0-9_\-]','_').ToLower()
            $nodeName  = ($nic.Node    -replace '[^a-zA-Z0-9_\-]','_').ToLower()
            $netName   = ($nic.Network -replace '[^a-zA-Z0-9_\-]','_').ToLower()
            $adptrName = ($nic.Adapter -replace '[^a-zA-Z0-9_\-]','_').ToLower()

            $nicTags = @{
                cluster_name    = $cn
                node_name       = $nodeName
                network_name    = $netName
                adapter_name    = $adptrName
                interface_name  = $nicName
                interface_state = $nic.StateLabel
            }

            Send-Metric -Name 'wsfc.network_interface.health' -Value ([int]($nic.StateCode -eq 4)) -Tags $nicTags
            Send-Metric -Name 'wsfc.network_interface.state'  -Value $nic.StateCode               -Tags $nicTags
        }
    }

    Write-Host "[$([datetime]::Now.ToString('HH:mm:ss'))] Metrics submitted." -ForegroundColor Green
}

# =============================================================================
# SECTION 6 - Entry Point / 60-Second Run Loop
# -----------------------------------------------------------------------------
# Pre-flight runs first - exits if prerequisites are missing.
# Stopwatch compensates for collection time to maintain exact 60s intervals.
# UDP client is always disposed in the finally block.
# =============================================================================

if (-not (Test-Prerequisites)) {
    Write-Host "[WSFC Monitor] Prerequisites not met. Please fix the issues above and re-run." -ForegroundColor Red
    Write-Host ""
    Write-Host "Quick fix commands (elevated PowerShell):" -ForegroundColor Yellow
    Write-Host "  Install-WindowsFeature -Name Failover-Clustering -IncludeManagementTools" -ForegroundColor White
    Write-Host "  Install-WindowsFeature -Name RSAT-Clustering-PowerShell" -ForegroundColor White
    Write-Host "  Restart-Computer" -ForegroundColor White
    exit 1
}

Initialize-DogStatsDClient -Hostname $DogStatsDHost -Port $DogStatsDPort

try {
    if ($RunOnce) {
        Submit-WSFCMetrics -ComputerName $ComputerName
        Write-Host '[WSFC Monitor] Single collection cycle complete.' -ForegroundColor Green
    }
    else {
        Write-Host '[WSFC Monitor] Running every 60 seconds. Press Ctrl+C to stop.' -ForegroundColor Cyan
        while ($true) {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            Submit-WSFCMetrics -ComputerName $ComputerName
            $sw.Stop()
            $sleepMs = [Math]::Max(0, 60000 - $sw.ElapsedMilliseconds)
            Write-Verbose "[Scheduler] Collection took $($sw.ElapsedMilliseconds)ms. Sleeping $([Math]::Round($sleepMs/1000,1))s."
            Start-Sleep -Milliseconds $sleepMs
        }
    }
}
finally {
    $Script:UdpClient.Close()
    $Script:UdpClient.Dispose()
    Write-Host '[WSFC Monitor] Stopped. UDP client closed.' -ForegroundColor Yellow
}