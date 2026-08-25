@echo off
setlocal EnableExtensions
title IT Helper Toolkit - PC Quick Support
color 0A

rem ============================================================
rem  IT HELPER TOOLKIT - PC QUICK SUPPORT
rem  Single-file: .bat launcher + embedded PowerShell backend
rem  Compatible: Windows 10/11, Server 2019/2022/2025
rem
rem  Usage:
rem    IT_Helper_PC_Support.bat          interactive menu
rem    IT_Helper_PC_Support.bat quick    quick overview (default)
rem    IT_Helper_PC_Support.bat report   full report
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
set "ITH_PS=%TEMP%\ITH_PC_%RANDOM%%RANDOM%.ps1"
set "ITH_ERR=%TEMP%\ITH_PC_err_%RANDOM%.log"
set "ITH_FLAG=%TEMP%\ITH_PC_done_%RANDOM%.flag"
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
ping 127.0.0.1 -n 2 >nul
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
#  IT Helper Toolkit - PC Quick Support (backend)
# ==================================================================
param(
    [Parameter(Position = 0)]
    [ValidateSet('menu', 'quick', 'report')]
    [string]$Mode = 'quick',

    # Explicit flag path handed over by the launcher. Travels as a
    # command-line argument, so it survives the UAC boundary; falls back
    # to the env var when this backend is run standalone.
    [string]$DoneFlag = $env:ITH_FLAG
)

$ErrorActionPreference = 'Continue'
$ToolVersion = '1.0'
$Stamp   = Get-Date -Format 'yyyyMMdd_HHmmss'
$RunDir  = Join-Path 'C:\ITHelper\Reports' ('PCSupport_{0}_{1}' -f $env:COMPUTERNAME, $Stamp)
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

