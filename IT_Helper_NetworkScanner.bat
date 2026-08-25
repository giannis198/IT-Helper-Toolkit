@echo off
setlocal EnableExtensions
title IT Helper Toolkit - Network Scanner
color 0A

rem ============================================================
rem  IT HELPER TOOLKIT - NETWORK SCANNER
rem  Single-file: .bat launcher + embedded PowerShell backend
rem  Compatible: Windows 10/11, Server 2019/2022/2025
rem
rem  Usage:
rem    IT_Helper_NetworkScanner.bat       interactive menu
rem    IT_Helper_NetworkScanner.bat subnet  detect local subnet
rem    IT_Helper_NetworkScanner.bat ping    ping sweep
rem    IT_Helper_NetworkScanner.bat host    resolve hostnames
rem    IT_Helper_NetworkScanner.bat mac     show MAC addresses
rem    IT_Helper_NetworkScanner.bat ports   scan common ports
rem    IT_Helper_NetworkScanner.bat router  find routers
rem    IT_Helper_NetworkScanner.bat printer find printers
rem    IT_Helper_NetworkScanner.bat windows find Windows PCs
rem    IT_Helper_NetworkScanner.bat csv     export CSV
rem    IT_Helper_NetworkScanner.bat full    full scan
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
set "ITH_PS=%TEMP%\ITH_Scan_%RANDOM%%RANDOM%.ps1"
set "ITH_ERR=%TEMP%\ITH_Scan_err_%RANDOM%.log"
set "ITH_FLAG=%TEMP%\ITH_Scan_done_%RANDOM%.flag"
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
#  IT Helper Toolkit - Network Scanner (backend)
# ==================================================================
param(
    [Parameter(Position = 0)]
    [ValidateSet('menu', 'subnet', 'ping', 'host', 'mac', 'ports', 'router', 'printer', 'windows', 'csv', 'full')]
    [string]$Mode = 'menu',

    # Explicit flag path handed over by the launcher. Travels as a
    # command-line argument, so it survives the UAC boundary; falls back
    # to the env var when this backend is run standalone.
    [string]$DoneFlag = $env:ITH_FLAG
)

$ErrorActionPreference = 'Continue'
$ToolVersion = '1.0'
$Stamp   = Get-Date -Format 'yyyyMMdd_HHmmss'
$RunDir  = Join-Path 'C:\ITHelper\Reports' ('NetScan_{0}_{1}' -f $env:COMPUTERNAME, $Stamp)
$TxtPath = Join-Path $RunDir 'report.txt'
$CsvPath = Join-Path $RunDir 'summary.csv'
$ExportCsvPath = Join-Path $RunDir 'scan_results.csv'
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
    param([string]$Target, [int]$Port, [int]$TimeoutMs = 1000)
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

function Get-LocalSubnet {
    $ipconf = Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } | Select-Object -First 1
    if (-not $ipconf) { return $null }
    $ip = $ipconf.IPv4Address.IPAddress
    $prefix = $ipconf.IPv4Address.PrefixLength
    if ($prefix -lt 8 -or $prefix -gt 30) { return $null }
    $mask = [System.Net.IPAddress]::new((0xFFFFFFFF -shl (32 - $prefix)) -band 0xFFFFFFFF)
    $ipBytes = [System.Net.IPAddress]::Parse($ip).GetAddressBytes()
    $maskBytes = $mask.GetAddressBytes()
    $netBytes = @()
    for ($i = 0; $i -lt 4; $i++) { $netBytes += $ipBytes[$i] -band $maskBytes[$i] }
    $network = [System.Net.IPAddress]::new($netBytes).ToString()
    return @{ Network = $network; Prefix = $prefix; Mask = $mask.ToString(); Gateway = $ipconf.IPv4DefaultGateway.NextHop }
}

