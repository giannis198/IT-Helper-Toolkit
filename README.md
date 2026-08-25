# IT Helper Toolkit v1.x

A modular collection of Windows diagnostic and repair utilities for IT technicians. Each tool is a single `.bat` file with an embedded PowerShell backend — no installation required, just copy and run.

---

## Quick Start

```cmd
# From the toolkit directory
IT_Helper_Launcher.bat

# Run Self Test first to validate the toolkit
IT_Helper_SelfTest.bat full

# Or run any tool directly
IT_Helper_Network.bat repair
IT_Helper_PC_Support.bat quick
```

---

## Requirements

- **Windows 10/11** or **Windows Server 2019/2022/2025**
- **PowerShell 5.1+** (built-in)
- **Administrator privileges** (auto-elevates via UAC)
- Run from a **local directory** (not a network share)

---

## Tools Overview

| # | Tool | File | Description |
|---|------|------|-------------|
| 1 | **Network Fixer** | `IT_Helper_Network.bat` | IP/DNS/Winsock/TCP reset + full network diagnostics |
| 2 | **PC Quick Support** | `IT_Helper_PC_Support.bat` | 30-60 sec system snapshot (OS, hardware, network, services) |
| 3 | **Printer Fixer** | `IT_Helper_Printer.bat` | Spooler, queues, drivers, TCP ports (9100/631/515/443) |
| 4 | **RDP Troubleshooter** | `IT_Helper_RDP.bat` | Service, firewall, port 3389, NLA, users, remote tests |
| 5 | **Windows Repair** | `IT_Helper_WindowsRepair.bat` | SFC/DISM/CHKDSK/Windows Update repair |
| 6 | **Backup Helper** | `IT_Helper_Backup.bat` | Robocopy backup/mirror/verify/compare with logging |
| 7 | **Network Scanner** | `IT_Helper_NetworkScanner.bat` | LAN discovery, ping sweep, ARP, ports, device detection |
| 8 | **USB/Device Helper** | `IT_Helper_Device.bat` | USB, PnP errors, controllers, storage, hardware scan |
| 9 | **Server Health** | `IT_Helper_Server.bat` | AD/DNS/DHCP/IIS/SQL + core server diagnostics |
| 10 | **Self Test** | `IT_Helper_SelfTest.bat` | **Validate entire toolkit before use** |
| 11 | **Launcher** | `IT_Helper_Launcher.bat` | Unified menu for all tools |

---

## Usage Modes

### Interactive Menu (Default)

Double-click any `.bat` file or run without arguments:

```cmd
IT_Helper_Network.bat
```

### CLI Mode (Automation)

Run with a mode argument:

```cmd
IT_Helper_Network.bat repair
IT_Helper_PC_Support.bat quick
IT_Helper_Printer.bat stuck
```

### Run Self Test First (Recommended)

```cmd
# Full validation of entire toolkit
IT_Helper_SelfTest.bat full

# Quick environment + core commands check
IT_Helper_SelfTest.bat quick

# Validate embedded payloads only
IT_Helper_SelfTest.bat payload

# Environment check only
IT_Helper_SelfTest.bat env
```

### Available Modes per Tool

#### Network Fixer (`IT_Helper_Network.bat`)

| Mode | Description |
|------|-------------|
| `config` | Network configuration (IP, gateway, DNS, DHCP lease) |
| `gateway` | Test default gateway |
| `internet` | Internet diagnostic (DNS → HTTPS → ICMP) |
| `dns` | DNS diagnostic (4 domains + latency) |
| `dhcp` | DHCP diagnostic (server, lease times) |
| `arp` | ARP/Neighbor table |
| `route` | IPv4 routing table |
| `profile` | Network profiles (Domain/Private/Public) |
| `host` | Test specific host (ping) |
| `port` | Test TCP port |
| `flushdns` | Flush DNS cache |
| `renew` | Renew DHCP (DHCP adapters only) |
| `winsock` | Reset Winsock |
| `tcpip` | Reset TCP/IP stack |
| `setdns` | Set custom DNS (with presets) |
| `repair` | **Full network repair** (DHCP-aware, per-step tracking) |
| `report` | Full network report |

