@echo off
setlocal EnableExtensions
title IT Helper Toolkit - RDP Troubleshooter
color 0D

rem ============================================================
rem  IT HELPER TOOLKIT - RDP TROUBLESHOOTER
rem  Single-file: .bat launcher + embedded PowerShell backend
rem  Compatible: Windows 10/11, Server 2019/2022/2025
rem
rem  Usage:
rem    IT_Helper_RDP.bat            interactive menu
rem    IT_Helper_RDP.bat enabled    check RDP enabled
rem    IT_Helper_RDP.bat service    check TermService
rem    IT_Helper_RDP.bat firewall   check firewall
rem    IT_Helper_RDP.bat port       test TCP 3389
rem    IT_Helper_RDP.bat profile    check network profile
rem    IT_Helper_RDP.bat nla        check NLA
rem    IT_Helper_RDP.bat users      check Remote Desktop Users
rem    IT_Helper_RDP.bat host       test remote host
rem    IT_Helper_RDP.bat rport      test remote port
rem    IT_Helper_RDP.bat diag       full RDP diagnostic
rem    IT_Helper_RDP.bat report     generate RDP report
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
set "ITH_PS=%TEMP%\ITH_RDP_%RANDOM%%RANDOM%.ps1"
set "ITH_ERR=%TEMP%\ITH_RDP_err_%RANDOM%.log"
set "ITH_FLAG=%TEMP%\ITH_RDP_done_%RANDOM%.flag"
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
#  IT Helper Toolkit - RDP Troubleshooter (backend)
# ==================================================================
param(
    [Parameter(Position = 0)]
    [ValidateSet('menu', 'enabled', 'service', 'firewall', 'port', 'profile', 'nla', 'users', 'host', 'rport', 'diag', 'report')]
    [string]$Mode = 'menu',

    # Explicit flag path handed over by the launcher. Travels as a
    # command-line argument, so it survives the UAC boundary; falls back
    # to the env var when this backend is run standalone.
    [string]$DoneFlag = $env:ITH_FLAG
)

$ErrorActionPreference = 'Continue'
$ToolVersion = '1.0'
$Stamp   = Get-Date -Format 'yyyyMMdd_HHmmss'
$RunDir  = Join-Path 'C:\ITHelper\Reports' ('RDP_{0}_{1}' -f $env:COMPUTERNAME, $Stamp)
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
    Log ('  IT HELPER RDP TROUBLESHOOTER v' + $ToolVersion + '  -  GROUP: ' + $GroupLabel) Cyan
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
    Log '|           RDP TROUBLESHOOTER RESULT        |' Cyan
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

# ------------------------- RDP sections ------------------------------

function Section-RDPEnabled {
    Log '  Remote Desktop Configuration:' Gray
    try {
        $rdp = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -ErrorAction Stop).fDenyTSConnections
        $state = if ($rdp -eq 0) { 'ENABLED' } else { 'DISABLED' }
        Log ('  fDenyTSConnections = {0}  ->  Remote Desktop: {1}' -f $rdp, $state)
        $s = if ($rdp -eq 0) { 'PASS' } else { 'FAIL' }
        Add-Summary 'RDP Enabled' $s $state
    } catch {
        Log '  ERROR: Could not read RDP registry key.' Red
        Add-Summary 'RDP Enabled' 'FAIL' 'Registry not readable'
    }

    # Also check the user-mode setting
    try {
        $userRDP = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' -Name fDenyTSConnections -ErrorAction SilentlyContinue).fDenyTSConnections
        if ($null -ne $userRDP) {
            Log ('  Policy fDenyTSConnections = {0}' -f $userRDP) Gray
        }
    } catch { }
}

function Section-TermService {
    Log '  Remote Desktop Services (TermService):' Gray
    $svc = Get-Service -Name 'TermService' -ErrorAction SilentlyContinue
    if (-not $svc) {
        Log '  TermService not found.' Red
        Add-Summary 'TermService' 'FAIL' 'Service not found'
        return
    }
    Log ('  Status      : {0}' -f $svc.Status)
    Log ('  Start Type  : {0}' -f $svc.StartType)
    Log ('  Can Pause   : {0}' -f $svc.CanPauseAndContinue)
    Log ('  Can Stop    : {0}' -f $svc.CanStop)

    $s = if ($svc.Status -eq 'Running') { 'PASS' } elseif ($svc.Status -eq 'Stopped') { 'FAIL' } else { 'WARN' }
    Add-Summary 'TermService' $s $svc.Status

    if ($svc.Status -ne 'Running' -and $IsAdmin) {
        if ((Read-Host '  Start TermService now? (y/n)') -eq 'y') {
            try { Start-Service -Name 'TermService' -ErrorAction Stop; Log '  TermService started.' Green } catch { Log ('  ERROR: ' + $_.Exception.Message) Red }
        }
    }
}