function Get-IPRange {
    param($subnet)
    $ips = @()
    $network = [System.Net.IPAddress]::Parse($subnet.Network)
    $networkBytes = $network.GetAddressBytes()
    $prefix = $subnet.Prefix
    $hostBits = 32 - $prefix
    $totalHosts = [math]::Pow(2, $hostBits)
    # Limit for safety (max 1024 hosts to scan)
    $maxHosts = [math]::Min($totalHosts - 2, 1024)
    # Network byte order: we need to increment the host portion
    # For any prefix, the last (32-prefix) bits are host bits
    # We iterate from 1 to maxHosts and add to network address
    for ($i = 1; $i -le $maxHosts; $i++) {
        $ipBytes = @($networkBytes[0], $networkBytes[1], $networkBytes[2], $networkBytes[3])
        # Add i to the IP address (network byte order)
        $val = $i
        for ($j = 3; $j -ge 0; $j--) {
            $sum = $ipBytes[$j] + $val
            $ipBytes[$j] = $sum -band 0xFF
            $val = [math]::Floor($sum / 256)
            if ($val -eq 0) { break }
        }
        $ips += [System.Net.IPAddress]::new($ipBytes).ToString()
    }
    return $ips
}

function Section-DetectSubnet {
    Log '  Detecting Local Subnet:' Gray
    $subnet = Get-LocalSubnet
    if (-not $subnet) {
        Log '  Could not determine local subnet.' Red
        Add-Summary 'Subnet Detection' 'FAIL' 'No active interface with gateway'
        return $null
    }
    Log ('  Network      : {0}/{1}' -f $subnet.Network, $subnet.Prefix)
    Log ('  Netmask      : {0}' -f $subnet.Mask)
    Log ('  Gateway      : {0}' -f ($subnet.Gateway -join ', '))
    Log ('  Host IP      : {0}' -f $script:PrimaryIP)
    Add-Summary 'Subnet Detection' 'PASS' ("{0}/{1}" -f $subnet.Network, $subnet.Prefix)
    return $subnet
}

function Section-PingSweep {
    param($subnet = $null)
    if (-not $subnet) { $subnet = Get-LocalSubnet }
    if (-not $subnet) { Add-Summary 'Ping Sweep' 'FAIL' 'No subnet'; return }

    Log ("  Ping sweeping {0}/{1}..." -f $subnet.Network, $subnet.Prefix) Cyan
    $ips = Get-IPRange $subnet
    $results = @()
    $up = 0; $down = 0
    foreach ($ip in $ips) {
        $ok = Test-Connection -ComputerName $ip -Count 1 -Quiet
        $status = if ($ok) { 'UP'; $up++ } else { 'DOWN'; $down++ }
        $results += [pscustomobject]@{ IP = $ip; Status = $status; Hostname = ''; MAC = ''; Vendor = ''; Type = '' }
        if ($ok) { Log ("  {0,-15} {1}" -f $ip, $status) Green } else { Log ("  {0,-15} {1}" -f $ip, $status) Gray }
    }
    Log ("  Total: {0} UP, {1} DOWN" -f $up, $down)
    Add-Summary 'Ping Sweep' 'INFO' ("{0} UP, {1} DOWN" -f $up, $down)
    $script:ScanResults = $results
    return $results
}

function Section-ResolveHostnames {
    if (-not $script:ScanResults) {
        Log '  No scan results to resolve. Run ping sweep first.' Yellow
        Add-Summary 'Resolve Hostnames' 'WARN' 'No prior results'
        return
    }
    Log '  Resolving hostnames...' Cyan
    foreach ($r in $script:ScanResults) {
        if ($r.Status -eq 'UP') {
            try {
                $hn = [System.Net.Dns]::GetHostEntry($r.IP).HostName
                $r.Hostname = $hn
                Log ("  {0,-15} {1}" -f $r.IP, $hn)
            } catch { $r.Hostname = 'N/A' }
        }
    }
    Add-Summary 'Resolve Hostnames' 'INFO' 'Completed'
}

function Section-GetMAC {
    if (-not $script:ScanResults) {
        Log '  No scan results. Run ping sweep first.' Yellow
        Add-Summary 'Get MAC' 'WARN' 'No prior results'
        return
    }
    Log '  Getting MAC addresses (ARP)...' Cyan
    foreach ($r in $script:ScanResults) {
        if ($r.Status -eq 'UP') {
            try {
                $arp = arp -a $r.IP 2>$null
                if ($arp -match '([0-9a-f]{2}[:-]){5}[0-9a-f]{2}') {
                    $mac = $matches[0].ToUpper()
                    $r.MAC = $mac
                    # Lookup vendor (first 3 octets)
                    $oui = $mac.Substring(0,8).Replace(':','-')
                    Log ("  {0,-15} {1}" -f $r.IP, $mac)
                } else { $r.MAC = 'N/A' }
            } catch { $r.MAC = 'N/A' }
        }
    }
    Add-Summary 'Get MAC Addresses' 'INFO' 'Completed'
}