function Start-Run {
    param([string]$GroupLabel, [scriptblock]$Pipeline)
    $script:Results = New-Object System.Collections.Generic.List[object]
    Log ('=' * 62) DarkCyan
    Log ('  IT HELPER PC QUICK SUPPORT v' + $ToolVersion + '  -  GROUP: ' + $GroupLabel) Cyan
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
    Log '|           QUICK SUPPORT RESULT             |' Cyan
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

# ------------------------- quick support sections ------------------------------

function Section-SystemInfo {
    $os  = Get-CimInstance Win32_OperatingSystem
    $cs  = Get-CimInstance Win32_ComputerSystem
    $ver = [Environment]::OSVersion.Version
    $up  = (Get-Date) - $os.LastBootUpTime

    Log ''
    Log ('=' * 56) DarkCyan
    Log ('  SYSTEM INFORMATION') Cyan
    Log ('=' * 56) DarkCyan
    Log ('  Computer     : {0} {1}' -f $cs.Manufacturer, $cs.Model)
    Log ('  OS           : {0}  build {1}' -f $os.Caption.Trim(), $os.BuildNumber)
    Log ('  Version      : {0}' -f $ver.ToString())
    Log ('  Uptime       : {0}d {1:D2}h {2:D2}m' -f [int]$up.Days, $up.Hours, $up.Minutes)
    Log ('  Last Boot    : {0}' -f $os.LastBootUpTime)
    Log ('  User         : {0}\{1}' -f $env:USERDOMAIN, $env:USERNAME)
    Log ('  Domain       : {0}' -f $env:USERDOMAIN)

    Add-Summary 'OS Version' 'INFO' ('{0} build {1}' -f $os.Caption.Trim(), $os.BuildNumber)
    if ($up.TotalDays -gt 30) {
        Add-Summary 'Uptime' 'WARN' ('{0:N0} days since last boot - reboot recommended' -f $up.TotalDays)
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
    Log ('  HARDWARE') Cyan
    Log ('=' * 56) DarkCyan
    Log ('  CPU       : {0}' -f $cpu.Name.Trim())
    Log ('  Load      : {0} percent  ({1} cores / {2} threads)' -f $load, $cpu.NumberOfCores, $cpu.NumberOfLogicalProcessors)
    Log ('  RAM       : {0} GB total / {1} GB free ({2} percent free)' -f $totGB, $freeGB, $freePct)

    $s = if ($load -ge 90) { 'WARN' } else { 'PASS' }
    Add-Summary 'CPU Load' $s ('{0} percent' -f $load)
    $s = if ($freePct -lt 10) { 'WARN' } elseif ($freePct -lt 20) { 'INFO' } else { 'PASS' }
    Add-Summary 'RAM Free' $s ('{0} GB free of {1} GB' -f $freeGB, $totGB)
}

function Section-Disks {
    Log ''
    Log ('=' * 56) DarkCyan
    Log ('  DISK SPACE') Cyan
    Log ('=' * 56) DarkCyan
    $vols = Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | Where-Object { $_.Size }
    $rows = $vols | Select-Object DeviceID,
        @{n = 'TotalGB'; e = { [math]::Round($_.Size / 1GB, 1) } },
        @{n = 'UsedGB'; e = { [math]::Round(($_.Size - $_.FreeSpace) / 1GB, 1) } },
        @{n = 'FreeGB'; e = { [math]::Round($_.FreeSpace / 1GB, 1) } },
        @{n = 'Free%'; e = { [math]::Round($_.FreeSpace / $_.Size * 100, 1) } }
    Log (($rows | Format-Table -AutoSize | Out-String).TrimEnd())

    foreach ($v in $vols) {
        $pct = [math]::Round($v.FreeSpace / $v.Size * 100, 1)
        $s = if ($pct -lt 3) { 'FAIL' } elseif ($pct -lt 10) { 'WARN' } else { 'PASS' }
        Add-Summary 'Disk Space' $s ('Drive {0} {1} percent free' -f $v.DeviceID, $pct)
    }
}

function Section-NetworkQuick {
    Log ''
    Log ('=' * 56) DarkCyan
    Log ('  NETWORK') Cyan
    Log ('=' * 56) DarkCyan

    $ipconfs = Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway }
    if ($ipconfs) {
        $ipc = $ipconfs | Select-Object -First 1
        Log ('  IPv4         : {0}' -f $ipc.IPv4Address.IPAddress)
        Log ('  Gateway      : {0}' -f ($ipc.IPv4DefaultGateway.NextHop -join ', '))
        Log ('  DNS          : {0}' -f ($ipc.DNSServer.ServerAddresses -join ', '))
        Add-Summary 'Network Config' 'INFO' ('Primary IP {0}' -f $script:PrimaryIP)
    } else {
        Log '  No adapter with default gateway found!' Yellow
        Add-Summary 'Network Config' 'WARN' 'No default gateway'
    }

    # Quick connectivity
    $gw = $null
    try { $gw = (Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway } | Select-Object -First 1).IPv4DefaultGateway.NextHop } catch { }
    if ($gw) {
        $okGw = Test-Connection -ComputerName $gw -Count 2 -Quiet
        Log ('  Gateway      : {0}' -f $(if ($okGw) { 'REACHABLE' } else { 'NOT REACHABLE' }))
        Add-Summary 'Gateway' $(if ($okGw) { 'PASS' } else { 'FAIL' }) $gw
    }

    $okDns = $false
    try { $r = Resolve-DnsName 'www.microsoft.com' -Type A -ErrorAction Stop; $okDns = $true } catch { }
    Log ('  DNS          : {0}' -f $(if ($okDns) { 'OK' } else { 'FAILED' }))
    Add-Summary 'DNS' $(if ($okDns) { 'PASS' } else { 'FAIL' }) 'www.microsoft.com'

    $okNet = Test-Connection -ComputerName '8.8.8.8' -Count 2 -Quiet
    Log ('  Internet     : {0}' -f $(if ($okNet) { 'OK' } else { 'FAILED' }))
    Add-Summary 'Internet' $(if ($okNet) { 'PASS' } else { 'FAIL' }) '8.8.8.8'
}

function Section-ServicesQuick {
    Log ''
    Log ('=' * 56) DarkCyan
    Log ('  CRITICAL SERVICES') Cyan
    Log ('=' * 56) DarkCyan

    $criticalList = @('WinDefend', 'wuauserv', 'BITS', 'Dhcp', 'Dnscache',
                      'LanmanServer', 'LanmanWorkstation', 'EventLog',
                      'Schedule', 'ProfSvc', 'CryptSvc', 'Spooler')

    $allOk = $true
    foreach ($name in $criticalList) {
        $sv = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($sv) {
            $status = $sv.Status
            $disp = $sv.DisplayName
            $s = if ($status -eq 'Running') { 'PASS' } else { $allOk = $false; 'FAIL' }
            Log ('  [{0}] {1} - {2}' -f $status, $name, $disp)
            Add-Summary "Service: $name" $s $disp
        } else {
            Log ('  [NOT FOUND] {0}' -f $name) Yellow
            Add-Summary "Service: $name" 'INFO' 'Not installed'
        }
    }
    if ($allOk) { Log '  All critical services running.' Green }
}

