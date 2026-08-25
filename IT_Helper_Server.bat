@echo off
setlocal EnableExtensions
title IT Helper Toolkit - Server Health Check
color 0B

rem ============================================================
rem  IT HELPER TOOLKIT - SERVER HEALTH CHECK
rem  Single-file: .bat launcher + embedded PowerShell backend
rem  Compatible: Windows Server 2019/2022/2025
rem
rem  Usage:
rem    IT_Helper_Server.bat           interactive menu
rem    IT_Helper_Server.bat os        OS / Build info
rem    IT_Helper_Server.bat hw        CPU / RAM / Disks
rem    IT_Helper_Server.bat storage   RAID / Storage
rem    IT_Helper_Server.bat net       Network
rem    IT_Helper_Server.bat rdp       RDP
rem    IT_Helper_Server.bat services  Critical services
rem    IT_Helper_Server.bat wu        Windows Update
rem    IT_Helper_Server.bat events    Event logs
rem    IT_Helper_Server.bat ad        AD Health
rem    IT_Helper_Server.bat dns       DNS Health
rem    IT_Helper_Server.bat dhcp      DHCP Health
rem    IT_Helper_Server.bat iis       IIS Health
rem    IT_Helper_Server.bat sql       SQL Services
rem    IT_Helper_Server.bat full      Full server report
rem    Exit code: number of FAILED checks
rem ============================================================

rem ---------- Admin check / self-elevation ----------
rem NOTE: an elevated process gets a FRESH environment rebuilt from the
rem registry, so nothing "set" here survives the RunAs boundary. The mode
rem argument is forwarded explicitly via -ArgumentList and re-read from
rem %%~1 inside the elevated instance below.
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges...
    if "%~1"=="" (
        powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    ) else (
        powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '%~1' -Verb RunAs"
    )
    exit /b 1
)

rem Elevated instance: recover the mode argument from its own command line
if not "%~1"=="" set "ITH_MODE=%~1"

mkdir "C:\ITHelper\Reports" >nul 2>&1

rem ---------- Extract embedded PowerShell payload ----------
rem These paths are created HERE on purpose, inside the instance that will
rem actually run the payload: plain "set" variables ARE inherited by child
rem processes of this same instance (extraction step + powershell.exe below),
rem and because they are built after elevation they can never be lost at the
rem UAC boundary. ITH_FLAG additionally travels explicitly as -DoneFlag.
set "ITH_PS=%TEMP%\ITH_Srv_%RANDOM%%RANDOM%.ps1"
set "ITH_ERR=%TEMP%\ITH_Srv_err_%RANDOM%.log"
set "ITH_FLAG=%TEMP%\ITH_Srv_done_%RANDOM%.flag"
powershell -NoProfile -Command "$c = Get-Content -LiteralPath '%~f0'; $m = $c | Select-String -Pattern '^#__PS_PAYLOAD__' | Select-Object -First 1; if (-not $m) { throw 'payload marker missing' }; $c[$m.LineNumber..($c.Count - 1)] | Set-Content -LiteralPath '%ITH_PS%' -Encoding UTF8"

if not exist "%ITH_PS%" (
    color CF
    echo ERROR: could not extract PowerShell backend.
    echo Check that the file was copied fully and is named *.bat
    echo.
    pause
    exit /b 1
)

rem ---------- Run ----------
powershell -NoProfile -ExecutionPolicy Bypass -File "%ITH_PS%" %ITH_MODE% -DoneFlag "%ITH_FLAG%" 2>"%ITH_ERR%"
set "ITH_RC=%errorlevel%"

rem ---------- Crash guard: if the tool died, DO NOT close ----------
if not exist "%ITH_FLAG%" (
    color CF
    echo.
    echo ============================================================
    echo  THE TOOL TERMINATED ABNORMALLY ^(exit code %ITH_RC%^)
    echo ============================================================
    echo.
    echo --- PowerShell error output: ---
    if exist "%ITH_ERR%" type "%ITH_ERR%"
    echo.
    echo Session log: C:\ITHelper\Reports\^<run-folder^>\session.log
    echo Please screenshot this window when reporting the problem.
    echo.
    pause
)

del "%ITH_PS%" >nul 2>&1
del "%ITH_ERR%" >nul 2>&1
del "%ITH_FLAG%" >nul 2>&1
color
exit /b %ITH_RC%

