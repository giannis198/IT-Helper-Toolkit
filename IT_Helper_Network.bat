@echo off
setlocal EnableExtensions
title IT Helper Toolkit - Network Fixer v1.2
color 0B

rem ============================================================
rem  IT HELPER TOOLKIT - NETWORK FIXER v1.2
rem  Single-file: .bat launcher + embedded PowerShell backend
rem  Compatible: Windows 10/11, Server 2019/2022/2025
rem
rem  Usage:
rem    IT_Helper_Network.bat             interactive menu
rem    IT_Helper_Network.bat config      show network config
rem    IT_Helper_Network.bat gateway     test gateway
rem    IT_Helper_Network.bat internet    internet diagnostic (HTTPS first)
rem    IT_Helper_Network.bat dns         dns diagnostic
rem    IT_Helper_Network.bat dhcp        dhcp diagnostic
rem    IT_Helper_Network.bat arp         arp / neighbor table
rem    IT_Helper_Network.bat route       routing table
rem    IT_Helper_Network.bat profile     network profiles
rem    IT_Helper_Network.bat host        test specific host
rem    IT_Helper_Network.bat port        test TCP port
rem    IT_Helper_Network.bat flushdns    flush DNS cache
rem    IT_Helper_Network.bat renew       renew DHCP (DHCP adapters only)
rem    IT_Helper_Network.bat winsock     reset Winsock
rem    IT_Helper_Network.bat tcpip       reset TCP/IP
rem    IT_Helper_Network.bat setdns      set custom DNS (with presets)
rem    IT_Helper_Network.bat repair      full network repair (DHCP-aware)
rem    IT_Helper_Network.bat report      full network report
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
set "ITH_PS=%TEMP%\ITH_Net_%RANDOM%%RANDOM%.ps1"
set "ITH_ERR=%TEMP%\ITH_Net_err_%RANDOM%.log"
set "ITH_FLAG=%TEMP%\ITH_Net_done_%RANDOM%.flag"
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
#  IT Helper Toolkit - Network Fixer v1.1 (backend)
# ==================================================================
param(
    [Parameter(Position = 0)]
    [ValidateSet('menu', 'config', 'gateway', 'internet', 'dns', 'dhcp', 'arp', 'route', 'profile', 'host', 'port', 'flushdns', 'renew', 'winsock', 'tcpip', 'setdns', 'repair', 'report')]
    [string]$Mode = 'menu',

    # Explicit flag path handed over by the launcher. Travels as a
    # command-line argument, so it survives the UAC boundary; falls back
    # to the env var when this backend is run standalone.
    [string]$DoneFlag = $env:ITH_FLAG
)

$ErrorActionPreference = 'Continue'
$ToolVersion = '1.2'
$Stamp   = Get-Date -Format 'yyyyMMdd_HHmmss'
$RunDir  = Join-Path 'C:\ITHelper\Reports' ('Network_{0}_{1}' -f $env:COMPUTERNAME, $Stamp)
$TxtPath = Join-Path $RunDir 'report.txt'
$CsvPath = Join-Path $RunDir 'summary.csv'
New-Item -ItemType Directory -Path $RunDir -Force | Out-Null

$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

$script:PrimaryIP = 'N/A'
$script:PrimaryGateway = 'N/A'
$script:PrimaryInterface = $null
try {
    $nic = Get-NetIPConfiguration -ErrorAction Stop |
        Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } |
        Select-Object -First 1
    if ($nic) {
        $script:PrimaryIP = $nic.IPv4Address.IPAddress
        $script:PrimaryGateway = $nic.IPv4DefaultGateway.NextHop
        $script:PrimaryInterface = $nic.NetAdapter
    }
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

function Confirm-Action {
    param([string]$What, [string]$Warning = '')
    Log ''
    Log ('  PROPOSED ACTION: ' + $What) Yellow
    if ($Warning) { Log ('  WARNING: ' + $Warning) Red }
    $answer = Read-Host '  Type YES to continue (anything else skips)'
    return ($answer -eq 'yes')
}

function Get-DhcpAdapters {
    Get-NetIPConfiguration -ErrorAction SilentlyContinue |
    Where-Object { $_.IPv4Address -and $_.NetAdapter.Status -eq 'Up' } |
    ForEach-Object {
        $adapter = $_.NetAdapter
        $ipconf = $_
        $dhcpEnabled = $false
        try {
            $setting = Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter "InterfaceIndex=$($adapter.ifIndex)" -ErrorAction Stop
            $dhcpEnabled = $setting.DHCPEnabled
        } catch { }
        [pscustomobject]@{
            Interface = $adapter
            IPConfig  = $ipconf
            DhcpEnabled = $dhcpEnabled
        }
    }
}

