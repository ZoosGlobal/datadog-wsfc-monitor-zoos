# ==============================================================================
#
#   ███████╗ ██████╗  ██████╗ ███████╗     ██████╗ ██╗      ██████╗ ██████╗  █████╗ ██╗
#   ╚══███╔╝██╔═══██╗██╔═══██╗██╔════╝    ██╔════╝ ██║     ██╔═══██╗██╔══██╗██╔══██╗██║
#     ███╔╝ ██║   ██║██║   ██║███████╗    ██║  ███╗██║     ██║   ██║██████╔╝███████║██║
#    ███╔╝  ██║   ██║██║   ██║╚════██║    ██║   ██║██║     ██║   ██║██╔══██╗██╔══██║██║
#   ███████╗╚██████╔╝╚██████╔╝███████║    ╚██████╔╝███████╗╚██████╔╝██████╔╝██║  ██║███████╗
#   ╚══════╝ ╚═════╝  ╚═════╝ ╚══════╝     ╚═════╝ ╚══════╝ ╚═════╝ ╚═════╝ ╚═╝  ╚═╝╚══════╝
#
# ==============================================================================
#  Script    : Datadog WSFC Monitor - Setup Script
#  Version   : 1.0.0
#  Purpose   : Post-agent-installation setup for WSFC Datadog monitoring
#              1. Validates Failover Clustering prerequisites (WMI + module + service)
#              2. Validates Datadog Agent is installed and running
#              3. Validates DogStatsD is listening on :8125
#              4. Creates C:\Scripts directory
#              5. Copies wsfc-dogstatsd-monitor.ps1 to C:\Scripts\
#              6. Unblocks both scripts (removes Zone.Identifier)
#              7. Runs wsfc-dogstatsd-monitor.ps1 once for manual validation
#              8. Creates Windows Task Scheduler task (every 1 min, SYSTEM)
#              9. Prints final status summary
# ------------------------------------------------------------------------------
#  Author    : Shivam Anand
#  Title     : Sr. DevOps Engineer | Engineering
#  Org       : Zoos Global
#  Email     : shivam.anand@zoosglobal.com
#  Web       : www.zoosglobal.com
#  Address   : Violena, Pali Hill, Bandra West, Mumbai - 400050
# ------------------------------------------------------------------------------
#  Usage     : Run as Administrator from the folder containing
#              wsfc-dogstatsd-monitor.ps1
#
#              PowerShell.exe -ExecutionPolicy Bypass -File .\wsfc-setup.ps1
#
#  Platform  : Windows Server 2016 / 2019 / 2022 / 2025
#  Requires  : Failover Clustering feature installed
#              Datadog Agent already installed
#              PowerShell 5.1+
#              Administrator privileges
# ==============================================================================

#Requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'

# ==============================================================================
# CONFIG
# ==============================================================================
$ScriptsDir   = 'C:\Scripts'
$SourceScript = 'wsfc-dogstatsd-monitor.ps1'
$TargetScript = 'C:\Scripts\wsfc-dogstatsd-monitor.ps1'
$TaskName     = 'WSFC-DogStatsD-Monitor'
$TaskDesc     = 'Collects WSFC cluster health metrics every minute and submits to Datadog via DogStatsD. | Zoos Global'
$DDAgentSvc   = 'datadogagent'
$DDStatsdPort = 8125

$SEP  = '=' * 70
$SEP2 = '-' * 60

# ==============================================================================
# HELPER FUNCTIONS
# ==============================================================================

function Write-Banner {
    Write-Host ''
    Write-Host $SEP -ForegroundColor Cyan
    Write-Host '  Datadog WSFC Monitor - Setup                        Zoos Global' -ForegroundColor Cyan
    Write-Host $SEP -ForegroundColor Cyan
    Write-Host '  Author : Shivam Anand | Sr. DevOps Engineer'
    Write-Host '  Web    : www.zoosglobal.com'
    Write-Host '  Email  : shivam.anand@zoosglobal.com'
    Write-Host $SEP
    Write-Host ''
}

function Write-Step($step, $msg) {
    Write-Host ''
    Write-Host "  [$step] $msg" -ForegroundColor Yellow
    Write-Host "  $SEP2" -ForegroundColor DarkGray
}

function Write-OK($msg)   { Write-Host "  [OK]   $msg" -ForegroundColor Green }
function Write-FAIL($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red   }
function Write-INFO($msg) { Write-Host "  [INFO] $msg" -ForegroundColor Cyan  }
function Write-WARN($msg) { Write-Host "  [WARN] $msg" -ForegroundColor Yellow }