function Section-ScanPorts {
    if (-not $script:ScanResults) {
        Log '  No scan results. Run ping sweep first.' Yellow
        Add-Summary 'Port Scan' 'WARN' 'No prior results'
        return
    }
    $commonPorts = @(21,22,23,25,53,80,110,135,139,143,443,445,993,995,1433,3306,3389,5432,5900,8080,8443)
    Log ("  Scanning {0} common ports on UP hosts..." -f $commonPorts.Count) Cyan
    foreach ($r in $script:ScanResults) {
        if ($r.Status -eq 'UP') {
            $openPorts = @()
            foreach ($p in $commonPorts) {
                if (Test-TcpPort -Target $r.IP -Port $p -TimeoutMs 500) { $openPorts += $p }
            }
            if ($openPorts.Count -gt 0) {
                $r.Type = 'OPEN PORTS'
                Log ("  {0,-15} {1}" -f $r.IP, ($openPorts -join ','))
            }
        }
    }
    Add-Summary 'Port Scan' 'INFO' ('Scanned {0} ports on UP hosts' -f $commonPorts.Count)
}

function Section-FindRouters {
    param($subnet = $null)
    if (-not $script:ScanResults) { $script:ScanResults = Section-PingSweep $subnet }
    if (-not $subnet) { $subnet = Get-LocalSubnet }
    Log '  Identifying Routers/Gateways...' Cyan
    foreach ($r in $script:ScanResults) {
        if ($r.Status -eq 'UP') {
            # Check for common router ports
            $routerPorts = @(22,23,80,443,8080,8443)
            $open = @()
            foreach ($p in $routerPorts) { if (Test-TcpPort -Target $r.IP -Port $p -TimeoutMs 300) { $open += $p } }
            if ($open.Count -ge 2 -or ($subnet -and $r.IP -eq $subnet.Gateway[0])) {
                $r.Type = 'ROUTER'
                Log ("  {0,-15} ROUTER (ports: {1})" -f $r.IP, ($open -join ','))
            }
        }
    }
    Add-Summary 'Find Routers' 'INFO' 'Completed'
}

function Section-FindPrinters {
    if (-not $script:ScanResults) { Section-PingSweep }
    Log '  Identifying Printers (ports 9100, 631, 515)...' Cyan
    foreach ($r in $script:ScanResults) {
        if ($r.Status -eq 'UP') {
            $printerPorts = @(9100, 631, 515)
            $open = @()
            foreach ($p in $printerPorts) { if (Test-TcpPort -Target $r.IP -Port $p -TimeoutMs 500) { $open += $p } }
            if ($open.Count -gt 0) {
                $r.Type = 'PRINTER'
                Log ("  {0,-15} PRINTER (ports: {1})" -f $r.IP, ($open -join ','))
            }
        }
    }
    Add-Summary 'Find Printers' 'INFO' 'Completed'
}

function Section-FindWindows {
    if (-not $script:ScanResults) { Section-PingSweep }
    Log '  Identifying Windows PCs (ports 135, 139, 445, 3389)...' Cyan
    foreach ($r in $script:ScanResults) {
        if ($r.Status -eq 'UP') {
            $winPorts = @(135, 139, 445, 3389)
            $open = @()
            foreach ($p in $winPorts) { if (Test-TcpPort -Target $r.IP -Port $p -TimeoutMs 500) { $open += $p } }
            if ($open.Count -ge 2) {
                $r.Type = 'WINDOWS'
                Log ("  {0,-15} WINDOWS (ports: {1})" -f $r.IP, ($open -join ','))
            }
        }
    }
    Add-Summary 'Find Windows PCs' 'INFO' 'Completed'
}