#__PS_PAYLOAD__
#Requires -Version 5.1
# ==================================================================
#  IT Helper Toolkit - Server Health Check (backend)
# ==================================================================
param(
    [Parameter(Position = 0)]
    [ValidateSet('menu', 'os', 'hw', 'storage', 'net', 'rdp', 'services', 'wu', 'events', 'ad', 'dns', 'dhcp', 'iis', 'sql', 'full')]
    [string]$Mode = 'menu',

    # Explicit flag path handed over by the launcher. Travels as a
    # command-line argument, so it survives the UAC boundary; falls back
    # to the env var when this backend is run standalone.
    [string]$DoneFlag = $env:ITH_FLAG
)

$ErrorActionPreference = 'Continue'
$ToolVersion = '1.0'
$Stamp   = Get-Date -Format 'yyyyMMdd_HHmmss'
$RunDir  = Join-Path 'C:\ITHelper\Reports' ('ServerHealth_{0}_{1}' -f $env:COMPUTERNAME, $Stamp)
$TxtPath = Join-Path $RunDir 'report.txt'
$CsvPath = Join-Path $RunDir 'summary.csv'
New-Item -ItemType Directory -Path $RunDir -Force | Out-Null

$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

$script:PrimaryIP = 'N/A'
try {
    $nic = Get-NetIPConfiguration -ErrorAction Stop |
        Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } |
        Select-Object -First 1
    if ($nic) { $script:PrimaryIP = $nic.IPv4Address.IPAddress }
} catch { }

try { Start-Transcript -Path (Join-Path $RunDir 'session.log') -ErrorAction SilentlyContinue | Out-Null } catch { }

# ------------------------- helpers -------------------------------

function Set-DoneFlag {
    if ($DoneFlag) {
        try { New-Item -ItemType File -Path $DoneFlag -Force -ErrorAction SilentlyContinue | Out-Null } catch { }
    }
}

function Log {
    param([string]$Text = '', [string]$Color = 'White')
    Write-Host $Text -ForegroundColor $Color
    Add-Content -LiteralPath $TxtPath -Value $Text
}

function Add-Summary {
    param(
        [string]$Check,
        [string]$Status,
        [string]$Detail = ''
    )
    $script:Results.Add([pscustomobject]@{
        Timestamp = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Hostname  = $env:COMPUTERNAME
        User      = ('{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME)
        IP        = $script:PrimaryIP
        Group     = $script:CurrentGroup
        Check     = $Check
        Status    = $Status
        Detail    = $Detail
    }) | Out-Null
}

function Test-TcpPort {
    param([string]$Target, [int]$Port, [int]$TimeoutMs = 3000)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $ar = $client.BeginConnect($Target, $Port, $null, $null)
        if ($ar.AsyncWaitHandle.WaitOne($TimeoutMs) -and $client.Connected) { return $true }
        return $false
    } catch {
        return $false
    } finally {
        if ($client -and $client.Connected) { $client.Close() }
        $client.Dispose()
    }
}

function Is-RoleInstalled {
    param([string]$Name)
    try { return (Get-WindowsFeature -Name $Name -ErrorAction Stop).Installed } catch { return $false }
}