# ==============================================================================
# BANNER
# ==============================================================================
Write-Banner

# ==============================================================================
# STEP 1 - Validate Failover Clustering Prerequisites
# ==============================================================================
Write-Step '1/8' 'Validating Failover Clustering prerequisites...'

# 1A - ROOT\MSCluster WMI namespace
try {
    $null = Get-CimInstance -Namespace ROOT\MSCluster -ClassName MSCluster_Cluster `
                            -ErrorAction Stop | Select-Object -First 1
    Write-OK 'ROOT\MSCluster WMI namespace is available'
}
catch {
    Write-FAIL 'ROOT\MSCluster WMI namespace not found'
    Write-INFO 'Fix: Install-WindowsFeature -Name Failover-Clustering -IncludeManagementTools'
    Write-INFO 'A reboot may be required after installation'
    exit 1
}

# 1B - FailoverClusters PowerShell module
if (Get-Module -ListAvailable -Name FailoverClusters) {
    Write-OK 'FailoverClusters PowerShell module is available'
}
else {
    Write-FAIL 'FailoverClusters PowerShell module not found'
    Write-INFO 'Fix: Install-WindowsFeature -Name RSAT-Clustering-PowerShell'
    exit 1
}

# 1C - Cluster Service running
$clusSvc = Get-Service -Name ClusSvc -ErrorAction SilentlyContinue
if ($null -eq $clusSvc) {
    Write-FAIL 'Cluster Service (ClusSvc) not found - this node is not a cluster member'
    Write-INFO 'Join this node to a Windows Server Failover Cluster first'
    exit 1
}
elseif ($clusSvc.Status -ne 'Running') {
    Write-WARN "Cluster Service (ClusSvc) is not running (Status: $($clusSvc.Status))"
    Write-INFO 'Attempting to start Cluster Service...'
    Start-Service -Name ClusSvc
    Start-Sleep -Seconds 3
    $clusSvc = Get-Service -Name ClusSvc
    if ($clusSvc.Status -eq 'Running') {
        Write-OK 'Cluster Service started successfully'
    }
    else {
        Write-FAIL 'Cluster Service could not be started'
        exit 1
    }
}
else {
    Write-OK "Cluster Service (ClusSvc) is running"
}

# Print cluster name for confirmation
try {
    $clusterName = (Get-Cluster -ErrorAction Stop).Name
    Write-INFO "Cluster detected : $clusterName"
}
catch {
    Write-WARN 'Could not retrieve cluster name - continuing setup'
}

# ==============================================================================
# STEP 2 - Validate Datadog Agent service
# ==============================================================================
Write-Step '2/8' 'Checking Datadog Agent service...'

try {
    $svc = Get-Service -Name $DDAgentSvc -ErrorAction Stop
    if ($svc.Status -eq 'Running') {
        Write-OK "Datadog Agent is running (Status: $($svc.Status))"
    }
    else {
        Write-WARN "Datadog Agent is NOT running (Status: $($svc.Status))"
        Write-INFO 'Attempting to start Datadog Agent...'
        Start-Service -Name $DDAgentSvc
        Start-Sleep -Seconds 5
        $svc = Get-Service -Name $DDAgentSvc
        if ($svc.Status -eq 'Running') {
            Write-OK 'Datadog Agent started successfully'
        }
        else {
            throw 'Datadog Agent could not be started'
        }
    }
}
catch {
    Write-FAIL "Datadog Agent service not found: $_"
    Write-INFO 'Install: https://s3.amazonaws.com/ddagent-windows-stable/datadog-agent-7-latest.amd64.msi'
    exit 1
}

# ==============================================================================
# STEP 3 - Verify DogStatsD is listening on UDP :8125
# ==============================================================================
Write-Step '3/8' "Verifying DogStatsD is listening on UDP :$DDStatsdPort..."

try {
    $listening = netstat -an | Select-String "UDP.*0\.0\.0\.0:$DDStatsdPort|UDP.*127\.0\.0\.1:$DDStatsdPort"
    if ($listening) {
        Write-OK "DogStatsD is listening on :$DDStatsdPort"
        Write-INFO "$($listening[0].ToString().Trim())"
    }
    else {
        Write-FAIL "DogStatsD not found on UDP port $DDStatsdPort"
        Write-INFO 'Check C:\ProgramData\Datadog\datadog.yaml: dogstatsd_port: 8125'
        exit 1
    }
}
catch {
    Write-FAIL "Could not verify DogStatsD port: $_"
    exit 1
}

# ==============================================================================
# STEP 4 - Create C:\Scripts directory
# ==============================================================================
Write-Step '4/8' "Creating target directory: $ScriptsDir..."

try {
    if (Test-Path $ScriptsDir) {
        Write-OK "Directory already exists: $ScriptsDir"
    }
    else {
        New-Item -ItemType Directory -Path $ScriptsDir -Force | Out-Null
        Write-OK "Created directory: $ScriptsDir"
    }
}
catch {
    Write-FAIL "Failed to create directory ${ScriptsDir}: $_"
    exit 1
}

# ==============================================================================
# STEP 5 - Copy wsfc-dogstatsd-monitor.ps1 to C:\Scripts\
# ==============================================================================
Write-Step '5/8' "Copying $SourceScript to $TargetScript..."

try {
    $sourcePath = Join-Path (Get-Location).Path $SourceScript

    if (-not (Test-Path $sourcePath)) {
        Write-FAIL "$SourceScript not found in current directory: $(Get-Location)"
        Write-INFO 'Run wsfc-setup.ps1 from the same folder as wsfc-dogstatsd-monitor.ps1'
        exit 1
    }

    Copy-Item -Path $sourcePath -Destination $TargetScript -Force
    Write-OK "Copied successfully: $TargetScript"

    $copied = Get-Item $TargetScript
    Write-INFO "File size    : $([math]::Round($copied.Length / 1KB, 2)) KB"
    Write-INFO "Last written : $($copied.LastWriteTime)"
}
catch {
    Write-FAIL "Failed to copy script: $_"
    exit 1
}

# ==============================================================================
# STEP 6 - Unblock scripts (remove Zone.Identifier stream)
# Files downloaded from internet/GitHub get a hidden Zone.Identifier NTFS
# stream that Windows treats as untrusted. Unblock-File removes it so the
# script can run without triggering the "Do you want to run?" security prompt.
# ==============================================================================
Write-Step '6/8' 'Unblocking scripts (removing Zone.Identifier)...'

try {
    Unblock-File -Path $TargetScript -ErrorAction SilentlyContinue
    Write-OK "Unblocked: $TargetScript"

    $setupPath = $MyInvocation.MyCommand.Path
    if ($setupPath -and (Test-Path $setupPath)) {
        Unblock-File -Path $setupPath -ErrorAction SilentlyContinue
        Write-OK "Unblocked: $setupPath"
    }

    $sourcePath = Join-Path (Get-Location).Path $SourceScript
    if (Test-Path $sourcePath) {
        Unblock-File -Path $sourcePath -ErrorAction SilentlyContinue
        Write-OK "Unblocked: $sourcePath"
    }
}
catch {
    Write-FAIL "Unblock-File failed: $_"
    Write-INFO "Try manually: Unblock-File -Path '$TargetScript'"
    exit 1
}

# ==============================================================================
# STEP 7 - Run wsfc-dogstatsd-monitor.ps1 once for validation
# ==============================================================================
Write-Step '7/8' 'Running wsfc-dogstatsd-monitor.ps1 once for validation...'
Write-INFO 'You should see metric lines like: >> wsfc.cluster.health:1|g|#...'
Write-Host ''

try {
    & PowerShell.exe -NonInteractive -ExecutionPolicy Bypass `
        -File $TargetScript -RunOnce
    Write-Host ''
    Write-OK 'Validation run completed successfully'
    Write-INFO 'Verify in Datadog -> Metrics -> Explorer -> search: wsfc.cluster.health'
}
catch {
    Write-WARN "Validation run encountered an issue: $_"
    Write-INFO 'Review output above. Setup will continue to create the scheduled task...'
}