function Section-RDPQuick {
    Log ''
    Log ('=' * 56) DarkCyan
    Log ('  REMOTE DESKTOP') Cyan
    Log ('=' * 56) DarkCyan
    try {
        $rdp = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -ErrorAction Stop).fDenyTSConnections
        $state = if ($rdp -eq 0) { 'ENABLED' } else { 'DISABLED' }
        Log ('  Remote Desktop: {0}' -f $state)
        $s = if ($rdp -eq 0) { 'INFO' } else { 'PASS' }
        Add-Summary 'Remote Desktop' $s $state
    } catch {
        Log '  Could not read RDP status.' Yellow
        Add-Summary 'Remote Desktop' 'INFO' 'Not readable'
    }

    $svc = Get-Service -Name 'TermService' -ErrorAction SilentlyContinue
    if ($svc) {
        Log ('  TermService   : {0}' -f $svc.Status)
        Add-Summary 'TermService' $(if ($svc.Status -eq 'Running') { 'PASS' } else { 'FAIL' }) $svc.Status
    }
}

function Section-DefenderQuick {
    Log ''
    Log ('=' * 56) DarkCyan
    Log ('  WINDOWS DEFENDER') Cyan
    Log ('=' * 56) DarkCyan
    try {
        $mp = Get-MpComputerStatus -ErrorAction Stop
        Log ('  Antivirus        : {0}' -f $mp.AntivirusEnabled)
        Log ('  Real-time        : {0}' -f $mp.RealTimeProtectionEnabled)
        Log ('  Behavior monitor : {0}' -f $mp.BehaviorMonitorEnabled)
        $sigAge = -1
        if ($mp.AntivirusSignatureLastUpdated) {
            $sigAge = [int]((Get-Date) - $mp.AntivirusSignatureLastUpdated).TotalDays
        }
        Log ('  Signature age    : {0} day(s)' -f $sigAge)

        if (-not $mp.AntivirusEnabled -or -not $mp.RealTimeProtectionEnabled) {
            Add-Summary 'Defender' 'WARN' 'AV or real-time disabled'
        } else {
            Add-Summary 'Defender' 'PASS' 'Enabled'
        }
        if ($sigAge -gt 7) {
            Add-Summary 'Defender Signatures' 'WARN' ('{0} days old' -f $sigAge)
        } else {
            Add-Summary 'Defender Signatures' 'PASS' ('{0} day(s) old' -f $sigAge)
        }
    } catch {
        Log '  Windows Defender not available (third-party AV or Server SKU).' Gray
        Add-Summary 'Defender' 'INFO' 'Not available'
    }
}

function Invoke-Quick {
    Section-SystemInfo
    Section-Hardware
    Section-Disks
    Section-NetworkQuick
    Section-ServicesQuick
    Section-RDPQuick
    Section-DefenderQuick
}

# ------------------------- menu ----------------------------------

function Show-Menu {
    while ($true) {
        Clear-Host
        Write-Host ''
        Write-Host ('=' * 56) -ForegroundColor Green
        Write-Host ('   IT HELPER TOOLKIT - PC QUICK SUPPORT v' + $ToolVersion) -ForegroundColor Green
        Write-Host ('   {0}  |  Admin: {1}' -f $env:COMPUTERNAME, $IsAdmin) -ForegroundColor Gray
        Write-Host ('=' * 56) -ForegroundColor Green
        Write-Host ''
        Write-Host '   1. QUICK OVERVIEW    (30-60 sec system snapshot)'
        Write-Host '   2. FULL REPORT       (detailed + CSV export)'
        Write-Host ''
        Write-Host '   0. Exit'
        Write-Host ''
        $c = (Read-Host ' Select').Trim()

        switch ($c) {
            '1' { Start-Run 'QUICK OVERVIEW' { Invoke-Quick } }
            '2' { Start-Run 'FULL REPORT'    { Invoke-Quick } }
            '0' { return }
        }
    }
}

# ------------------------- dispatch ------------------------------

try {
    switch ($Mode) {
        'quick'  { Start-Run 'QUICK OVERVIEW' { Invoke-Quick } }
        'report' { Start-Run 'FULL REPORT'    { Invoke-Quick } }
        default  { Show-Menu }
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