function Start-Run {
    param([string]$GroupLabel, [scriptblock]$Pipeline)
    $script:Results = New-Object System.Collections.Generic.List[object]
    Log ('=' * 62) DarkCyan
    Log ('  IT HELPER SERVER HEALTH CHECK v' + $ToolVersion + '  -  GROUP: ' + $GroupLabel) Cyan
    $hdr = '  Host: {0}   User: {1}\{2}   IP: {3}   Admin: {4}' -f $env:COMPUTERNAME, $env:USERDOMAIN, $env:USERNAME, $script:PrimaryIP, $IsAdmin
    Log $hdr Gray
    Log ('  Started: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) Gray
    Log ('=' * 62) DarkCyan
    & $Pipeline
    Complete-Run -GroupLabel $GroupLabel
}

function Complete-Run {
    param([string]$GroupLabel)
    $pass = @($script:Results | Where-Object Status -eq 'PASS').Count
    $warn = @($script:Results | Where-Object Status -eq 'WARN').Count
    $fail = @($script:Results | Where-Object Status -eq 'FAIL').Count
    $info = @($script:Results | Where-Object Status -eq 'INFO').Count

    $script:Results | Export-Csv -LiteralPath $CsvPath -NoTypeInformation -Encoding UTF8

    $overall = 'HEALTHY'
    if     ($fail -gt 0) { $overall = 'PROBLEMS FOUND - ' + $fail + ' FAIL ITEM(S)' }
    elseif ($warn -gt 0) { $overall = 'HEALTHY - ' + $warn + ' ITEM(S) TO REVIEW' }

    Log ''
    Log '+============================================+' Cyan
    Log '|         SERVER HEALTH CHECK RESULT         |' Cyan
    Log '+============================================+' Cyan
    Log ('|  PASS: {0,4}   INFO: {1,4}   WARN: {2,4}   FAIL: {3,4} |' -f $pass, $info, $warn, $fail) White
    Log '+--------------------------------------------+' Cyan
    $overallColor = if ($fail -gt 0) { 'Red' } elseif ($warn -gt 0) { 'Yellow' } else { 'Green' }
    Log ('|  Overall: ' + $overall.PadRight(34) + '|') $overallColor
    Log '+============================================+' Cyan
    Log (' Report : ' + $TxtPath)
    Log (' CSV    : ' + $CsvPath)
    Log (' Folder : ' + $RunDir) Gray

    if ($Mode -eq 'menu') {
        Set-DoneFlag
        $open = Read-Host ' Open report folder in Explorer? (y/n)'
        if ($open -eq 'y') { Start-Process explorer.exe -ArgumentList ('"' + $RunDir + '"') }
    } else {
        Set-DoneFlag
        try { Stop-Transcript | Out-Null } catch { }
        exit ([Math]::Min($fail, 250))
    }
}

# ------------------------- server sections ------------------------------

function Section-OsInfo {
    $os  = Get-CimInstance Win32_OperatingSystem
    $cs  = Get-CimInstance Win32_ComputerSystem
    $ver = [Environment]::OSVersion.Version
    $up  = (Get-Date) - $os.LastBootUpTime

    Log ''
    Log ('=' * 56) DarkCyan
    Log ('  OS / BUILD INFORMATION') Cyan
    Log ('=' * 56) DarkCyan
    Log ('  Computer          : {0} {1}' -f $cs.Manufacturer, $cs.Model)
    Log ('  OS                : {0}' -f $os.Caption.Trim())
    Log ('  Version           : {0}' -f $ver.ToString())
    Log ('  Build             : {0}' -f $os.BuildNumber)
    Log ('  Install Date      : {0}' -f $os.InstallDate)
    Log ('  Uptime            : {0}d {1:D2}h {2:D2}m' -f [int]$up.Days, $up.Hours, $up.Minutes)
    Log ('  Last Boot         : {0}' -f $os.LastBootUpTime)
    Log ('  Product Type      : {0}' -f $os.ProductType)
    Log ('  Domain Role       : {0}' -f $cs.DomainRole)
    Log ('  Total RAM         : {0} GB' -f [math]::Round($cs.TotalPhysicalMemory/1GB, 1))

    Add-Summary 'OS Version' 'INFO' ('{0} build {1}' -f $os.Caption.Trim(), $os.BuildNumber)
    if ($up.TotalDays -gt 90) {
        Add-Summary 'Uptime' 'WARN' ('{0:N0} days since last boot' -f $up.TotalDays)
    } else {
        Add-Summary 'Uptime' 'INFO' ('{0:N1} hours' -f $up.TotalHours)
    }
}

function Section-Hardware {
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $os  = Get-CimInstance Win32_OperatingSystem
    $load = if ($cpu.LoadPercentage) { $cpu.LoadPercentage } else { 0 }
    $totGB  = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
    $freeGB = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
    $freePct = if ($totGB) { [math]::Round($freeGB / $totGB * 100, 1) } else { 0 }

    Log ''
    Log ('=' * 56) DarkCyan
    Log ('  CPU / RAM') Cyan
    Log ('=' * 56) DarkCyan
    Log ('  CPU       : {0}' -f $cpu.Name.Trim())
    Log ('  Load      : {0} percent  ({1} cores / {2} threads)' -f $load, $cpu.NumberOfCores, $cpu.NumberOfLogicalProcessors)
    Log ('  RAM       : {0} GB total / {1} GB free ({2} percent free)' -f $totGB, $freeGB, $freePct)

    $s = if ($load -ge 90) { 'WARN' } else { 'PASS' }
    Add-Summary 'CPU Load' $s ('{0} percent' -f $load)
    $s = if ($freePct -lt 10) { 'WARN' } elseif ($freePct -lt 20) { 'INFO' } else { 'PASS' }
    Add-Summary 'RAM Free' $s ('{0} GB free of {1} GB' -f $freeGB, $totGB)
}

function Section-StorageServer {
    Log ''
    Log ('=' * 56) DarkCyan
    Log ('  STORAGE / RAID') Cyan
    Log ('=' * 56) DarkCyan

    try {
        $disks = Get-PhysicalDisk -ErrorAction Stop
        $rows = $disks | Select-Object FriendlyName, MediaType, BusType,
            @{n='SizeGB';e={[math]::Round($_.Size/1GB)}}, HealthStatus, OperationalStatus
        Log (($rows | Format-Table -AutoSize | Out-String).TrimEnd())
        foreach ($d in $disks) {
            $s = if ($d.HealthStatus -eq 'Healthy') { 'PASS' } elseif ($d.HealthStatus -eq 'Warning') { 'WARN' } else { 'FAIL' }
            Add-Summary 'Disk Health' $s ("{0}: {1}" -f $d.FriendlyName, $d.HealthStatus)
        }
    } catch {
        Log '  Get-PhysicalDisk not available.' Yellow
    }

    try {
        $pools = Get-StoragePool -IsPrimordial $false -ErrorAction Stop
        if ($pools) {
            Log ''
            Log '  Storage Pools:' Gray
            foreach ($p in $pools) {
                $vd = Get-VirtualDisk -StoragePoolFriendlyName $p.FriendlyName -ErrorAction SilentlyContinue
                Log ("  Pool: {0} - {1} - Health: {2}" -f $p.FriendlyName, $p.OperationalStatus, $p.HealthStatus)
                if ($vd) {
                    $vd | Select-Object FriendlyName, Size, ResiliencySettingName, HealthStatus, OperationalStatus | Format-Table -AutoSize | Out-Default
                }
            }
        }
    } catch { }

    try {
        $vols = Get-Volume -ErrorAction Stop | Where-Object { $_.DriveLetter } |
            Select-Object DriveLetter, FileSystemLabel, FileSystem,
                @{n='SizeGB';e={if($_.Size){[math]::Round($_.Size/1GB,1)}}}, HealthType, OperationalStatus
        Log (($vols | Format-Table -AutoSize | Out-String).TrimEnd())
    } catch { }
}

function Section-NetworkServer {
    Log ''
    Log ('=' * 56) DarkCyan
    Log ('  NETWORK') Cyan
    Log ('=' * 56) DarkCyan

    $adapters = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' }
    if ($adapters) {
        Log (($adapters | Select-Object Name, InterfaceDescription, LinkSpeed, MacAddress, Status | Format-Table -AutoSize | Out-String).TrimEnd())
    }

    $ipconfs = Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway }
    foreach ($ipc in $ipconfs) {
        Log ('  [{0}]' -f $ipc.InterfaceAlias) Cyan
        Log ('    IPv4    : {0}' -f $ipc.IPv4Address.IPAddress)
        Log ('    Gateway : {0}' -f ($ipc.IPv4DefaultGateway.NextHop -join ', '))
        Log ('    DNS     : {0}' -f ($ipc.DNSServer.ServerAddresses -join ', '))
    }

    try {
        $teams = Get-NetLbfoTeam -ErrorAction Stop
        if ($teams) {
            Log ''
            Log '  NIC Teams:' Gray
            Log (($teams | Select-Object Name, Members, TeamingMode, LoadBalancingAlgorithm | Format-Table -AutoSize | Out-String).TrimEnd())
        }
    } catch { }
}