function Section-ExportCSV {
    if (-not $script:ScanResults) {
        Log '  No scan results to export.' Yellow
        Add-Summary 'Export CSV' 'WARN' 'No results'
        return
    }
    $script:ScanResults | Export-Csv -LiteralPath $ExportCsvPath -NoTypeInformation -Encoding UTF8
    Log ("  Exported to: {0}" -f $ExportCsvPath) Green
    Add-Summary 'Export CSV' 'PASS' $ExportCsvPath
}

function Section-FullScan {
    $subnet = Section-DetectSubnet
    if ($subnet) {
        Section-PingSweep $subnet
        Section-ResolveHostnames
        Section-GetMAC
        Section-ScanPorts
        Section-FindRouters
        Section-FindPrinters
        Section-FindWindows
        Section-ExportCSV
    }
}

# ------------------------- menu ----------------------------------

function Show-Menu {
    while ($true) {
        Clear-Host
        Write-Host ''
        Write-Host ('=' * 56) -ForegroundColor Green
        Write-Host ('   IT HELPER TOOLKIT - NETWORK SCANNER v' + $ToolVersion) -ForegroundColor Green
        Write-Host ('   {0}  |  Admin: {1}' -f $env:COMPUTERNAME, $IsAdmin) -ForegroundColor Gray
        Write-Host ('=' * 56) -ForegroundColor Green
        Write-Host ''
        Write-Host '  SCANNING'
        Write-Host '  --------'
        Write-Host '   1. Detect Local Subnet'
        Write-Host '   2. Ping Sweep'
        Write-Host '   3. Resolve Hostnames'
        Write-Host '   4. Get MAC Addresses (ARP)'
        Write-Host '   5. Scan Common Ports'
        Write-Host ''
        Write-Host '  DEVICE DISCOVERY'
        Write-Host '  ----------------'
        Write-Host '   6. Find Routers/Gateways'
        Write-Host '   7. Find Printers'
        Write-Host '   8. Find Windows PCs'
        Write-Host ''
        Write-Host '  EXPORT'
        Write-Host '  ------'
        Write-Host '   9. Export to CSV'
        Write-Host '  10. Full Scan (all above)'
        Write-Host ''
        Write-Host '   0. Exit'
        Write-Host ''
        $c = (Read-Host ' Select').Trim()

        switch ($c) {
            '1'  { Start-Run 'DETECT SUBNET'   { $script:Subnet = Section-DetectSubnet } }
            '2'  { Start-Run 'PING SWEEP'      { $script:ScanResults = Section-PingSweep $script:Subnet } }
            '3'  { Start-Run 'RESOLVE HOSTS'   { Section-ResolveHostnames } }
            '4'  { Start-Run 'GET MAC'         { Section-GetMAC } }
            '5'  { Start-Run 'SCAN PORTS'      { Section-ScanPorts } }
            '6'  { Start-Run 'FIND ROUTERS'    { Section-FindRouters } }
            '7'  { Start-Run 'FIND PRINTERS'   { Section-FindPrinters } }
            '8'  { Start-Run 'FIND WINDOWS'    { Section-FindWindows } }
            '9'  { Start-Run 'EXPORT CSV'      { Section-ExportCSV } }
            '10' { Start-Run 'FULL SCAN'       { Section-FullScan } }
            '0'  { return }
        }
    }
}

# ------------------------- dispatch ------------------------------

try {
    switch ($Mode) {
        'subnet'  { Start-Run 'DETECT SUBNET'   { $script:Subnet = Section-DetectSubnet } }
        'ping'    { Start-Run 'PING SWEEP'      { $script:ScanResults = Section-PingSweep $script:Subnet } }
        'host'    { Start-Run 'RESOLVE HOSTS'   { Section-ResolveHostnames } }
        'mac'     { Start-Run 'GET MAC'         { Section-GetMAC } }
        'ports'   { Start-Run 'SCAN PORTS'      { Section-ScanPorts } }
        'router'  { Start-Run 'FIND ROUTERS'    { Section-FindRouters } }
        'printer' { Start-Run 'FIND PRINTERS'   { Section-FindPrinters } }
        'windows' { Start-Run 'FIND WINDOWS'    { Section-FindWindows } }
        'csv'     { Start-Run 'EXPORT CSV'      { Section-ExportCSV } }
        'full'    { Start-Run 'FULL SCAN'       { Section-FullScan } }
        default   { Show-Menu }
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