function Start-Run {
    param([string]$GroupLabel, [scriptblock]$Pipeline)
    $script:Results = New-Object System.Collections.Generic.List[object]
    Log ('=' * 62) DarkCyan
    Log ('  IT HELPER NETWORK FIXER v' + $ToolVersion + '  -  GROUP: ' + $GroupLabel) Cyan
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
    Log '|           DIAGNOSTIC RESULT                |' Cyan
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

# ------------------------- network sections ------------------------------

function Section-NetworkConfig {
    Log '  Network Configuration:' Gray
    $adapters = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' }
    if ($adapters) {
        Log (($adapters | Select-Object Name, InterfaceDescription, LinkSpeed, MacAddress, Status |
            Format-Table -AutoSize | Out-String).TrimEnd())
    } else {
        Log '  No active adapters found.' Yellow
    }

    $ipconfs = Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway }
    foreach ($ipc in $ipconfs) {
        Log ''
        Log ('  [{0}]' -f $ipc.InterfaceAlias) Cyan
        Log ('    IPv4 Address : {0}' -f $ipc.IPv4Address.IPAddress)
        Log ('    Prefix Length: {0}' -f $ipc.IPv4Address.PrefixLength)
        Log ('    Gateway      : {0}' -f ($ipc.IPv4DefaultGateway.NextHop -join ', '))
        Log ('    DNS Servers  : {0}' -f ($ipc.DNSServer.ServerAddresses -join ', '))
        try {
            $setting = Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter "InterfaceIndex=$($ipc.NetAdapter.ifIndex)" -ErrorAction Stop
            Log ('    DHCP Enabled : {0}' -f $setting.DHCPEnabled)
            if ($setting.DHCPEnabled -and $setting.DHCPServer) {
                Log ('    DHCP Server  : {0}' -f $setting.DHCPServer)
            }
            if ($setting.DHCPEnabled -and $setting.DHCPLeaseObtained -and $setting.DHCPLeaseExpires) {
                Log ('    Lease Start  : {0}' -f $setting.DHCPLeaseObtained)
                Log ('    Lease Expiry : {0}' -f $setting.DHCPLeaseExpires)
            }
        } catch { }
    }
    if (-not $ipconfs) {
        Log '  No adapter with a default gateway found!' Yellow
        Add-Summary 'Network Config' 'WARN' 'No default gateway'
    } else {
        Add-Summary 'Network Config' 'INFO' ('Primary IP {0}' -f $script:PrimaryIP)
    }
}

function Section-GatewayTest {
    if (-not $script:PrimaryGateway -or $script:PrimaryGateway -eq 'N/A') {
        Log '  No default gateway configured.' Yellow
        Add-Summary 'Gateway Ping' 'WARN' 'No gateway'
        return
    }
    $gw = $script:PrimaryGateway[0]
    $okGw = Test-Connection -ComputerName $gw -Count 3 -Quiet
    $state = if ($okGw) { 'REACHABLE' } else { 'NOT REACHABLE' }
    Log ('  Gateway {0} : {1}' -f $gw, $state)
    $s = if ($okGw) { 'PASS' } else { 'FAIL' }
    Add-Summary 'Gateway Ping' $s $gw
}

function Section-InternetTest {
    Log '  Internet Diagnostic (HTTPS-first):' Gray

    # DNS resolution first
    $okDns = $false; $dnsTime = 0; $resolved = ''
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $r = Resolve-DnsName -Name 'www.microsoft.com' -Type A -ErrorAction Stop
        $okDns = $true
        $resolved = $r.IPAddress | Select-Object -First 1
    } catch { }
    $sw.Stop()
    $dnsTime = $sw.ElapsedMilliseconds
    Log ('  DNS www.microsoft.com : {0} ({1} ms)' -f $(if ($okDns) { 'OK' } else { 'FAILED' }), $dnsTime)
    $s = if ($okDns) { 'PASS' } else { 'FAIL' }
    Add-Summary 'DNS Resolution' $s $(if ($okDns) { $resolved } else { 'resolve failed' })

    # HTTPS test
    $okTls = Test-TcpPort -Target 'www.microsoft.com' -Port 443
    Log ('  HTTPS 443             : {0}' -f $(if ($okTls) { 'OK' } else { 'FAILED' }))
    $s = if ($okTls) { 'PASS' } else { 'FAIL' }
    Add-Summary 'Internet HTTPS' $s 'tcp 443 www.microsoft.com'

    # ICMP as informational only
    $okPing = Test-Connection -ComputerName '8.8.8.8' -Count 2 -Quiet
    Log ('  ICMP 8.8.8.8          : {0}' -f $(if ($okPing) { 'OK (INFO)' } else { 'BLOCKED (INFO)' }))
    $s = if ($okPing) { 'INFO' } else { 'INFO' }
    Add-Summary 'Internet ICMP' $s 'ping 8.8.8.8 (informational)'
}