function Section-RDPServer {
    Log ''
    Log ('=' * 56) DarkCyan
    Log ('  RDP') Cyan
    Log ('=' * 56) DarkCyan
    try {
        $rdp = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -ErrorAction Stop).fDenyTSConnections
        $state = if ($rdp -eq 0) { 'ENABLED' } else { 'DISABLED' }
        Log ('  Remote Desktop: {0}' -f $state)
        Add-Summary 'RDP' $(if ($rdp -eq 0) { 'PASS' } else { 'FAIL' }) $state
    } catch { Add-Summary 'RDP' 'FAIL' 'Registry not readable' }

    $svc = Get-Service -Name 'TermService' -ErrorAction SilentlyContinue
    if ($svc) {
        Log ('  TermService: {0}' -f $svc.Status)
        Add-Summary 'TermService' $(if ($svc.Status -eq 'Running') { 'PASS' } else { 'FAIL' }) $svc.Status
    }

    try {
        $nla = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name UserAuthentication -ErrorAction Stop).UserAuthentication
        Log ('  NLA: {0}' -f $(if ($nla -eq 1) { 'Enabled' } else { 'Disabled' }))
        Add-Summary 'NLA' $(if ($nla -eq 1) { 'PASS' } else { 'WARN' }) $(if ($nla -eq 1) { 'Enabled' } else { 'Disabled' })
    } catch { }

    $fw = Get-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction SilentlyContinue | Where-Object Enabled
    Add-Summary 'RDP Firewall' $(if ($fw) { 'PASS' } else { 'FAIL' }) $(if ($fw) { '{0} rules' -f @($fw).Count } else { 'No rules' })
}

