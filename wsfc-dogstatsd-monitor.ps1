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
# Validates that required Windows features are installed before starting.
# Exits with a clear, actionable error message if prerequisites are missing.
# This prevents the script from running a silent loop with zero useful data.
#
# Checks performed:
#   1. ROOT\MSCluster WMI namespace  - registered when Failover-Clustering is installed
#   2. FailoverClusters PS module    - installed via RSAT-Clustering-PowerShell
#   3. Cluster Service (ClusSvc)     - must be running on this node
# =============================================================================

function Test-Prerequisites {
    $pass = $true

    Write-Host "`n[Pre-Flight] Checking prerequisites..." -ForegroundColor Cyan

    # Check 1 - ROOT\MSCluster WMI namespace
    # This namespace is registered when the Failover Clustering feature is installed.
    # If missing, Get-CimInstance throws "Invalid namespace 0x8004100e"
    try {
        $null = Get-CimInstance -Namespace ROOT\MSCluster `
                                -ClassName  MSCluster_Cluster `
                                -ErrorAction Stop |
                Select-Object -First 1
        Write-Host "  [OK] ROOT\MSCluster WMI namespace is available." -ForegroundColor Green
    }
    catch {
        Write-Host "  [FAIL] ROOT\MSCluster WMI namespace not found." -ForegroundColor Red
        Write-Host "         The Failover Clustering feature is NOT installed on this node." -ForegroundColor Yellow
        Write-Host "         Fix: Run in an elevated PowerShell session:" -ForegroundColor Yellow
        Write-Host "              Install-WindowsFeature -Name Failover-Clustering -IncludeManagementTools" -ForegroundColor White
        Write-Host "         Note: A reboot may be required after installation." -ForegroundColor Yellow
        $pass = $false
    }

    # Check 2 - FailoverClusters PowerShell module
    # Required for Get-ClusterNetwork / Get-ClusterNetworkInterface cmdlets.
    # Installed separately from the clustering feature via RSAT tools.
    if (Get-Module -ListAvailable -Name FailoverClusters) {
        Write-Host "  [OK] FailoverClusters PowerShell module is available." -ForegroundColor Green
    }
    else {
        Write-Host "  [FAIL] FailoverClusters PowerShell module not found." -ForegroundColor Red
        Write-Host "         Fix: Run in an elevated PowerShell session:" -ForegroundColor Yellow
        Write-Host "              Install-WindowsFeature -Name RSAT-Clustering-PowerShell" -ForegroundColor White
        $pass = $false
    }

    # Check 3 - Cluster Service running
    # Even if features are installed, the Cluster Service must be running.
    $svc = Get-Service -Name ClusSvc -ErrorAction SilentlyContinue
    if ($null -eq $svc) {
        Write-Host "  [FAIL] Cluster Service (ClusSvc) not found on this node." -ForegroundColor Red
        Write-Host "         This node may not be a cluster member." -ForegroundColor Yellow
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
# FIX APPLIED: Parameter renamed from $Host -> $Hostname
#   $Host is a PowerShell automatic/reserved variable (refers to the PS host
#   application). Using it as a parameter name causes the error:
#   "Cannot overwrite variable Host because it is read-only or constant."
#
# Wire format: <metric.name>:<value>|g|#tag1:val1,tag2:val2
# Example:     wsfc.node.health:1|g|#cluster_name:prod,node_name:node01,node_state:up
# =============================================================================

function Initialize-DogStatsDClient {
    param(
        [string] $Hostname,    # NOTE: renamed from $Host (reserved PS variable)
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

    # Sanitize tag keys/values - DogStatsD requires [a-zA-Z0-9_\-./] only
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
# WMI returns raw integers. These maps translate them to human-readable strings
# used as Datadog tag values - readable in dashboards without needing a legend.
#
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
# Queries ROOT\MSCluster WMI namespace - available on any WSFC node.
#
# WMI Classes used:
#   MSCluster_Cluster       -> cluster name + quorum type
#   MSCluster_Node          -> per-node states
#   MSCluster_ResourceGroup -> resource groups (find Core Cluster Group)
#   MSCluster_Resource      -> all resources (find witness resource)
#
# If ComputerName is provided, a CimSession is opened for remote queries.
# The session is ALWAYS closed in the finally block (no resource leaks).
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

        # Query 3 - Resource groups (to check Core Cluster Group state)
        $groups = Get-CimInstance -Namespace ROOT\MSCluster `
                                  -ClassName  MSCluster_ResourceGroup @cimArgs

        # Query 4 - All resources (to find quorum witness resource)
        $resources = Get-CimInstance -Namespace ROOT\MSCluster `
                                     -ClassName  MSCluster_Resource @cimArgs |
                     Select-Object Name, ResourceType, State, OwnerGroup, OwnerNode

        # Derived - Cluster is Up if at least one node is Up(0) or Joining(3)
        $clusterIsUp = [bool]($nodes | Where-Object { $_.State -in @(0, 3) })

        # Witness detection - different quorum types use different resource types
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

        # Extract witness details (default 'none' if no witness configured)
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

        # Core Cluster Group - hosts Cluster Name + IP resources
        # If Offline or Failed, the cluster is functionally down
        $coreGroup      = $groups | Where-Object { $_.IsCoreGroup } | Select-Object -First 1
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
# Uses two cmdlets from the FailoverClusters PS module:
#   Get-ClusterNetwork          -> one object per network segment
#   Get-ClusterNetworkInterface -> one object per NIC per node per network
#
# .State returns an enum - cast to [int] for consistent map lookup.
# .Node and .Network are embedded objects - extract .Name as plain string.
# =============================================================================

function Get-ClusterNetworkData {
    param([string] $ComputerName = '')

    try {
        Import-Module FailoverClusters -ErrorAction Stop

        $clusterArgs = @{}
        if ($ComputerName -and $ComputerName -ne '') { $clusterArgs.Cluster = $ComputerName }

        $clusterName = Get-Cluster @clusterArgs -ErrorAction Stop |
                       Select-Object -ExpandProperty Name -First 1

        # Network segments (e.g. "Cluster-Network-1", "Heartbeat-Network")
        $networks = Get-ClusterNetwork @clusterArgs | ForEach-Object {
            $stateInt = try { [int]$_.State } catch { -1 }
            [pscustomobject]@{
                Name       = [string]$_.Name
                StateCode  = $stateInt
                StateLabel = if ($NetworkStateMap.ContainsKey($stateInt)) { $NetworkStateMap[$stateInt] } else { 'unknown' }
                Role       = ($_.Role).ToString().ToLower()
                Metric     = [int]$_.Metric
            }
        }

        # NIC per node per network (e.g. "NODE01 - Ethernet0")
        $interfaces = Get-ClusterNetworkInterface @clusterArgs | ForEach-Object {
            $stateInt = try { [int]$_.State } catch { -1 }
            [pscustomobject]@{
                Name       = [string]$_.Name
                Node       = [string]$_.Node.Name      # plain string - not the embedded object
                Network    = [string]$_.Network.Name   # plain string - not the embedded object
                Adapter    = [string]$_.Adapter
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
#   wsfc.*.health -> binary 1/0  - used by monitors (threshold < 1 = alert)
#   wsfc.*.state  -> raw code    - used in dashboards for trend/state-change graphs
#
# Quorum context (type, witness name/type/state/owner) sent as TAGS on
# wsfc.quorum.witness.health - not as separate metrics - to keep custom
# metric count low while keeping all data queryable in Datadog.
# =============================================================================

function Submit-WSFCMetrics {
    param([string] $ComputerName = '')

    Write-Host "[$([datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))] Collecting WSFC metrics..." -ForegroundColor DarkCyan

    # -------------------------------------------------------------------------
    # 5A - Cluster Health, Node Health, Quorum  (from WMI)
    # -------------------------------------------------------------------------
    $clusterData = Get-ClusterCimData -ComputerName $ComputerName

    if ($null -ne $clusterData) {
        $cn = ($clusterData.ClusterName -replace '[^a-zA-Z0-9_\-]','_').ToLower()

        # Common tags shared by all cluster-scope metrics
        $clusterTags = @{
            cluster_name     = $cn
            quorum_type      = $clusterData.QuorumType
            core_group_state = $clusterData.CoreGroupState
        }

        # wsfc.cluster.health - 1=Up (>=1 node Up/Joining), 0=Down
        Send-Metric -Name 'wsfc.cluster.health' `
                    -Value ([int][bool]$clusterData.ClusterIsUp) `
                    -Tags  $clusterTags

        # wsfc.cluster.nodes.up / down / paused - aggregate counts
        # nodes.down >= 1 is an early warning before quorum is lost
        Send-Metric -Name 'wsfc.cluster.nodes.up'     -Value $clusterData.NodesUp     -Tags $clusterTags
        Send-Metric -Name 'wsfc.cluster.nodes.down'   -Value $clusterData.NodesDown   -Tags $clusterTags
        Send-Metric -Name 'wsfc.cluster.nodes.paused' -Value $clusterData.NodesPaused -Tags $clusterTags

        # wsfc.quorum.witness.health - 1=Online, 0=Offline/Failed/None
        # All quorum context travels as tags - not as separate metrics
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

            # wsfc.node.health: 1=Up only | 0=Down/Paused/Joining/Unknown
            Send-Metric -Name 'wsfc.node.health' -Value ([int]($stateCode -eq 0)) -Tags $nodeTags

            # wsfc.node.state: 0=Up | 1=Down | 2=Paused | 3=Joining
            Send-Metric -Name 'wsfc.node.state'  -Value $stateCode                -Tags $nodeTags
        }
    }

    # -------------------------------------------------------------------------
    # 5B - Network Health & Interface Health  (from FailoverClusters module)
    # -------------------------------------------------------------------------
    $netData = Get-ClusterNetworkData -ComputerName $ComputerName

    if ($null -ne $netData) {
        $cn = ($netData.ClusterName -replace '[^a-zA-Z0-9_\-]','_').ToLower()

        # wsfc.network.health / state / metric - per network segment
        foreach ($net in $netData.Networks) {
            $netName = ($net.Name -replace '[^a-zA-Z0-9_\-]','_').ToLower()
            $netTags = @{
                cluster_name  = $cn
                network_name  = $netName
                network_role  = $net.Role        # cluster_and_client / cluster / none
                network_state = $net.StateLabel
            }

            # wsfc.network.health: 1=Up (StateCode 2 only) | 0=Down/PartiallyUp/Unreachable
            Send-Metric -Name 'wsfc.network.health' -Value ([int]($net.StateCode -eq 2)) -Tags $netTags

            # wsfc.network.state: 0=Down | 1=PartiallyUp | 2=Up | 3=Unreachable
            Send-Metric -Name 'wsfc.network.state'  -Value $net.StateCode               -Tags $netTags

            # wsfc.network.metric: route preference - lower = more preferred path
            Send-Metric -Name 'wsfc.network.metric' -Value $net.Metric                  -Tags $netTags
        }

        # wsfc.network_interface.health / state - per NIC per node
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

            # wsfc.network_interface.health: 1=Up (StateCode 4 only) | 0=anything else
            Send-Metric -Name 'wsfc.network_interface.health' -Value ([int]($nic.StateCode -eq 4)) -Tags $nicTags

            # wsfc.network_interface.state: 0=Unknown|1=Unavailable|2=Failed|3=Unreachable|4=Up
            Send-Metric -Name 'wsfc.network_interface.state'  -Value $nic.StateCode               -Tags $nicTags
        }
    }

    Write-Host "[$([datetime]::Now.ToString('HH:mm:ss'))] Metrics submitted." -ForegroundColor Green
}

# =============================================================================
# SECTION 6 - Entry Point / 60-Second Run Loop
# -----------------------------------------------------------------------------
# Pre-flight check runs first - exits cleanly if prerequisites are not met.
#
# The run loop uses a Stopwatch to maintain exactly 60-second intervals:
#   Sleep = 60000ms - actual_collection_time_ms
# This ensures consistent metric intervals regardless of WMI query duration.
#
# UDP client is always disposed in the finally block (Ctrl+C or any error).
# =============================================================================

# Run pre-flight checks - abort if this node is not cluster-ready
if (-not (Test-Prerequisites)) {
    Write-Host "[WSFC Monitor] Prerequisites not met. Please fix the issues above and re-run." -ForegroundColor Red
    Write-Host ""
    Write-Host "Quick fix commands (run in an elevated PowerShell window):" -ForegroundColor Yellow
    Write-Host "  Install-WindowsFeature -Name Failover-Clustering -IncludeManagementTools" -ForegroundColor White
    Write-Host "  Install-WindowsFeature -Name RSAT-Clustering-PowerShell" -ForegroundColor White
    Write-Host "  Restart-Computer  # if prompted after feature install" -ForegroundColor White
    exit 1
}

# Initialise UDP client
# NOTE: Using $Hostname parameter (not $Host which is a reserved PS variable)
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
            # Sleep for remainder of 60s window - compensates for collection time
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