function Section-DnsDiagnostic {
    Log '  DNS Diagnostic:' Gray

    # Configured DNS servers
    $dnsServers = (Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.ServerAddresses }).ServerAddresses
    if ($dnsServers) {
        Log ('  Configured DNS: {0}' -f ($dnsServers -join ', '))
    } else {
        Log '  No DNS servers configured.' Yellow
    }

    # Multi-target resolution test
    $testDomains = @('www.microsoft.com', 'www.google.com', 'cloudflare.com', 'github.com')
    $allOk = $true
    foreach ($domain in $testDomains) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $ok = $false; $resolved = ''
        try {
            $r = Resolve-DnsName -Name $domain -Type A -ErrorAction Stop
            $ok = $true
            $resolved = $r.IPAddress | Select-Object -First 1
        } catch { }
        $sw.Stop()
        $status = if ($ok) { 'PASS' } else { $allOk = $false; 'FAIL' }
        $detail = if ($ok) { '{0} ({1} ms)' -f $resolved, $sw.ElapsedMilliseconds } else { 'FAILED' }
        Log ('  {0,-20} {1}' -f $domain, $detail)
        Add-Summary "DNS: $domain" $status $detail
    }
    if ($allOk) { Log '  DNS HEALTHY' Green } else { Log '  DNS ISSUES DETECTED' Red }
}

function Section-DhcpDiagnostic {
    Log '  DHCP Diagnostic:' Gray
    $adapters = Get-DhcpAdapters
    if (-not $adapters) {
        Log '  No active adapters with IPv4.' Yellow
        Add-Summary 'DHCP Diagnostic' 'INFO' 'No adapters'
        return
    }
    foreach ($a in $adapters) {
        Log ('  [{0}]' -f $a.Interface.Name) Cyan
        Log ('    IPv4          : {0}' -f $a.IPConfig.IPv4Address.IPAddress)
        Log ('    Gateway       : {0}' -f ($a.IPConfig.IPv4DefaultGateway.NextHop -join ', '))
        Log ('    DNS           : {0}' -f ($a.IPConfig.DNSServer.ServerAddresses -join ', '))
        Log ('    DHCP Enabled  : {0}' -f $a.DhcpEnabled)
        if ($a.DhcpEnabled) {
            try {
                $setting = Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter "InterfaceIndex=$($a.Interface.ifIndex)" -ErrorAction Stop
                if ($setting.DHCPServer) { Log ('    DHCP Server   : {0}' -f $setting.DHCPServer) }
                if ($setting.DHCPLeaseObtained) { Log ('    Lease Start   : {0}' -f $setting.DHCPLeaseObtained) }
                if ($setting.DHCPLeaseExpires) { Log ('    Lease Expiry  : {0}' -f $setting.DHCPLeaseExpires) }
            } catch { }
        } else {
            Log '    (Static IP configuration)' Gray
        }
    }
    Add-Summary 'DHCP Diagnostic' 'INFO' 'Completed'
}

function Section-ArpTable {
    Log '  ARP / Neighbor Table (Get-NetNeighbor):' Gray
    try {
        $neighbors = Get-NetNeighbor -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object { $_.State -ne 'Unreachable' } |
            Select-Object IPAddress, LinkLayerAddress, State, InterfaceAlias, InterfaceIndex |
            Sort-Object IPAddress
        if ($neighbors) {
            Log (($neighbors | Format-Table -AutoSize | Out-String).TrimEnd())
            Add-Summary 'ARP Table' 'INFO' ('{0} entries' -f @($neighbors).Count)
        } else {
            Log '  No reachable neighbors.' Yellow
            Add-Summary 'ARP Table' 'INFO' 'Empty'
        }
    } catch {
        Log '  Get-NetNeighbor not available (Windows 10/11+ required).' Yellow
        Add-Summary 'ARP Table' 'INFO' 'Not available'
    }
}

function Section-RouteTable {
    Log '  IPv4 Routing Table (Get-NetRoute):' Gray
    try {
        $routes = Get-NetRoute -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object { $_.DestinationPrefix -ne '0.0.0.0/32' -and $_.DestinationPrefix -ne '127.0.0.0/8' -and $_.DestinationPrefix -ne '224.0.0.0/4' -and $_.DestinationPrefix -ne '240.0.0.0/4' -and $_.DestinationPrefix -ne '255.255.255.255/32' } |
            Select-Object DestinationPrefix, NextHop, InterfaceAlias, InterfaceIndex, RouteMetric, ValidLifetime |
            Sort-Object { [System.Net.IPAddress]::Parse(($_.DestinationPrefix -split '/')[0]).GetAddressBytes()[3] } |
            Select-Object -First 30
        if ($routes) {
            Log (($routes | Format-Table -AutoSize | Out-String).TrimEnd())
            Add-Summary 'Routing Table' 'INFO' ('{0} routes shown' -f @($routes).Count)
        } else {
            Log '  No routes displayed.' Yellow
        }
    } catch {
        Log '  Get-NetRoute not available.' Yellow
        Add-Summary 'Routing Table' 'INFO' 'Not available'
    }
}