function Section-CriticalServices {
    Log ''
    Log ('=' * 56) DarkCyan
    Log ('  CRITICAL SERVICES') Cyan
    Log ('=' * 56) DarkCyan

    $criticalList = @('wuauserv', 'BITS', 'Dhcp', 'Dnscache',
                      'LanmanServer', 'LanmanWorkstation', 'EventLog',
                      'Schedule', 'ProfSvc', 'CryptSvc', 'Spooler',
                      'WinRM', 'W32Time', 'Netlogon')

    $allOk = $true
    foreach ($name in $criticalList) {
        $sv = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($sv) {
            $s = if ($sv.Status -eq 'Running') { 'PASS' } else { $allOk = $false; 'FAIL' }
            Log ('  [{0}] {1} - {2}' -f $sv.Status, $name, $sv.DisplayName)
            Add-Summary "Service: $name" $s $sv.DisplayName
        } else {
            Log ('  [NOT FOUND] {0}' -f $name) Yellow
            Add-Summary "Service: $name" 'INFO' 'Not installed'
        }
    }
    if ($allOk) { Log '  All critical services running.' Green }
}

function Section-WUServer {
    Log ''
    Log ('=' * 56) DarkCyan
    Log ('  WINDOWS UPDATE') Cyan
    Log ('=' * 56) DarkCyan
    $svc = Get-Service -Name 'wuauserv' -ErrorAction SilentlyContinue
    if ($svc) { Log ('  wuauserv: {0}' -f $svc.Status) }

    $hf = @(Get-HotFix -ErrorAction SilentlyContinue | Sort-Object InstalledOn -Descending)
    if ($hf.Count -eq 0) {
        Log '  No hotfix history.' Yellow
        Add-Summary 'WU History' 'INFO' 'Empty'
        return
    }
    Log (($hf | Select-Object -First 10 HotFixID, Description, InstalledOn | Format-Table -AutoSize | Out-String).TrimEnd())
    $last = $hf | Where-Object { $_.InstalledOn } | Select-Object -First 1
    if ($last) {
        $days = [int]((Get-Date) - $last.InstalledOn).TotalDays
        $s = if ($days -gt 90) { 'WARN' } else { 'PASS' }
        Add-Summary 'Last Update' $s ('{0} ({1:yyyy-MM-dd}, {2} days)' -f $last.HotFixID, $last.InstalledOn, $days)
    }
}