#### PC Quick Support (`IT_Helper_PC_Support.bat`)

| Mode | Description |
|------|-------------|
| `quick` | Quick system snapshot (default) |
| `report` | Full detailed report |

#### Printer Fixer (`IT_Helper_Printer.bat`)

| Mode | Description |
|------|-------------|
| `list` | List all printers |
| `spooler` | Test/restart spooler |
| `queue` | Show print queue |
| `ports` | Show printer ports |
| `drivers` | Show printer drivers |
| `testip` | Test printer IP (ping) |
| `testport` | Test printer TCP ports (9100/631/515/443) |
| `stuck` | Remove stuck jobs |
| `diag` | Full printer diagnostic |
| `report` | Full printer report |

#### RDP Troubleshooter (`IT_Helper_RDP.bat`)

| Mode | Description |
|------|-------------|
| `enabled` | Check RDP enabled |
| `service` | Check TermService |
| `firewall` | Check RDP firewall rules |
| `port` | Check TCP 3389 |
| `profile` | Check network profiles |
| `nla` | Check NLA |
| `users` | Check Remote Desktop Users |
| `host` | Test remote host (ping + TCP 3389) |
| `rport` | Test custom remote port |
| `diag` | Full RDP diagnostic |
| `report` | Full RDP report |

#### Windows Repair (`IT_Helper_WindowsRepair.bat`)

| Mode | Description |
|------|-------------|
| `sfc_v` | SFC verify only |
| `sfc_r` | SFC /scannow |
| `dism_c` | DISM CheckHealth |
| `dism_s` | DISM ScanHealth |
| `dism_r` | DISM RestoreHealth |
| `chkdsk` | CHKDSK read-only |
| `wu_diag` | Windows Update diagnostic |
| `wu_reset` | Reset Windows Update components |
| `store` | Component Store cleanup |
| `full` | Full Windows Repair |
| `report` | Full repair report |

#### Backup Helper (`IT_Helper_Backup.bat`)

| Mode | Description |
|------|-------------|
| `backup` | Backup folder (incremental) |
| `mirror` | Mirror folder (exact copy, deletes extras) |
| `profile` | Backup user profile (Documents, Desktop, Pictures...) |
| `docs` | Backup Documents |
| `desktop` | Backup Desktop |
| `verify` | Verify backup (what would copy) |
| `compare` | Compare source vs destination |
| `log` | View recent backup logs |

#### Network Scanner (`IT_Helper_NetworkScanner.bat`)

| Mode | Description |
|------|-------------|
| `subnet` | Detect local subnet |
| `ping` | Ping sweep |
| `host` | Resolve hostnames |
| `mac` | Get MAC addresses (ARP) |
| `ports` | Scan common ports |
| `router` | Find routers |
| `printer` | Find printers |
| `windows` | Find Windows PCs |
| `csv` | Export to CSV |
| `full` | Full scan (all above) |

#### USB/Device Helper (`IT_Helper_Device.bat`)

| Mode | Description |
|------|-------------|
| `usb` | List USB devices |
| `problems` | Show problem devices |
| `errors` | Device Manager errors (detailed) |
| `controllers` | USB controllers/hubs |
| `storage` | Storage devices |
| `pnp` | PnP events (last 24h) |
| `refresh` | Scan for hardware changes |
| `report` | Full device report |

#### Server Health (`IT_Helper_Server.bat`)

| Mode | Description |
|------|-------------|
| `os` | OS/Build info |
| `hw` | CPU/RAM |
| `storage` | Storage/RAID/Volumes |
| `net` | Network (adapters, teams, IP) |
| `rdp` | RDP status |
| `services` | Critical services |
| `wu` | Windows Update |
| `events` | Event logs (System, App, Security) |
| `ad` | AD Health (replication, FSMO) |
| `dns` | DNS Health |
| `dhcp` | DHCP Health |
| `iis` | IIS Health |
| `sql` | SQL Health |
| `full` | Full server report |

#### Self Test (`IT_Helper_SelfTest.bat`)

| Mode | Description |
|------|-------------|
| `full` | Full validation (all checks + payload validation) |
| `quick` | Quick validation (env + core commands + tool files) |
| `payload` | Embedded payload syntax validation only |
| `env` | Environment check only (OS, PS version, admin, paths) |