function Section-NetworkProfiles {
    Log '  Network Connection Profiles:' Gray
    try {
        $profiles = Get-NetConnectionProfile -ErrorAction Stop
        $hasPublic = $false
        $hasDomain = $false
        $hasPrivate = $false
        foreach ($p in $profiles) {
            $cat = $p.NetworkCategory
            switch ($cat) {
                'DomainAuthenticated' { $stateColor = 'Green'; $label = 'DOMAIN'; $hasDomain = $true }
                'Private'             { $stateColor = 'Cyan';  $label = 'PRIVATE'; $hasPrivate = $true }
                'Public'              { $stateColor = 'Red';   $label = 'PUBLIC'; $hasPublic = $true }
                default               { $stateColor = 'White'; $label = $cat }
            }
            Log ('  [{0}] {1,-25} {2,-10} ({3})' -f $p.InterfaceAlias, $p.Name, $label, $cat) $stateColor
        }
        if ($hasPublic) {
            Log ''
            Log '  WARNING: Public profile detected - file sharing, RDP, discovery may be blocked by firewall.' Yellow
        }
        $summary = @()
        if ($hasDomain) { $summary += 'Domain' }
        if ($hasPrivate) { $summary += 'Private' }
        if ($hasPublic) { $summary += 'Public' }
        $s = if ($hasPublic) { 'WARN' } elseif ($hasDomain) { 'PASS' } else { 'INFO' }
        Add-Summary 'Network Profiles' $s ('Active: {0}' -f ($summary -join ', '))
    } catch {
        Log '  ERROR: Could not get network profiles.' Red
        Add-Summary 'Network Profiles' 'FAIL' $_.Exception.Message
    }
}

function Section-FlushDNS {
    if (-not (Confirm-Action 'Flush DNS resolver cache (ipconfig /flushdns)')) {
        Add-Summary 'Flush DNS' 'INFO' 'Skipped by user'
        return
    }
    $out = & ipconfig.exe /flushdns 2>&1
    Log ('  ' + ($out -join "`n  "))
    Add-Summary 'Flush DNS' 'PASS' 'Cache flushed'
}

function Section-RenewDHCP {
    $adapters = Get-DhcpAdapters
    $dhcpAdapters = @($adapters | Where-Object { $_.DhcpEnabled })
    if (-not $dhcpAdapters) {
        Log '  No DHCP-enabled adapters found.' Yellow
        Add-Summary 'DHCP Renew' 'INFO' 'No DHCP adapters'
        return
    }
    if (-not (Confirm-Action 'Release and renew DHCP lease on DHCP adapters')) {
        Add-Summary 'DHCP Renew' 'INFO' 'Skipped by user'
        return
    }
    $allOk = $true
    foreach ($a in $dhcpAdapters) {
        Log ("  Processing {0} (ifIndex {1})..." -f $a.Interface.Name, $a.Interface.ifIndex) Cyan
        # PRIMARY: ipconfig /release + /renew (non-disruptive, keeps session alive)
        Log '    Releasing DHCP lease...'
        $out = & ipconfig.exe /release $a.Interface.Name 2>&1
        $rc1 = $LASTEXITCODE
        $out | ForEach-Object { Log ('      ' + $_) }
        if ($rc1 -ne 0) {
            Log ('    Release FAILED (exit code ' + $rc1 + ')') Red
        } else {
            Log '    OK' Green
        }
        Log '    Renewing DHCP lease...'
        $out = & ipconfig.exe /renew $a.Interface.Name 2>&1
        $rc2 = $LASTEXITCODE
        $out | ForEach-Object { Log ('      ' + $_) }
        if ($rc2 -ne 0) {
            Log ('    Renew FAILED (exit code ' + $rc2 + ')') Red
            $allOk = $false
            # FALLBACK: Try adapter restart if ipconfig renew failed
            Log '    Attempting adapter restart as fallback...' Yellow
            try {
                Disable-NetAdapter -InterfaceIndex $a.Interface.ifIndex -Confirm:$false -ErrorAction Stop
                Start-Sleep -Seconds 2
                Enable-NetAdapter -InterfaceIndex $a.Interface.ifIndex -Confirm:$false -ErrorAction Stop
                Start-Sleep -Seconds 3
                Log '    Adapter restart completed.' Green
                $allOk = $true
            } catch {
                Log ('    Adapter restart FAILED: ' + $_.Exception.Message) Red
                $allOk = $false
            }
        }
        # Verify new IP
        Start-Sleep -Seconds 2
        $newIp = (Get-NetIPConfiguration -InterfaceIndex $a.Interface.ifIndex -ErrorAction SilentlyContinue).IPv4Address.IPAddress
        if ($newIp) {
            Log ("    New IP: {0}" -f $newIp) Green
        } else {
            Log '    No IPv4 address assigned after renew.' Yellow
            $allOk = $false
        }
    }
    $s = if ($allOk) { 'PASS' } else { 'WARN' }
    Add-Summary 'DHCP Renew' $s ("{0} adapter(s) processed" -f $dhcpAdapters.Count)
}

