# Datadog WSFC Monitor

<div align="center">

<img src="https://media.licdn.com/dms/image/v2/C510BAQEaNQXhD4EVaQ/company-logo_200_200/company-logo_200_200/0/1631395395675/zoos_logo?e=2147483647&v=beta&t=OR7jdri2KV5dJZuY7I8bt0U5wOFT6-ElaMb_0Kydvj8" alt="Zoos Global" width="90" height="90"/>

<br/>

![Version](https://img.shields.io/badge/version-1.0.0-blue?style=for-the-badge)
![Platform](https://img.shields.io/badge/platform-Windows%20Server-0078D4?style=for-the-badge&logo=windows)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1+-5391FE?style=for-the-badge&logo=powershell&logoColor=white)
![Datadog](https://img.shields.io/badge/Datadog-DogStatsD-632CA6?style=for-the-badge&logo=datadog&logoColor=white)
![License](https://img.shields.io/badge/license-MIT-green?style=for-the-badge)
![Status](https://img.shields.io/badge/status-Production%20Ready-brightgreen?style=for-the-badge)

<br/>

**PowerShell → Windows Server Failover Cluster → DogStatsD → Datadog Metrics → Dashboards & Alerts**

*Monitors WSFC cluster health, node states, quorum/witness status, network health, and NIC-level interface health via a single lightweight PowerShell script submitted every minute to Datadog.*

<br/>

![Metrics](https://img.shields.io/badge/metrics-12%20unique%20names-blue?style=flat-square)
![Runs](https://img.shields.io/badge/runs%2Fday-1440-blue?style=flat-square)
![Coverage](https://img.shields.io/badge/coverage-Cluster%20%2B%20Node%20%2B%20Quorum%20%2B%20Network-blue?style=flat-square)
![Scope](https://img.shields.io/badge/scope-All%20WSFC%20Nodes-blue?style=flat-square)

</div>

---

## 📁 Directory Structure

```text
C:\Scripts\
└── wsfc-dogstatsd-monitor.ps1    # Main metric collection & submission script
```

---

## 📊 Metrics Reference

### `wsfc.cluster.*` — Cluster Level

> Tags: `cluster_name`, `quorum_type`, `core_group_state`

| Metric | Type | Description |
|--------|------|-------------|
| `wsfc.cluster.health` | gauge | `1` = Up (≥1 node Up/Joining), `0` = Down |
| `wsfc.cluster.nodes.up` | gauge | Count of nodes in Up state |
| `wsfc.cluster.nodes.down` | gauge | Count of nodes in Down state ⚠️ |
| `wsfc.cluster.nodes.paused` | gauge | Count of nodes in Paused state |

---

### `wsfc.node.*` — Node Level

> Tags: `cluster_name`, `node_name`, `node_state`

| Metric | Type | Description |
|--------|------|-------------|
| `wsfc.node.health` | gauge | `1` = Up only, `0` = Down / Paused / Joining |
| `wsfc.node.state` | gauge | Raw state code: `0`=Up `1`=Down `2`=Paused `3`=Joining |

---

### `wsfc.quorum.*` — Quorum & Witness

> Tags: `cluster_name`, `quorum_type`, `quorum_type_value`, `witness_type`, `witness_name`, `witness_state`, `witness_owner_node`

| Metric | Type | Description |
|--------|------|-------------|
| `wsfc.quorum.witness.health` | gauge | `1` = Witness Online, `0` = Offline / Failed / None 🎯 |

> **ℹ️ Quorum Context as Tags:** All quorum details (type, witness name, state, owner node) are encoded as tags on `wsfc.quorum.witness.health` — not as separate metrics — to keep custom metric count low while retaining full filterability.

---

### `wsfc.network.*` — Network Segment Level

> Tags: `cluster_name`, `network_name`, `network_role`, `network_state`

| Metric | Type | Description |
|--------|------|-------------|
| `wsfc.network.health` | gauge | `1` = Up (state=2 only), `0` = Down / PartiallyUp / Unreachable |
| `wsfc.network.state` | gauge | Raw state: `0`=Down `1`=PartiallyUp `2`=Up `3`=Unreachable |
| `wsfc.network.metric` | gauge | Route preference — lower = more preferred path |

---

### `wsfc.network_interface.*` — NIC Level

> Tags: `cluster_name`, `node_name`, `network_name`, `adapter_name`, `interface_name`, `interface_state`

| Metric | Type | Description |
|--------|------|-------------|
| `wsfc.network_interface.health` | gauge | `1` = Up (state=4 only), `0` = any other state |
| `wsfc.network_interface.state` | gauge | Raw state: `0`=Unknown `1`=Unavailable `2`=Failed `3`=Unreachable `4`=Up |

---

## ⚙️ System Requirements

| Requirement | Version |
|-------------|---------|
| Windows Server | 2016 / 2019 / 2022 / 2025 |
| Failover Clustering Feature | Installed & Running |
| Datadog Agent | v7+ (DogStatsD on `127.0.0.1:8125`) |
| PowerShell | 5.1+ |
| Privileges | Local Administrator / SYSTEM |

---

## 1️⃣ Install Failover Clustering Prerequisites

> Run in an **elevated PowerShell window** on every cluster node.

```powershell
# Install Failover Clustering feature + management tools
Install-WindowsFeature -Name Failover-Clustering -IncludeManagementTools

# Install PowerShell management module
Install-WindowsFeature -Name RSAT-Clustering-PowerShell

# Reboot if prompted
Restart-Computer
```

**Verify installation:**

```powershell
(Get-WindowsFeature -Name Failover-Clustering).Installed        # True
(Get-WindowsFeature -Name RSAT-Clustering-PowerShell).Installed # True
Get-Service -Name ClusSvc                                        # Status: Running
```

---

## 2️⃣ Install Datadog Agent

```powershell
# Download installer
Invoke-WebRequest -Uri "https://s3.amazonaws.com/ddagent-windows-stable/datadog-agent-7-latest.amd64.msi" `
                  -OutFile "C:\ddagent.msi"

# Install with your API key
Start-Process -Wait msiexec -ArgumentList '/qn /i C:\ddagent.msi APIKEY="<your_api_key>"'
```

**Verify Agent is running:**

```powershell
Get-Service -Name "datadog-agent"
# Expected: Status = Running
```

**Verify DogStatsD is listening:**

```powershell
netstat -an | findstr 8125
# Expected: UDP    127.0.0.1:8125    *:*
```

---

## 3️⃣ Deploy the Script

```powershell
New-Item -ItemType Directory -Path "C:\Scripts" -Force
Copy-Item wsfc-dogstatsd-monitor.ps1 C:\Scripts\wsfc-dogstatsd-monitor.ps1
Unblock-File C:\Scripts\wsfc-dogstatsd-monitor.ps1
```

---

## 4️⃣ Manual Validation (MANDATORY)

> Always test manually **before** scheduling.

```powershell
cd C:\Scripts
.\wsfc-dogstatsd-monitor.ps1 -RunOnce -Verbose
```

**Expected output:**

```text
[Pre-Flight] Checking prerequisites...
  [OK] ROOT\MSCluster WMI namespace is available.
  [OK] FailoverClusters PowerShell module is available.
  [OK] Cluster Service (ClusSvc) is running.

[WSFC Monitor] DogStatsD target: 127.0.0.1:8125
[2026-04-07 16:40:28] Collecting WSFC metrics...
  >> wsfc.cluster.health:1|g|#cluster_name:prod-cluster,quorum_type:node_majority,...
  >> wsfc.cluster.nodes.up:2|g|#cluster_name:prod-cluster,...
  >> wsfc.cluster.nodes.down:0|g|#cluster_name:prod-cluster,...
  >> wsfc.node.health:1|g|#cluster_name:prod-cluster,node_name:node01,node_state:up
  >> wsfc.node.health:1|g|#cluster_name:prod-cluster,node_name:node02,node_state:up
  >> wsfc.quorum.witness.health:1|g|#cluster_name:prod-cluster,...
  >> wsfc.network.health:1|g|#cluster_name:prod-cluster,network_name:cluster-network-1,...
  >> wsfc.network_interface.health:1|g|#cluster_name:prod-cluster,node_name:node01,...
[16:40:30] Metrics submitted.
[WSFC Monitor] Single collection cycle complete.
```

**Verify in Datadog:**
Metrics → Explorer → search `wsfc.cluster.health`

---

## 5️⃣ Windows Task Scheduler Setup

### Option A — Command Line (Quickest)

```cmd
schtasks /create /tn "WSFC-DogStatsD-Monitor" /sc minute /mo 1 /st 00:00 ^
  /tr "powershell.exe -NonInteractive -ExecutionPolicy Bypass -File C:\Scripts\wsfc-dogstatsd-monitor.ps1 -RunOnce" ^
  /ru SYSTEM /rl HIGHEST /f
```

### Option B — PowerShell (Recommended)

```powershell
$action  = New-ScheduledTaskAction `
    -Execute  'powershell.exe' `
    -Argument '-NonInteractive -ExecutionPolicy Bypass -File "C:\Scripts\wsfc-dogstatsd-monitor.ps1" -RunOnce'

$trigger = New-ScheduledTaskTrigger -AtStartup
$trigger.RepetitionInterval = (New-TimeSpan -Minutes 1)
$trigger.RepetitionDuration = ([TimeSpan]::MaxValue)

$settings = New-ScheduledTaskSettingsSet `
    -MultipleInstances  IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 2) `
    -RestartCount       3 `
    -RestartInterval    (New-TimeSpan -Minutes 1)

Register-ScheduledTask `
    -TaskName 'WSFC-DogStatsD-Monitor' `
    -Action   $action `
    -Trigger  $trigger `
    -Settings $settings `
    -RunLevel Highest `
    -User     'SYSTEM'
```

**Start immediately without rebooting:**

```powershell
Start-ScheduledTask -TaskName 'WSFC-DogStatsD-Monitor'

# Verify it is running
Get-ScheduledTask -TaskName 'WSFC-DogStatsD-Monitor' | Select-Object TaskName, State
# State: Running
```

---

## 6️⃣ Execution Timeline

```text
Server Boot
    └─→ Task fires immediately (AtStartup)
            └─→ Script: collect → submit → exit

60 seconds later
    └─→ Task fires (RepetitionInterval = 1 min)
            └─→ Script: collect → submit → exit

If script hangs/crashes
    └─→ ExecutionTimeLimit (2 min) kills it
    └─→ RestartCount retries within 1 minute

1,440 runs/day
```

> **`-MultipleInstances IgnoreNew`** — if a previous run is still in progress when the next trigger fires, the new instance is silently skipped. Prevents duplicate metrics in Datadog.

---

## 7️⃣ Datadog Monitors

| Monitor | Query | Alert Condition |
|---------|-------|-----------------|
| Cluster Down | `min:wsfc.cluster.health{*} by {cluster_name}` | `< 1` for 3 min |
| Node Down | `min:wsfc.node.health{*} by {node_name}` | `< 1` |
| Nodes Down Count | `max:wsfc.cluster.nodes.down{*} by {cluster_name}` | `>= 1` |
| Witness Offline | `min:wsfc.quorum.witness.health{*} by {cluster_name}` | `< 1` |
| Network Down | `min:wsfc.network.health{*} by {network_name}` | `< 1` |
| NIC Down | `min:wsfc.network_interface.health{*} by {node_name,adapter_name}` | `< 1` |

---

## 8️⃣ Datadog Dashboard Queries

| Widget | Query |
|--------|-------|
| Cluster health status | `avg:wsfc.cluster.health{*} by {cluster_name}` |
| Nodes up count | `avg:wsfc.cluster.nodes.up{*} by {cluster_name}` |
| Nodes down count | `avg:wsfc.cluster.nodes.down{*} by {cluster_name}` |
| Per-node health | `avg:wsfc.node.health{*} by {node_name}` |
| Witness health | `avg:wsfc.quorum.witness.health{*} by {cluster_name,witness_type}` |
| Network health | `avg:wsfc.network.health{*} by {network_name}` |
| Network route metric | `avg:wsfc.network.metric{*} by {network_name}` |
| NIC health per node | `avg:wsfc.network_interface.health{*} by {node_name,adapter_name}` |

---

## 🛡️ Production Features

| Feature | Status |
|---------|--------|
| Cluster health metrics | ✅ |
| Per-node health & state | ✅ |
| Quorum type + witness health | ✅ |
| Witness context as tags (no extra metrics) | ✅ |
| Network segment health | ✅ |
| NIC-level interface health | ✅ |
| Core Group detection (3-level fallback) | ✅ |
| Single-node cluster `.Count` fix (`@()` wrapping) | ✅ |
| `try/catch` pre-computed outside `@{}` literals | ✅ |
| Node/Network as string or object (both handled) | ✅ |
| Pre-flight prerequisite checks with fix guidance | ✅ |
| Optional remote node query via `-ComputerName` | ✅ |
| SYSTEM scheduler compatible | ✅ |
| DogStatsD UDP submission | ✅ |
| `$Hostname` parameter (avoids `$Host` PS conflict) | ✅ |

---

## ✅ Production Checklist

- [ ] Failover Clustering feature installed on all cluster nodes
- [ ] RSAT-Clustering-PowerShell module installed
- [ ] Cluster Service (ClusSvc) running
- [ ] Datadog Agent installed and running
- [ ] DogStatsD listening on `127.0.0.1:8125`
- [ ] Script deployed to `C:\Scripts\wsfc-dogstatsd-monitor.ps1`
- [ ] Script unblocked via `Unblock-File`
- [ ] Script validated manually (`-RunOnce -Verbose`)
- [ ] All 12 metrics visible in Datadog Metrics Explorer
- [ ] Task Scheduler task created and running
- [ ] Datadog monitors created for all 6 health checks
- [ ] Dashboard created

---

## 🚨 Troubleshooting

| Issue | Cause | Fix |
|-------|-------|-----|
| `Cannot overwrite variable Host` | `$Host` is a reserved PS variable | Use `-Hostname` parameter (already fixed) |
| `Invalid namespace ROOT\MSCluster` | Failover Clustering not installed | `Install-WindowsFeature -Name Failover-Clustering -IncludeManagementTools` |
| `FailoverClusters module not found` | RSAT tools not installed | `Install-WindowsFeature -Name RSAT-Clustering-PowerShell` |
| `ClusSvc not found` | Node is not a cluster member | Join node to cluster or run on a cluster node |
| `IsCoreGroup property not found` | Older Windows Server version | Script auto-falls back to `GroupType` then name match |
| `Count property not found` | Single-item CIM result (1-node cluster) | Fixed via `@()` wrapping on all collections |
| `Pipeline has been stopped` | `.Node.Name` / `.Network.Name` type mismatch | Fixed via string/object type check before property access |
| Metrics not appearing in Datadog | Agent not listening | `netstat -an \| findstr 8125` — verify UDP 8125 is open |
| Duplicate metrics | Multiple task instances running | `IgnoreNew` setting prevents overlap |

---

## 📘 Script Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-DogStatsDHost` | `127.0.0.1` | IP/hostname of DogStatsD listener |
| `-DogStatsDPort` | `8125` | UDP port of DogStatsD listener |
| `-ComputerName` | *(local)* | Remote cluster node to query via CimSession |
| `-RunOnce` | *(not set)* | Run single collection cycle and exit |

```powershell
# Examples
.\wsfc-dogstatsd-monitor.ps1                                        # continuous loop
.\wsfc-dogstatsd-monitor.ps1 -RunOnce -Verbose                      # single test run
.\wsfc-dogstatsd-monitor.ps1 -ComputerName NODE02 -RunOnce          # remote node test
.\wsfc-dogstatsd-monitor.ps1 -DogStatsDHost 10.0.0.5 -RunOnce      # custom DogStatsD host
```

---

## 👤 Author

| | |
|--|--|
| **Name** | Shivam Anand |
| **Title** | Sr. DevOps Engineer \| Engineering |
| **Organisation** | Zoos Global |
| **Email** | [shivam.anand@zoosglobal.com](mailto:shivam.anand@zoosglobal.com) |
| **Web** | [www.zoosglobal.com](https://www.zoosglobal.com) |
| **Address** | Violena, Pali Hill, Bandra West, Mumbai - 400050 |

---

<div align="center">

**Version 1.0.0 · Last Updated: April 07, 2026**
© 2026 Zoos Global · <a href="LICENSE">MIT License</a>

</div>