function Section-Firewall {
    Log '  Windows Firewall Rules for RDP:' Gray
    try {
        $rules = Get-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction Stop |
            Where-Object { $_.Enabled -eq 'True' }
        if ($rules) {
            Log (($rules | Select-Object DisplayName, Name, Enabled, Action, Direction, Profile |
                Format-Table -AutoSize | Out-String).TrimEnd())
            Add-Summary 'RDP Firewall' 'PASS' ('{0} rule(s) enabled' -f @($rules).Count)
        } else {
            Log '  No enabled Remote Desktop firewall rules found!' Red
            Add-Summary 'RDP Firewall' 'FAIL' 'No enabled rules'
        }
    } catch {
        Log '  ERROR: Could not query firewall rules.' Red
        Add-Summary 'RDP Firewall' 'FAIL' $_.Exception.Message
    }

    # Check profile-specific
    try {
        $profiles = Get-NetFirewallProfile -ErrorAction Stop
        Log ''
        Log '  Firewall Profiles:' Gray
        Log (($profiles | Select-Object Name, Enabled, DefaultInboundAction | Format-Table -AutoSize | Out-String).TrimEnd())
    } catch { }
}

function Section-Port3389 {
    Log '  TCP Port 3389 (RDP):' Gray
    $listeners = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $_.LocalPort -eq 3389 }
    if ($listeners) {
        Log (($listeners | Select-Object LocalAddress, LocalPort, State, OwningProcess | Format-Table -AutoSize | Out-String).TrimEnd())
        Add-Summary 'TCP 3389' 'PASS' 'Listening'
    } else {
        Log '  Port 3389 is NOT listening.' Red
        Add-Summary 'TCP 3389' 'FAIL' 'Not listening'
    }
}

function Section-NetworkProfile {
    Log '  Network Connection Profiles:' Gray
    try {
        $profiles = Get-NetConnectionProfile -ErrorAction Stop
        Log (($profiles | Select-Object Name, InterfaceAlias, NetworkCategory, IPv4Connectivity | Format-Table -AutoSize | Out-String).TrimEnd())
        $public = @($profiles | Where-Object { $_.NetworkCategory -eq 'Public' })
        if ($public.Count -gt 0) {
            Log ''
            Log '  WARNING: Public network profile detected - RDP may be blocked by firewall.' Yellow
            Add-Summary 'Network Profile' 'WARN' ('{0} public profile(s)' -f $public.Count)
        } else {
            Add-Summary 'Network Profile' 'PASS' 'No public profiles'
        }
    } catch {
        Log '  ERROR: Could not get network profiles.' Red
        Add-Summary 'Network Profile' 'FAIL' $_.Exception.Message
    }
}

function Section-NLA {
    Log '  Network Level Authentication (NLA):' Gray
    try {
        $nla = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name UserAuthentication -ErrorAction Stop).UserAuthentication
        $state = if ($nla -eq 1) { 'ENABLED (Required)' } else { 'DISABLED (Not Required)' }
        Log ('  UserAuthentication = {0}  ->  NLA: {1}' -f $nla, $state)
        $s = if ($nla -eq 1) { 'PASS' } else { 'WARN' }
        Add-Summary 'NLA' $s $state
    } catch {
        Log '  ERROR: Could not read NLA setting.' Red
        Add-Summary 'NLA' 'FAIL' 'Registry not readable'
    }

    # Also check Security Layer
    try {
        $secLayer = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name SecurityLayer -ErrorAction Stop).SecurityLayer
        $layerDesc = @{0='Negotiate';1='RDP';2='SSL';3='TLS'}[$secLayer]
        Log ('  SecurityLayer = {0} ({1})' -f $secLayer, $layerDesc) Gray
    } catch { }
}

function Section-RDPUsers {
    Log '  Remote Desktop Users Group:' Gray
    try {
        $group = [ADSI]"WinNT://$env:COMPUTERNAME/Remote Desktop Users,group"
        $members = @($group.psbase.Invoke('Members') | ForEach-Object { $_.GetType().InvokeMember('Name','GetProperty',$null,$_,$null) })
        if ($members.Count -gt 0) {
            Log (($members | ForEach-Object { '  - ' + $_ }) -join "`n")
            Add-Summary 'RDP Users' 'INFO' ('{0} member(s)' -f $members.Count)
        } else {
            Log '  No members in Remote Desktop Users group.' Yellow
            Add-Summary 'RDP Users' 'WARN' 'Group empty'
        }
    } catch {
        Log '  ERROR: Could not query Remote Desktop Users group.' Red
        Add-Summary 'RDP Users' 'FAIL' $_.Exception.Message
    }
}

function Section-TestRemoteHost {
    $host = Read-Host '  Remote hostname or IP to test'
    if (-not $host) { Log '  No host provided.' Yellow; Add-Summary 'Test Remote Host' 'INFO' 'Skipped'; return }
    Log ("  Testing RDP connectivity to {0}..." -f $host)
    $okPing = Test-Connection -ComputerName $host -Count 3 -Quiet
    Log ("  ICMP Ping   : {0}" -f $(if ($okPing) { 'REACHABLE' } else { 'NOT REACHABLE' }))
    $okRDP = Test-TcpPort -Target $host -Port 3389 -TimeoutMs 5000
    Log ("  TCP 3389    : {0}" -f $(if ($okRDP) { 'OPEN' } else { 'CLOSED / FILTERED' }))
    $s = if ($okPing -and $okRDP) { 'PASS' } elseif ($okPing) { 'WARN' } else { 'FAIL' }
    Add-Summary 'Test Remote Host' $s $host
}