function Section-ResetWinsock {
    if (-not (Confirm-Action 'Reset Winsock catalog (netsh winsock reset)', 'Requires reboot to take full effect')) {
        Add-Summary 'Winsock Reset' 'INFO' 'Skipped by user'
        return
    }
    $out = & netsh.exe winsock reset 2>&1
    Log ('  ' + ($out -join "`n  "))
    Log '  Winsock reset completed. REBOOT REQUIRED.' Green
    Add-Summary 'Winsock Reset' 'PASS' 'Executed - reboot required'
}

function Section-ResetTCPIP {
    if (-not (Confirm-Action 'Reset TCP/IP stack (netsh int ip reset)', 'Requires reboot to take full effect')) {
        Add-Summary 'TCP/IP Reset' 'INFO' 'Skipped by user'
        return
    }
    $out = & netsh.exe int ip reset 2>&1
    Log ('  ' + ($out -join "`n  "))
    Log '  TCP/IP reset completed. REBOOT REQUIRED.' Green
    Add-Summary 'TCP/IP Reset' 'PASS' 'Executed - reboot required'
}

function Section-SetDNS {
    $adapters = Get-NetAdapter -Physical | Where-Object { $_.Status -eq 'Up' }
    if (-not $adapters) {
        Log '  No active physical adapters found.' Yellow
        Add-Summary 'Set DNS' 'WARN' 'No adapters'
        return
    }
    Log '  Available adapters:'
    $i = 1
    foreach ($a in $adapters) {
        Log ('  [{0}] {1} ({2})' -f $i, $a.Name, $a.InterfaceDescription)
        $i++
    }
    $choice = Read-Host '  Select adapter number'
    if (-not ($choice -match '^\d+$')) { Log '  Invalid selection.' Red; Add-Summary 'Set DNS' 'FAIL' 'Invalid selection'; return }
    $idx = [int]$choice - 1
    if ($idx -lt 0 -or $idx -ge $adapters.Count) { Log '  Selection out of range.' Red; Add-Summary 'Set DNS' 'FAIL' 'Out of range'; return }
    $adapter = $adapters[$idx]

    # DNS Presets
    Log ''
    Log '  DNS Presets:' Cyan
    Log '  1. Cloudflare (1.1.1.1, 1.0.0.1) - Privacy focused'
    Log '  2. Google     (8.8.8.8, 8.8.4.4)   - Reliability'
    Log '  3. Quad9      (9.9.9.9, 149.112.112.112) - Security'
    Log '  4. OpenDNS    (208.67.222.222, 208.67.220.220) - Filtering'
    Log '  5. Custom'
    $preset = Read-Host '  Choose preset [1-5]'
    $dnsList = @()
    switch ($preset) {
        '1' { $dnsList = @('1.1.1.1', '1.0.0.1') }
        '2' { $dnsList = @('8.8.8.8', '8.8.4.4') }
        '3' { $dnsList = @('9.9.9.9', '149.112.112.112') }
        '4' { $dnsList = @('208.67.222.222', '208.67.220.220') }
        '5' {
            $dns1 = Read-Host '  Primary DNS (e.g., 1.1.1.1)'
            $dns2 = Read-Host '  Secondary DNS (e.g., 1.0.0.1) [Enter to skip]'
            if ($dns1) {
                if (-not ($dns1 -match '^(?:(?:25[0-5]|2[0-4][0-9]|1?[0-9]{1,2})\.){3}(?:25[0-5]|2[0-4][0-9]|1?[0-9]{1,2})$')) {
                    Log '  Invalid IPv4 address: ' + $dns1 Red
                    Add-Summary 'Set DNS' 'FAIL' 'Invalid primary DNS'
                    return
                }
                $dnsList += $dns1
            }
            if ($dns2) {
                if (-not ($dns2 -match '^(?:(?:25[0-5]|2[0-4][0-9]|1?[0-9]{1,2})\.){3}(?:25[0-5]|2[0-4][0-9]|1?[0-9]{1,2})$')) {
                    Log '  Invalid IPv4 address: ' + $dns2 Red
                    Add-Summary 'Set DNS' 'FAIL' 'Invalid secondary DNS'
                    return
                }
                $dnsList += $dns2
            }
        }
        default { Log '  Invalid preset.' Red; Add-Summary 'Set DNS' 'FAIL' 'Invalid preset'; return }
    }
    if (-not $dnsList) { Log '  No DNS servers provided.' Yellow; Add-Summary 'Set DNS' 'INFO' 'Skipped'; return }

    if (-not (Confirm-Action ("Set DNS servers on '{0}' to: {1}" -f $adapter.Name, ($dnsList -join ', ')))) {
        Add-Summary 'Set DNS' 'INFO' 'Skipped by user'
        return
    }
    try {
        Set-DnsClientServerAddress -InterfaceAlias $adapter.Name -ServerAddresses $dnsList -ErrorAction Stop
        Log ('  DNS servers set successfully on {0}.' -f $adapter.Name) Green
        Add-Summary 'Set DNS' 'PASS' ("{0} -> {1}" -f $adapter.Name, ($dnsList -join ', '))
    } catch {
        Log ('  ERROR: ' + $_.Exception.Message) Red
        Add-Summary 'Set DNS' 'FAIL' $_.Exception.Message
    }
}