function Section-EventLogsServer {
    Log ''
    Log ('=' * 56) DarkCyan
    Log ('  EVENT LOGS (last 24h)') Cyan
    Log ('=' * 56) DarkCyan
    foreach ($logName in 'System', 'Application', 'Security') {
        $evts = @()
        try {
            $evts = @(Get-WinEvent -FilterHashtable @{ LogName = $logName; Level = 1, 2; StartTime = (Get-Date).AddDays(-1) } -MaxEvents 500 -ErrorAction Stop)
        } catch { }
        Log ("  [{0}] {1} error/critical event(s)" -f $logName, $evts.Count)
        if ($evts.Count -gt 0) {
            $top = $evts | Group-Object ProviderName | Sort-Object Count -Descending | Select-Object -First 5 Count, Name
            Log (($top | Format-Table -AutoSize | Out-String).TrimEnd())
            Add-Summary ("Events {0}" -f $logName) $(if ($evts.Count -gt 50) { 'WARN' } else { 'INFO' }) ("{0} events" -f $evts.Count)
        } else {
            Add-Summary ("Events {0}" -f $logName) 'PASS' 'No errors'
        }
    }
}

function Section-ADHealth {
    if (-not (Is-RoleInstalled 'AD-Domain-Services')) {
        Log '  AD Domain Services role NOT installed.' Gray
        Add-Summary 'AD Health' 'INFO' 'Role not installed'
        return
    }
    Log ''
    Log ('=' * 56) DarkCyan
    Log ('  AD HEALTH') Cyan
    Log ('=' * 56) DarkCyan

    try {
        $forest = (Get-ADForest -ErrorAction Stop)
        Log ('  Forest: {0}' -f $forest.Name)
        Log ('  Forest Mode: {0}' -f $forest.ForestMode)
    } catch { }

    try {
        $domain = (Get-ADDomain -ErrorAction Stop)
        Log ('  Domain: {0}' -f $domain.DNSRoot)
        Log ('  Domain Mode: {0}' -f $domain.DomainMode)
        Log ('  PDC Emulator: {0}' -f $domain.PDCEmulator)
    } catch { }

    try {
        $reps = repadmin /showrepl * /csv 2>$null | ConvertFrom-Csv
        if ($reps) {
            $fail = @($reps | Where-Object { $_.'Last Result' -ne '0' })
            if ($fail.Count -gt 0) {
                Log ('  REPLICATION ERRORS: {0}' -f $fail.Count) Red
                $fail | Select-Object 'Source DSA', 'Naming Context', 'Last Result', 'Last Attempt' | Format-Table -AutoSize | Out-Default
                Add-Summary 'AD Replication' 'FAIL' ("{0} errors" -f $fail.Count)
            } else {
                Log '  Replication: OK' Green
                Add-Summary 'AD Replication' 'PASS' 'OK'
            }
        }
    } catch {
        Log '  repadmin not available or failed.' Yellow
    }

    try {
        $fsmo = netdom query fsmo 2>$null
        if ($fsmo) { Log ('  FSMO Roles:'); $fsmo | ForEach-Object { Log "    $_" } }
    } catch { }
}

function Section-DNSHealth {
    if (-not (Is-RoleInstalled 'DNS')) {
        Log '  DNS Server role NOT installed.' Gray
        Add-Summary 'DNS Health' 'INFO' 'Role not installed'
        return
    }
    Log ''
    Log ('=' * 56) DarkCyan
    Log ('  DNS HEALTH') Cyan
    Log ('=' * 56) DarkCyan

    try {
        $zones = Get-DnsServerZone -ErrorAction Stop | Where-Object { $_.ZoneType -eq 'Primary' -or $_.ZoneType -eq 'Secondary' }
        Log ("  Zones: {0}" -f @($zones).Count)
        foreach ($z in $zones) {
            Log ("    {0} ({1})" -f $z.ZoneName, $z.ZoneType)
        }
    } catch { Log '  Could not query zones.' Yellow }

    try {
        $stats = Get-DnsServerStatistics -ErrorAction Stop
        Log ("  Queries: {0}" -f $stats.TotalQueries)
        Log ("  Responses: {0}" -f $stats.TotalResponses)
    } catch { }

    $ok = $false
    try { $r = Resolve-DnsName $env:USERDNSDOMAIN -Type A -ErrorAction Stop; $ok = $true } catch { }
    Add-Summary 'DNS Resolution' $(if ($ok) { 'PASS' } else { 'FAIL' }) $env:USERDNSDOMAIN
}