function Section-TestRemotePort {
    $host = Read-Host '  Remote hostname or IP'
    if (-not $host) { Log '  No host provided.' Yellow; Add-Summary 'Test Remote Port' 'INFO' 'Skipped'; return }
    $port = Read-Host '  TCP port [default 3389]'
    if (-not ($port -match '^\d+$')) { $port = 3389 }
    $timeout = Read-Host '  Timeout ms [default 5000]'
    if (-not ($timeout -match '^\d+$')) { $timeout = 5000 }
    Log ("  Testing TCP {0}:{1}..." -f $host, $port)
    $ok = Test-TcpPort -Target $host -Port $port -TimeoutMs $timeout
    $state = if ($ok) { 'OPEN' } else { 'CLOSED / FILTERED' }
    Log ("  Result: {0}" -f $state)
    $s = if ($ok) { 'PASS' } else { 'FAIL' }
    Add-Summary 'Test Remote Port' $s ("{0}:{1}" -f $host, $port)
}

function Section-FullDiag {
    Section-RDPEnabled
    Section-TermService
    Section-Firewall
    Section-Port3389
    Section-NetworkProfile
    Section-NLA
    Section-RDPUsers
}

# ------------------------- menu ----------------------------------

function Show-Menu {
    while ($true) {
        Clear-Host
        Write-Host ''
        Write-Host ('=' * 56) -ForegroundColor Green
        Write-Host ('   IT HELPER TOOLKIT - RDP TROUBLESHOOTER v' + $ToolVersion) -ForegroundColor Green
        Write-Host ('   {0}  |  Admin: {1}' -f $env:COMPUTERNAME, $IsAdmin) -ForegroundColor Gray
        Write-Host ('=' * 56) -ForegroundColor Green
        Write-Host ''
        Write-Host '  DIAGNOSTICS'
        Write-Host '  -----------'
        Write-Host '   1. Check RDP Enabled'
        Write-Host '   2. Check TermService'
        Write-Host '   3. Check Windows Firewall'
        Write-Host '   4. Check TCP Port 3389'
        Write-Host '   5. Check Network Profile'
        Write-Host '   6. Check NLA (Network Level Auth)'
        Write-Host '   7. Check Remote Desktop Users'
        Write-Host ''
        Write-Host '  REMOTE TESTS'
        Write-Host '  ------------'
        Write-Host '   8. Test Remote Host (Ping + TCP 3389)'
        Write-Host '   9. Test Custom Remote Port'
        Write-Host ''
        Write-Host '  REPORTS'
        Write-Host '  -------'
        Write-Host '  10. Full RDP Diagnostic'
        Write-Host '  11. Generate RDP Report'
        Write-Host ''
        Write-Host '   0. Exit'
        Write-Host ''
        $c = (Read-Host ' Select').Trim()

        switch ($c) {
            '1'  { Start-Run 'RDP ENABLED'     { Section-RDPEnabled } }
            '2'  { Start-Run 'TERMSERVICE'     { Section-TermService } }
            '3'  { Start-Run 'FIREWALL'        { Section-Firewall } }
            '4'  { Start-Run 'TCP PORT 3389'   { Section-Port3389 } }
            '5'  { Start-Run 'NETWORK PROFILE' { Section-NetworkProfile } }
            '6'  { Start-Run 'NLA'             { Section-NLA } }
            '7'  { Start-Run 'RDP USERS'       { Section-RDPUsers } }
            '8'  { Start-Run 'TEST REMOTE HOST' { Section-TestRemoteHost } }
            '9'  { Start-Run 'TEST REMOTE PORT' { Section-TestRemotePort } }
            '10' { Start-Run 'FULL DIAGNOSTIC' { Section-FullDiag } }
            '11' { Start-Run 'RDP REPORT'      { Section-FullDiag } }
            '0'  { return }
        }
    }
}

# ------------------------- dispatch ------------------------------

try {
    switch ($Mode) {
        'enabled'  { Start-Run 'RDP ENABLED'     { Section-RDPEnabled } }
        'service'  { Start-Run 'TERMSERVICE'     { Section-TermService } }
        'firewall' { Start-Run 'FIREWALL'        { Section-Firewall } }
        'port'     { Start-Run 'TCP PORT 3389'   { Section-Port3389 } }
        'profile'  { Start-Run 'NETWORK PROFILE' { Section-NetworkProfile } }
        'nla'      { Start-Run 'NLA'             { Section-NLA } }
        'users'    { Start-Run 'RDP USERS'       { Section-RDPUsers } }
        'host'     { Start-Run 'TEST REMOTE HOST' { Section-TestRemoteHost } }
        'rport'    { Start-Run 'TEST REMOTE PORT' { Section-TestRemotePort } }
        'diag'     { Start-Run 'FULL DIAGNOSTIC' { Section-FullDiag } }
        'report'   { Start-Run 'RDP REPORT'      { Section-FullDiag } }
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