function Section-TestHost {
    $host = Read-Host '  Hostname or IP to test'
    if (-not $host) { Log '  No host provided.' Yellow; Add-Summary 'Test Host' 'INFO' 'Skipped'; return }
    $count = Read-Host '  Ping count [default 4]'
    if (-not ($count -match '^\d+$')) { $count = 4 }
    Log ("  Testing {0} with {1} pings..." -f $host, $count)
    $ok = Test-Connection -ComputerName $host -Count $count -Quiet
    $state = if ($ok) { 'REACHABLE' } else { 'NOT REACHABLE' }
    Log ("  Result: {0}" -f $state)
    $s = if ($ok) { 'PASS' } else { 'FAIL' }
    Add-Summary 'Test Host' $s $host
}

function Section-TestPort {
    $host = Read-Host '  Target host'
    if (-not $host) { Log '  No host provided.' Yellow; Add-Summary 'Test Port' 'INFO' 'Skipped'; return }
    $port = Read-Host '  TCP port [default 443]'
    if (-not ($port -match '^\d+$')) { $port = 443 }
    $timeout = Read-Host '  Timeout ms [default 5000]'
    if (-not ($timeout -match '^\d+$')) { $timeout = 5000 }
    Log ("  Testing TCP {0}:{1}..." -f $host, $port)
    $ok = Test-TcpPort -Target $host -Port $port -TimeoutMs $timeout
    $state = if ($ok) { 'OPEN' } else { 'CLOSED / FILTERED' }
    Log ("  Result: {0}" -f $state)
    $s = if ($ok) { 'PASS' } else { 'FAIL' }
    Add-Summary 'Test TCP Port' $s ("{0}:{1}" -f $host, $port)
}