function Section-DHCPHealth {
    if (-not (Is-RoleInstalled 'DHCP')) {
        Log '  DHCP Server role NOT installed.' Gray
        Add-Summary 'DHCP Health' 'INFO' 'Role not installed'
        return
    }
    Log ''
    Log ('=' * 56) DarkCyan
    Log ('  DHCP HEALTH') Cyan
    Log ('=' * 56) DarkCyan

    try {
        $scopes = Get-DhcpServerv4Scope -ErrorAction Stop
        Log ("  Scopes: {0}" -f @($scopes).Count)
        foreach ($s in $scopes) {
            $stats = Get-DhcpServerv4ScopeStatistics -ScopeId $s.ScopeId -ErrorAction SilentlyContinue
            Log ("    {0} - {1} - InUse: {2} Free: {3}" -f $s.ScopeId.IPAddressToString, $s.Name, $stats.InUseAddresses, $stats.FreeAddresses)
        }
    } catch { Log '  Could not query scopes.' Yellow }
}

function Section-IISHealth {
    if (-not (Is-RoleInstalled 'Web-Server')) {
        Log '  IIS (Web Server) role NOT installed.' Gray
        Add-Summary 'IIS Health' 'INFO' 'Role not installed'
        return
    }
    Log ''
    Log ('=' * 56) DarkCyan
    Log ('  IIS HEALTH') Cyan
    Log ('=' * 56) DarkCyan

    try {
        Import-Module WebAdministration -ErrorAction Stop
        $sites = Get-Website -ErrorAction Stop
        Log ("  Sites: {0}" -f @($sites).Count)
        foreach ($s in $sites) {
            Log ("    [{0}] {1} - {2} - {3}" -f $s.State, $s.Name, $s.PhysicalPath, ($s.Bindings.Collection | ForEach-Object { $_.BindingInformation }) -join ', ')
        }

        $pools = Get-ChildItem IIS:\AppPools -ErrorAction Stop
        Log ("  App Pools: {0}" -f @($pools).Count)
        foreach ($p in $pools) {
            Log ("    [{0}] {1} - {2}" -f $p.state, $p.Name, $p.managedRuntimeVersion)
        }
    } catch { Log '  WebAdministration module not available.' Yellow }
}

function Section-SQLHealth {
    $sqlSvc = Get-Service -Name 'MSSQL*' -ErrorAction SilentlyContinue
    if (-not $sqlSvc) {
        Log '  SQL Server NOT installed.' Gray
        Add-Summary 'SQL Health' 'INFO' 'Not installed'
        return
    }
    Log ''
    Log ('=' * 56) DarkCyan
    Log ('  SQL SERVER HEALTH') Cyan
    Log ('=' * 56) DarkCyan

    foreach ($svc in $sqlSvc) {
        Log ("  Service: {0} - {1}" -f $svc.Name, $svc.Status)
        Add-Summary "SQL Service: $($svc.Name)" $(if ($svc.Status -eq 'Running') { 'PASS' } else { 'FAIL' }) $svc.Status
    }

    try {
        $conn = New-Object System.Data.SqlClient.SqlConnection
        $conn.ConnectionString = 'Server=.;Integrated Security=true;Connect Timeout=5'
        $conn.Open()
        Log '  Local SQL connection: OK' Green
        Add-Summary 'SQL Connection' 'PASS' 'Connected'
        $conn.Close()
    } catch {
        Log ('  Local SQL connection FAILED: ' + $_.Exception.Message) Red
        Add-Summary 'SQL Connection' 'FAIL' $_.Exception.Message
    }
}

function Section-FullServer {
    Section-OsInfo
    Section-Hardware
    Section-StorageServer
    Section-NetworkServer
    Section-RDPServer
    Section-CriticalServices
    Section-WUServer
    Section-EventLogsServer
    Section-ADHealth
    Section-DNSHealth
    Section-DHCPHealth
    Section-IISHealth
    Section-SQLHealth
}

# ------------------------- menu ----------------------------------