---

## Output & Reports

Each run creates a folder under:

```
C:\ITHelper\Reports\<Tool>_<COMPUTERNAME>_<TIMESTAMP>\
```

Contains:

| File | Description |
|------|-------------|
| `report.txt` | Human-readable diagnostic report |
| `summary.csv` | Machine-parseable results (Timestamp, Host, User, IP, Group, Check, Status, Detail) |
| `session.log` | Full PowerShell transcript |

### Status Values

| Status | Meaning |
|--------|---------|
| `PASS` | Check passed |
| `WARN` | Warning — review recommended |
| `FAIL` | Check failed — action required |
| `INFO` | Informational |
| `SKIP` | Check skipped (not applicable) |

---

## Architecture

Each tool follows the same pattern:

```
.bat launcher (handles UAC elevation, payload extraction)
    ↓
Embedded PowerShell backend (extracted to %TEMP%)
    ↓
Runs with explicit -DoneFlag temp file (survives UAC boundary)
    ↓
Writes reports to C:\ITHelper\Reports\
```

### Key Design Decisions

- **Single-file deployment** — no external dependencies
- **UAC-safe** — temp paths created *after* elevation; `-DoneFlag` passed explicitly
- **Confirmation required** — all destructive actions need `Type YES`
- **Crash guard** — if tool crashes, window stays open with error log
- **Filesystem flush delay** — 1-second delay after PowerShell exit to allow DoneFlag file to flush
- **Exit codes** — returns `min(fail_count, 250)` for CI/CD

---

## Common Tasks

### Run Self Test first (recommended)

```cmd
IT_Helper_SelfTest.bat full
```

### Run full network repair (elevated)

```cmd
IT_Helper_Network.bat repair
```

### Quick PC health check

```cmd
IT_Helper_PC_Support.bat quick
```

### Backup Documents to NAS

```cmd
IT_Helper_Backup.bat docs
# Prompts for destination
```

### Scan local network

```cmd
IT_Helper_NetworkScanner.bat full
```

### Check RDP readiness

```cmd
IT_Helper_RDP.bat diag
```

### Full server health report

```cmd
IT_Helper_Server.bat full
```

---

## Troubleshooting

| Issue | Solution |
|-------|----------|
| "Access denied" | Run as Administrator (tools auto-elevate) |
| Tool crashes immediately | Check `C:\ITHelper\Reports\...\session.log` |
| Network tool shows no adapters | Ensure running elevated; check `Get-NetAdapter` manually |
| Backup fails with Robocopy errors | Check `robocopy.log` in report folder |
| Printer tool finds no printers | Ensure Print Spooler service is running |
| Tool appears to crash on completion | Fixed in v1.2 — filesystem flush delay added; check `session.log` |

---

## Files

```
IT_Helper_Launcher.bat          # Unified menu
IT_Helper_Network.bat           # Network Fixer v1.2
IT_Helper_PC_Support.bat        # PC Quick Support
IT_Helper_Printer.bat           # Printer Fixer
IT_Helper_RDP.bat               # RDP Troubleshooter
IT_Helper_WindowsRepair.bat     # Windows Repair
IT_Helper_Backup.bat            # Backup Helper
IT_Helper_NetworkScanner.bat    # Network Scanner
IT_Helper_Device.bat            # USB/Device Helper
IT_Helper_Server.bat            # Server Health Check
IT_Helper_SelfTest.bat          # Self Test (validate toolkit)
README.md                       # This file
```

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.3 | 2026-08-25 | Added Self Test tool; fixed crash-on-completion (filesystem flush delay); launcher updated |
| 1.2 | 2026-08-24 | Network Fixer: DHCP-aware repair, per-step tracking, DNS presets, IPv4 regex |
| 1.1 | 2026-08-24 | Stabilization: syntax fixes, Robocopy parser, UAC paths, exit codes |
| 1.0 | 2026-08-24 | Initial release: 10 tools with unified architecture |

---

## License

Internal IT support toolkit. Use responsibly — repair actions can modify system state.

---

## Support

For issues, check the session log in the report folder. The crash guard keeps the window open on failure with error details.