function Section-FullRepair {
    Log ''
    Log '  ===== FULL NETWORK REPAIR (DHCP-aware) =====' Yellow
    Log '  This will execute:' Cyan
    Log '    1. ipconfig /flushdns'
    Log '    2. netsh winsock reset'
    Log '    3. netsh int ip reset'
    Log '    4. ipconfig /release + /renew (ONLY on DHCP adapters)'
    Log ''
    Log '  Steps 2 and 3 require a REBOOT to take full effect.' Red
    if (-not (Confirm-Action 'Execute FULL NETWORK REPAIR sequence')) {
        Add-Summary 'Full Repair' 'INFO' 'Skipped by user'
        return
    }
    Log ''
    $repairResults = @()

    # 1. Flush DNS
    Log '  [1/4] Flushing DNS cache...' Cyan
    $out = & ipconfig.exe /flushdns 2>&1
    $rc = $LASTEXITCODE
    $out | ForEach-Object { Log ('    ' + $_) }
    $repairResults += [pscustomobject]@{ Step = 'Flush DNS'; ExitCode = $rc; Status = if ($rc -eq 0) { 'PASS' } else { 'FAIL' } }
    if ($rc -ne 0) { Log ('    FAILED (exit code ' + $rc + ')') Red } else { Log '    OK' Green }

    # 2. Winsock reset
    Log '  [2/4] Resetting Winsock...' Cyan
    $out = & netsh.exe winsock reset 2>&1
    $rc = $LASTEXITCODE
    $out | ForEach-Object { Log ('    ' + $_) }
    $repairResults += [pscustomobject]@{ Step = 'Winsock Reset'; ExitCode = $rc; Status = if ($rc -eq 0) { 'PASS' } else { 'FAIL' } }
    if ($rc -ne 0) { Log ('    FAILED (exit code ' + $rc + ')') Red } else { Log '    OK - REBOOT REQUIRED' Green }

    # 3. TCP/IP reset
    Log '  [3/4] Resetting TCP/IP stack...' Cyan
    $out = & netsh.exe int ip reset 2>&1
    $rc = $LASTEXITCODE
    $out | ForEach-Object { Log ('    ' + $_) }
    $repairResults += [pscustomobject]@{ Step = 'TCP/IP Reset'; ExitCode = $rc; Status = if ($rc -eq 0) { 'PASS' } else { 'FAIL' } }
    if ($rc -ne 0) { Log ('    FAILED (exit code ' + $rc + ')') Red } else { Log '    OK - REBOOT REQUIRED' Green }

    # 4. DHCP renew (DHCP adapters only)
    Log '  [4/4] Renewing DHCP leases (DHCP adapters only)...' Cyan
    $adapters = Get-DhcpAdapters
    $dhcpAdapters = @($adapters | Where-Object { $_.DhcpEnabled })
    if ($dhcpAdapters) {
        $renewAllOk = $true
        foreach ($a in $dhcpAdapters) {
            Log ("    {0}..." -f $a.Interface.Name)
            try {
                $ipIf = Get-NetIPInterface -InterfaceIndex $a.Interface.ifIndex -AddressFamily IPv4 -ErrorAction Stop
                if ($ipIf.Dhcp -eq 'Enabled') {
                    Disable-NetAdapter -InterfaceIndex $a.Interface.ifIndex -Confirm:$false -ErrorAction Stop
                    Start-Sleep -Seconds 2
                    Enable-NetAdapter -InterfaceIndex $a.Interface.ifIndex -Confirm:$false -ErrorAction Stop
                    Start-Sleep -Seconds 3
                    $repairResults += [pscustomobject]@{ Step = "DHCP Renew: $($a.Interface.Name)"; ExitCode = 0; Status = 'PASS' }
                    Log '      OK (adapter restart)' Green
                } else {
                    $out = & ipconfig.exe /release $a.Interface.Name 2>&1
                    $rc1 = $LASTEXITCODE
                    $out = & ipconfig.exe /renew $a.Interface.Name 2>&1
                    $rc2 = $LASTEXITCODE
                    $rc = if ($rc1 -eq 0 -and $rc2 -eq 0) { 0 } else { 1 }
                    $repairResults += [pscustomobject]@{ Step = "DHCP Renew: $($a.Interface.Name)"; ExitCode = $rc; Status = if ($rc -eq 0) { 'PASS' } else { 'FAIL' } }
                    if ($rc -ne 0) { $renewAllOk = $false; Log ('      FAILED (release={0}, renew={1})' -f $rc1, $rc2) Red } else { Log '      OK' Green }
                }
            } catch {
                $repairResults += [pscustomobject]@{ Step = "DHCP Renew: $($a.Interface.Name)"; ExitCode = 1; Status = 'FAIL' }
                $renewAllOk = $false
                Log ("      FAILED: {0}" -f $_.Exception.Message) Red
            }
        }
    } else {
        Log '    No DHCP adapters - skipped release/renew.' Gray
        $repairResults += [pscustomobject]@{ Step = 'DHCP Renew'; ExitCode = 0; Status = 'INFO' }
    }

    # Summary
    Log ''
    $failCount = @($repairResults | Where-Object { $_.Status -eq 'FAIL' }).Count
    $warnCount = @($repairResults | Where-Object { $_.Status -eq 'WARN' }).Count
    $passCount = @($repairResults | Where-Object { $_.Status -eq 'PASS' }).Count
    $infoCount = @($repairResults | Where-Object { $_.Status -eq 'INFO' }).Count

    Log '  REPAIR SUMMARY:' Cyan
    foreach ($r in $repairResults) {
        $color = if ($r.Status -eq 'PASS') { 'Green' } elseif ($r.Status -eq 'FAIL') { 'Red' } elseif ($r.Status -eq 'WARN') { 'Yellow' } else { 'Gray' }
        Log ("    [{0}] {1} (exit {2})" -f $r.Status, $r.Step, $r.ExitCode) $color
    }

    $overall = if ($failCount -gt 0) { 'FAIL' } elseif ($warnCount -gt 0) { 'WARN' } else { 'PASS' }
    $detail = "Pass={0}, Fail={1}, Info={2}" -f $passCount, $failCount, $infoCount
    if ($failCount -gt 0) { Log ("  OVERALL: FAIL - {0} step(s) failed" -f $failCount) Red }
    elseif ($warnCount -gt 0) { Log ("  OVERALL: WARN" -f $warnCount) Yellow }
    else { Log '  OVERALL: PASS - All steps completed successfully' Green }
    Log '  IMPORTANT: Reboot required for Winsock and TCP/IP resets to take effect.' Red

    Add-Summary 'Full Network Repair' $overall $detail
}

function Section-FullReport {
    Section-NetworkConfig
    Section-GatewayTest
    Section-InternetTest
    Section-DnsDiagnostic
    Section-DhcpDiagnostic
    Section-ArpTable
    Section-RouteTable
    Section-NetworkProfiles
}

# ------------------------- menu ----------------------------------