function Show-Menu {
    while ($true) {
        Clear-Host
        Write-Host ''
        Write-Host ('=' * 56) -ForegroundColor Green
        Write-Host ('   IT HELPER TOOLKIT - SERVER HEALTH CHECK v' + $ToolVersion) -ForegroundColor Green
        Write-Host ('   {0}  |  Admin: {1}' -f $env:COMPUTERNAME, $IsAdmin) -ForegroundColor Gray
        Write-Host ('=' * 56) -ForegroundColor Green
        Write-Host ''
        Write-Host '  CORE'
        Write-Host '  ----'
        Write-Host '   1. OS / Build Information'
        Write-Host '   2. CPU / RAM'
        Write-Host '   3. Storage / RAID / Volumes'
        Write-Host '   4. Network (Adapters, Teams, IP)'
        Write-Host '   5. RDP (Enabled, TermService, NLA, Firewall)'
        Write-Host '   6. Critical Services'
        Write-Host '   7. Windows Update'
        Write-Host '   8. Event Logs (System, App, Security)'
        Write-Host ''
        Write-Host '  ROLE-SPECIFIC (auto-detected)'
        Write-Host '  ----------------------------'
        Write-Host '   9. AD Health (Replication, FSMO, Modes)'
        Write-Host '  10. DNS Health (Zones, Statistics, Resolution)'
        Write-Host '  11. DHCP Health (Scopes, Leases)'
        Write-Host '  12. IIS Health (Sites, App Pools)'
        Write-Host '  13. SQL Health (Services, Connection Test)'
        Write-Host ''
        Write-Host '  14. FULL SERVER REPORT (all above)'
        Write-Host ''
        Write-Host '   0. Exit'
        Write-Host ''
        $c = (Read-Host ' Select').Trim()

        switch ($c) {
            '1'  { Start-Run 'OS INFO'        { Section-OsInfo } }
            '2'  { Start-Run 'HARDWARE'       { Section-Hardware } }
            '3'  { Start-Run 'STORAGE'        { Section-StorageServer } }
            '4'  { Start-Run 'NETWORK'        { Section-NetworkServer } }
            '5'  { Start-Run 'RDP'            { Section-RDPServer } }
            '6'  { Start-Run 'CRITICAL SVCS'  { Section-CriticalServices } }
            '7'  { Start-Run 'WINDOWS UPDATE' { Section-WUServer } }
            '8'  { Start-Run 'EVENT LOGS'     { Section-EventLogsServer } }
            '9'  { Start-Run 'AD HEALTH'      { Section-ADHealth } }
            '10' { Start-Run 'DNS HEALTH'     { Section-DNSHealth } }
            '11' { Start-Run 'DHCP HEALTH'    { Section-DHCPHealth } }
            '12' { Start-Run 'IIS HEALTH'     { Section-IISHealth } }
            '13' { Start-Run 'SQL HEALTH'     { Section-SQLHealth } }
            '14' { Start-Run 'FULL REPORT'    { Section-FullServer } }
            '0'  { return }
        }
    }
}

# ------------------------- dispatch ------------------------------

try {
    switch ($Mode) {
        'os'       { Start-Run 'OS INFO'        { Section-OsInfo } }
        'hw'       { Start-Run 'HARDWARE'       { Section-Hardware } }
        'storage'  { Start-Run 'STORAGE'        { Section-StorageServer } }
        'net'      { Start-Run 'NETWORK'        { Section-NetworkServer } }
        'rdp'      { Start-Run 'RDP'            { Section-RDPServer } }
        'services' { Start-Run 'CRITICAL SVCS'  { Section-CriticalServices } }
        'wu'       { Start-Run 'WINDOWS UPDATE' { Section-WUServer } }
        'events'   { Start-Run 'EVENT LOGS'     { Section-EventLogsServer } }
        'ad'       { Start-Run 'AD HEALTH'      { Section-ADHealth } }
        'dns'      { Start-Run 'DNS HEALTH'     { Section-DNSHealth } }
        'dhcp'     { Start-Run 'DHCP HEALTH'    { Section-DHCPHealth } }
        'iis'      { Start-Run 'IIS HEALTH'     { Section-IISHealth } }
        'sql'      { Start-Run 'SQL HEALTH'     { Section-SQLHealth } }
        'full'     { Start-Run 'FULL REPORT'    { Section-FullServer } }
        default    { Show-Menu }
    }
} catch {
    Write-Host ''
    Write-Host ('FATAL: ' + $_.Exception.Message) -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
    Set-DoneFlag
    if ($Mode -ne 'menu') {
        try { Stop-Transcript | Out-Null } catch { }
        exit 250
    }
    Read-Host 'Press Enter to return to the menu'
}

try { Stop-Transcript | Out-Null } catch { }
Set-DoneFlag
exit 0