# ==============================================================================
# STEP 8 - Create / Update Windows Task Scheduler task
# ==============================================================================
Write-Step '8/8' "Creating Task Scheduler task: '$TaskName'..."

try {
    # Remove existing task if present
    $existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existingTask) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-INFO "Removed existing task: $TaskName"
    }

    # Action: run script with -RunOnce (task fires every minute, script exits after one cycle)
    $action = New-ScheduledTaskAction `
        -Execute  'PowerShell.exe' `
        -Argument "-NonInteractive -ExecutionPolicy Bypass -File `"$TargetScript`" -RunOnce"

    # Trigger: fire at startup, then repeat every 1 minute indefinitely
    $trigger = New-ScheduledTaskTrigger `
        -Once `
        -At                 (Get-Date) `
        -RepetitionInterval (New-TimeSpan -Minutes 1) `
        -RepetitionDuration (New-TimeSpan -Days 3650)

    # Settings: skip new instance if already running, kill if hung after 2 min, retry on failure
    $settings = New-ScheduledTaskSettingsSet `
        -ExecutionTimeLimit         (New-TimeSpan -Minutes 2) `
        -MultipleInstances          IgnoreNew `
        -RestartCount               3 `
        -RestartInterval            (New-TimeSpan -Minutes 1) `
        -StartWhenAvailable `
        -RunOnlyIfNetworkAvailable:$false

    # Principal: run as SYSTEM with highest privileges
    $principal = New-ScheduledTaskPrincipal `
        -UserId    'NT AUTHORITY\SYSTEM' `
        -RunLevel  Highest `
        -LogonType ServiceAccount

    Register-ScheduledTask `
        -TaskName    $TaskName `
        -Action      $action `
        -Trigger     $trigger `
        -Settings    $settings `
        -Principal   $principal `
        -Description $TaskDesc `
        -Force | Out-Null

    $task = Get-ScheduledTask -TaskName $TaskName
    Write-OK "Task registered  : $TaskName"
    Write-INFO "Run as           : NT AUTHORITY\SYSTEM"
    Write-INFO "Interval         : Every 1 minute"
    Write-INFO "Execution limit  : 2 minutes (auto-killed if hung)"
    Write-INFO "On failure       : Retry 3x with 1-minute delay"
    Write-INFO "Multiple instances: IgnoreNew (no duplicate metrics)"
    Write-INFO "Task state       : $($task.State)"

    # Start immediately without waiting for reboot
    Start-ScheduledTask -TaskName $TaskName
    Start-Sleep -Seconds 2
    $task = Get-ScheduledTask -TaskName $TaskName
    Write-OK "Task started - first collection cycle running now (State: $($task.State))"
}
catch {
    Write-FAIL "Failed to create scheduled task: $_"
    exit 1
}

# ==============================================================================
# FINAL STATUS SUMMARY
# ==============================================================================
Write-Host ''
Write-Host $SEP -ForegroundColor Green
Write-Host '  SETUP COMPLETE - WSFC Datadog Monitor is active' -ForegroundColor Green
Write-Host $SEP -ForegroundColor Green
Write-Host ''
Write-Host "  Script location   : $TargetScript"
Write-Host "  Task name         : $TaskName"
Write-Host '  Schedule          : Every 1 minute'
Write-Host '  Run as            : NT AUTHORITY\SYSTEM'
Write-Host ''
Write-Host '  Metrics being collected:'
Write-Host '    wsfc.cluster.health          wsfc.cluster.nodes.up'
Write-Host '    wsfc.cluster.nodes.down      wsfc.cluster.nodes.paused'
Write-Host '    wsfc.node.health             wsfc.node.state'
Write-Host '    wsfc.quorum.witness.health'
Write-Host '    wsfc.network.health          wsfc.network.state'
Write-Host '    wsfc.network.metric'
Write-Host '    wsfc.network_interface.health wsfc.network_interface.state'
Write-Host ''
Write-Host '  Next steps:'
Write-Host '  1. Open Datadog -> Metrics -> Explorer'
Write-Host '  2. Search: wsfc.cluster.health'
Write-Host '  3. Metrics should appear within ~60 seconds'
Write-Host ''
Write-Host '  Verify task is running:'
Write-Host "  > Get-ScheduledTask -TaskName '$TaskName' | Select-Object TaskName, State"
Write-Host "  > schtasks /query /tn ""$TaskName"" /fo LIST /v"
Write-Host ''
Write-Host '  Stop monitoring:'
Write-Host "  > Stop-ScheduledTask  -TaskName '$TaskName'"
Write-Host ''
Write-Host '  Remove monitoring:'
Write-Host "  > Unregister-ScheduledTask -TaskName '$TaskName' -Confirm:`$false"
Write-Host "  > Remove-Item '$TargetScript'"
Write-Host ''
Write-Host $SEP -ForegroundColor Cyan
Write-Host '  Powered by Zoos Global | www.zoosglobal.com' -ForegroundColor Cyan
Write-Host '  (c) 2026 Zoos Global | shivam.anand@zoosglobal.com' -ForegroundColor Cyan
Write-Host $SEP -ForegroundColor Cyan
Write-Host ''
# ==============================================================================