function Show-Menu {
    while ($true) {
        Clear-Host
        Write-Host ''
        Write-Host ('=' * 60) -ForegroundColor Green
        Write-Host ('   IT HELPER TOOLKIT - NETWORK FIXER v' + $ToolVersion + ' (DHCP-aware repair, per-step tracking)') -ForegroundColor Green
        Write-Host ('   {0}  |  Admin: {1}' -f $env:COMPUTERNAME, $IsAdmin) -ForegroundColor Gray
        Write-Host ('=' * 60) -ForegroundColor Green
        Write-Host ''
        Write-Host '  DIAGNOSTICS'
        Write-Host '  -----------'
        Write-Host '   1. Network Configuration'
        Write-Host '   2. Gateway Test'
        Write-Host '   3. DNS Diagnostic'
        Write-Host '   4. Internet Diagnostic (HTTPS-first)'
        Write-Host '   5. DHCP Diagnostic'
        Write-Host '   6. ARP / Neighbor Table'
        Write-Host '   7. Routing Table'
        Write-Host '   8. Network Profiles'
        Write-Host '   9. Test Specific Host'
        Write-Host '  10. Test TCP Port'
        Write-Host ''
        Write-Host '  REPAIR ACTIONS (require confirmation)'
        Write-Host '  ------------------------------------'
        Write-Host '  11. Flush DNS Cache'
        Write-Host '  12. Renew DHCP (DHCP adapters only)'
        Write-Host '  13. Reset Winsock'
        Write-Host '  14. Reset TCP/IP Stack'
        Write-Host '  15. Set DNS Servers (with presets)'
        Write-Host '  16. FULL NETWORK REPAIR (DHCP-aware, reboot warning)'
        Write-Host ''
        Write-Host '  REPORTS'
        Write-Host '  -------'
        Write-Host '  17. Full Network Report'
        Write-Host ''
        Write-Host '   0. Exit'
        Write-Host ''
        $c = (Read-Host ' Select').Trim()

        switch ($c) {
            '1'  { Start-Run 'NETWORK CONFIG'       { Section-NetworkConfig } }
            '2'  { Start-Run 'GATEWAY TEST'         { Section-GatewayTest } }
            '3'  { Start-Run 'DNS DIAGNOSTIC'       { Section-DnsDiagnostic } }
            '4'  { Start-Run 'INTERNET DIAGNOSTIC'  { Section-InternetTest } }
            '5'  { Start-Run 'DHCP DIAGNOSTIC'      { Section-DhcpDiagnostic } }
            '6'  { Start-Run 'ARP / NEIGHBOR TABLE' { Section-ArpTable } }
            '7'  { Start-Run 'ROUTING TABLE'        { Section-RouteTable } }
            '8'  { Start-Run 'NETWORK PROFILES'     { Section-NetworkProfiles } }
            '9'  { Start-Run 'TEST HOST'            { Section-TestHost } }
            '10' { Start-Run 'TEST TCP PORT'        { Section-TestPort } }
            '11' { Start-Run 'FLUSH DNS'            { Section-FlushDNS } }
            '12' { Start-Run 'DHCP RENEW'           { Section-RenewDHCP } }
            '13' { Start-Run 'WINSOCK RESET'        { Section-ResetWinsock } }
            '14' { Start-Run 'TCP/IP RESET'         { Section-ResetTCPIP } }
            '15' { Start-Run 'SET DNS'              { Section-SetDNS } }
            '16' { Start-Run 'FULL NETWORK REPAIR'  { Section-FullRepair } }
            '17' { Start-Run 'FULL NETWORK REPORT'  { Section-FullReport } }
            '0'  { return }
        }
    }
}

# ------------------------- dispatch ------------------------------

try {
    switch ($Mode) {
        'config'     { Start-Run 'NETWORK CONFIG'       { Section-NetworkConfig } }
        'gateway'    { Start-Run 'GATEWAY TEST'         { Section-GatewayTest } }
        'dns'        { Start-Run 'DNS DIAGNOSTIC'       { Section-DnsDiagnostic } }
        'internet'   { Start-Run 'INTERNET DIAGNOSTIC'  { Section-InternetTest } }
        'dhcp'       { Start-Run 'DHCP DIAGNOSTIC'      { Section-DhcpDiagnostic } }
        'arp'        { Start-Run 'ARP / NEIGHBOR TABLE' { Section-ArpTable } }
        'route'      { Start-Run 'ROUTING TABLE'        { Section-RouteTable } }
        'profile'    { Start-Run 'NETWORK PROFILES'     { Section-NetworkProfiles } }
        'host'       { Start-Run 'TEST HOST'            { Section-TestHost } }
        'port'       { Start-Run 'TEST TCP PORT'        { Section-TestPort } }
        'flushdns'   { Start-Run 'FLUSH DNS'            { Section-FlushDNS } }
        'renew'      { Start-Run 'DHCP RENEW'           { Section-RenewDHCP } }
        'winsock'    { Start-Run 'WINSOCK RESET'        { Section-ResetWinsock } }
        'tcpip'      { Start-Run 'TCP/IP RESET'         { Section-ResetTCPIP } }
        'setdns'     { Start-Run 'SET DNS'              { Section-SetDNS } }
        'repair'     { Start-Run 'FULL NETWORK REPAIR'  { Section-FullRepair } }
        'report'     { Start-Run 'FULL NETWORK REPORT'  { Section-FullReport } }
        default      { Show-Menu }
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
