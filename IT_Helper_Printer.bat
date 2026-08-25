@echo off
setlocal EnableExtensions
title IT Helper Toolkit - Printer Fixer
color 0C

rem ============================================================
rem  IT HELPER TOOLKIT - PRINTER FIXER
rem  Single-file: .bat launcher + embedded PowerShell backend
rem  Compatible: Windows 10/11, Server 2019/2022/2025
rem
rem  Usage:
rem    IT_Helper_Printer.bat           interactive menu
rem    IT_Helper_Printer.bat list      list printers
rem    IT_Helper_Printer.bat spooler   test/restart spooler
rem    IT_Helper_Printer.bat queue     clear print queue
rem    IT_Helper_Printer.bat ports     show printer ports
rem    IT_Helper_Printer.bat drivers   show printer drivers
rem    IT_Helper_Printer.bat testip    test printer IP
rem    IT_Helper_Printer.bat testport  test TCP 9100
rem    IT_Helper_Printer.bat stuck     remove stuck jobs
rem    IT_Helper_Printer.bat diag      full printer diagnostic
rem    IT_Helper_Printer.bat report    generate printer report
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
set "ITH_PS=%TEMP%\ITH_Print_%RANDOM%%RANDOM%.ps1"
set "ITH_ERR=%TEMP%\ITH_Print_err_%RANDOM%.log"
set "ITH_FLAG=%TEMP%\ITH_Print_done_%RANDOM%.flag"
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
#  IT Helper Toolkit - Printer Fixer (backend)
# ==================================================================
param(
    [Parameter(Position = 0)]
    [ValidateSet('menu', 'list', 'spooler', 'queue', 'ports', 'drivers', 'testip', 'testport', 'stuck', 'diag', 'report')]
    [string]$Mode = 'menu',

    # Explicit flag path handed over by the launcher. Travels as a
    # command-line argument, so it survives the UAC boundary; falls back
    # to the env var when this backend is run standalone.
    [string]$DoneFlag = $env:ITH_FLAG
)

$ErrorActionPreference = 'Continue'
$ToolVersion = '1.0'
$Stamp   = Get-Date -Format 'yyyyMMdd_HHmmss'
$RunDir  = Join-Path 'C:\ITHelper\Reports' ('Printer_{0}_{1}' -f $env:COMPUTERNAME, $Stamp)
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

function Confirm-Action {
    param([string]$What, [string]$Warning = '')
    Log ''
    Log ('  PROPOSED ACTION: ' + $What) Yellow
    if ($Warning) { Log ('  WARNING: ' + $Warning) Red }
    $answer = Read-Host '  Type YES to continue (anything else skips)'
    return ($answer -eq 'yes')
}

function Start-Run {
    param([string]$GroupLabel, [scriptblock]$Pipeline)
    $script:Results = New-Object System.Collections.Generic.List[object]
    Log ('=' * 62) DarkCyan
    Log ('  IT HELPER PRINTER FIXER v' + $ToolVersion + '  -  GROUP: ' + $GroupLabel) Cyan
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
    Log '|           PRINTER FIXER RESULT             |' Cyan
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

# ------------------------- printer sections ------------------------------

function Section-ListPrinters {
    Log '  Installed Printers:' Gray
    try {
        $printers = Get-Printer -ErrorAction Stop
        if ($printers) {
            Log (($printers | Select-Object Name, PortName, DriverName, Shared, Published, Location, Comment |
                Format-Table -AutoSize | Out-String).TrimEnd())
            Add-Summary 'Printers List' 'INFO' ('{0} printer(s) found' -f @($printers).Count)
        } else {
            Log '  No printers installed.' Yellow
            Add-Summary 'Printers List' 'INFO' 'No printers installed'
        }
    } catch {
        Log '  ERROR: Could not retrieve printers - ' + $_.Exception.Message Red
        Add-Summary 'Printers List' 'FAIL' $_.Exception.Message
    }
}

function Section-DefaultPrinter {
    try {
        $default = (Get-Printer | Where-Object { $_.IsDefault }) | Select-Object -First 1
        if ($default) {
            Log ('  Default Printer: {0}' -f $default.Name) Cyan
            Add-Summary 'Default Printer' 'INFO' $default.Name
        } else {
            Log '  No default printer set.' Yellow
            Add-Summary 'Default Printer' 'WARN' 'No default printer'
        }
    } catch {
        Log '  ERROR: Could not determine default printer.' Red
        Add-Summary 'Default Printer' 'FAIL' $_.Exception.Message
    }
}

function Section-TestSpooler {
    Log '  Print Spooler Service:' Gray
    $svc = Get-Service -Name 'Spooler' -ErrorAction SilentlyContinue
    if (-not $svc) {
        Log '  Print Spooler service not found.' Red
        Add-Summary 'Spooler Service' 'FAIL' 'Service not found'
        return
    }
    Log ('  Status: {0}' -f $svc.Status)
    Log ('  Start Type: {0}' -f $svc.StartType)

    if ($svc.Status -ne 'Running') {
        Add-Summary 'Spooler Service' 'FAIL' ('Status: {0}' -f $svc.Status)
        if ($IsAdmin -and (Confirm-Action 'Start Print Spooler service')) {
            try {
                Start-Service -Name 'Spooler' -ErrorAction Stop
                Log '  Print Spooler started.' Green
                Add-Summary 'Spooler Service' 'PASS' 'Started'
            } catch {
                Log ('  ERROR: ' + $_.Exception.Message) Red
                Add-Summary 'Spooler Service' 'FAIL' $_.Exception.Message
            }
        }
    } else {
        Add-Summary 'Spooler Service' 'PASS' 'Running'
    }
}

function Section-RestartSpooler {
    if (-not $IsAdmin) {
        Log '  Administrator privileges required to restart services.' Red
        Add-Summary 'Restart Spooler' 'FAIL' 'Not admin'
        return
    }
    if (-not (Confirm-Action 'Restart Print Spooler service', 'This will clear all print queues')) {
        Add-Summary 'Restart Spooler' 'INFO' 'Skipped by user'
        return
    }
    Log '  Stopping Print Spooler...'
    try { Stop-Service -Name 'Spooler' -Force -ErrorAction Stop | Out-Null } catch { }
    Log '  Starting Print Spooler...'
    try {
        Start-Service -Name 'Spooler' -ErrorAction Stop | Out-Null
        Log '  Print Spooler restarted.' Green
        Add-Summary 'Restart Spooler' 'PASS' 'Restarted'
    } catch {
        Log ('  ERROR: ' + $_.Exception.Message) Red
        Add-Summary 'Restart Spooler' 'FAIL' $_.Exception.Message
    }
}

function Section-ShowQueue {
    try {
        $jobs = Get-PrintJob -ErrorAction Stop
        if ($jobs) {
            Log (($jobs | Select-Object PrinterName, Id, Status, Size, SubmittedTime, @{n='Pages';e={$_.NumberOfPages}} |
                Format-Table -AutoSize | Out-String).TrimEnd())
            Add-Summary 'Print Queue' 'INFO' ('{0} job(s) in queue' -f @($jobs).Count)
        } else {
            Log '  Print queue is empty.' Green
            Add-Summary 'Print Queue' 'PASS' 'Empty'
        }
    } catch {
        Log '  ERROR: Could not retrieve print queue - ' + $_.Exception.Message Red
        Add-Summary 'Print Queue' 'FAIL' $_.Exception.Message
    }
}

function Section-ClearQueue {
    if (-not $IsAdmin) {
        Log '  Administrator privileges required to clear print queue.' Red
        Add-Summary 'Clear Queue' 'FAIL' 'Not admin'
        return
    }
    if (-not (Confirm-Action 'Clear ALL print jobs from ALL printers', 'This cannot be undone')) {
        Add-Summary 'Clear Queue' 'INFO' 'Skipped by user'
        return
    }
    try {
        $printers = Get-Printer -ErrorAction Stop
        foreach ($p in $printers) {
            $jobs = Get-PrintJob -PrinterName $p.Name -ErrorAction SilentlyContinue
            if ($jobs) {
                foreach ($job in $jobs) {
                    Remove-PrintJob -PrinterName $p.Name -Id $job.Id -ErrorAction Stop
                    Log ("  Removed job {0} from {1}" -f $job.Id, $p.Name)
                }
            }
        }
        Log '  All print queues cleared.' Green
        Add-Summary 'Clear Queue' 'PASS' 'All queues cleared'
    } catch {
        Log ('  ERROR: ' + $_.Exception.Message) Red
        Add-Summary 'Clear Queue' 'FAIL' $_.Exception.Message
    }
}

function Section-ShowPorts {
    Log '  Printer Ports:' Gray
    try {
        $ports = Get-PrinterPort -ErrorAction Stop
        if ($ports) {
            Log (($ports | Select-Object Name, PrinterHostAddress, PortNumber, SNMPEnabled, SNMPCommunity, SNMPDevIndex |
                Format-Table -AutoSize | Out-String).TrimEnd())
            Add-Summary 'Printer Ports' 'INFO' ('{0} port(s) found' -f @($ports).Count)
        } else {
            Log '  No printer ports configured.' Yellow
            Add-Summary 'Printer Ports' 'INFO' 'No ports'
        }
    } catch {
        Log '  ERROR: Could not retrieve printer ports - ' + $_.Exception.Message Red
        Add-Summary 'Printer Ports' 'FAIL' $_.Exception.Message
    }
}

function Section-ShowDrivers {
    Log '  Printer Drivers:' Gray
    try {
        $drivers = Get-PrinterDriver -ErrorAction Stop
        if ($drivers) {
            Log (($drivers | Select-Object Name, Version, Environment, DriverPath |
                Format-Table -AutoSize | Out-String).TrimEnd())
            Add-Summary 'Printer Drivers' 'INFO' ('{0} driver(s) found' -f @($drivers).Count)
        } else {
            Log '  No printer drivers found.' Yellow
            Add-Summary 'Printer Drivers' 'INFO' 'No drivers'
        }
    } catch {
        Log '  ERROR: Could not retrieve printer drivers - ' + $_.Exception.Message Red
        Add-Summary 'Printer Drivers' 'FAIL' $_.Exception.Message
    }
}

function Section-TestPrinterIP {
    $printers = Get-Printer -ErrorAction SilentlyContinue
    $tcpPrinters = @()
    foreach ($p in $printers) {
        $port = Get-PrinterPort -Name $p.PortName -ErrorAction SilentlyContinue
        if ($port -and $port.PrinterHostAddress) {
            $tcpPrinters += [pscustomobject]@{ Name = $p.Name; IP = $port.PrinterHostAddress; Port = $p.PortName }
        }
    }
    if (-not $tcpPrinters) {
        Log '  No TCP/IP printers found.' Yellow
        Add-Summary 'Test Printer IP' 'INFO' 'No TCP/IP printers'
        return
    }
    Log '  TCP/IP Printers found:'
    foreach ($tp in $tcpPrinters) {
        Log ("  [{0}] {1} - {2}" -f $tp.Port, $tp.Name, $tp.IP) Cyan
        $ok = Test-Connection -ComputerName $tp.IP -Count 2 -Quiet
        $state = if ($ok) { 'REACHABLE' } else { 'NOT REACHABLE' }
        Log ("      Ping: {0}" -f $state)
        Add-Summary ("Printer IP: {0}" -f $tp.Name) $(if ($ok) { 'PASS' } else { 'FAIL' }) $tp.IP
    }
}

function Section-TestPort9100 {
    $printers = Get-Printer -ErrorAction SilentlyContinue
    $tcpPrinters = @()
    foreach ($p in $printers) {
        $port = Get-PrinterPort -Name $p.PortName -ErrorAction SilentlyContinue
        if ($port -and $port.PrinterHostAddress) {
            $tcpPrinters += [pscustomobject]@{ Name = $p.Name; IP = $port.PrinterHostAddress; Port = $p.PortName }
        }
    }
    if (-not $tcpPrinters) {
        Log '  No TCP/IP printers found.' Yellow
        Add-Summary 'Test Printer Ports' 'INFO' 'No TCP/IP printers'
        return
    }
    $printerPorts = @(9100, 631, 515, 443)  # RAW, IPP, LPR, HTTPS
    $portNames = @{9100='RAW (9100)'; 631='IPP (631)'; 515='LPR (515)'; 443='HTTPS (443)'}
    foreach ($tp in $tcpPrinters) {
        Log ("  [{0}] {1} - {2}" -f $tp.Port, $tp.Name, $tp.IP) Cyan
        foreach ($p in $printerPorts) {
            $ok = Test-TcpPort -Target $tp.IP -Port $p -TimeoutMs 5000
            $state = if ($ok) { 'OPEN' } else { 'CLOSED / FILTERED' }
            Log ("      {0}: {1}" -f $portNames[$p], $state)
            Add-Summary ("Printer {0}: {1}" -f $tp.Name, $portNames[$p]) $(if ($ok) { 'PASS' } else { 'FAIL' }) ("{0}:{1}" -f $tp.IP, $p)
        }
    }
}

function Section-RemoveStuckJobs {
    if (-not $IsAdmin) {
        Log '  Administrator privileges required.' Red
        Add-Summary 'Remove Stuck Jobs' 'FAIL' 'Not admin'
        return
    }
    if (-not (Confirm-Action 'Remove STUCK print jobs (status = Blocked/Error)', 'Only jobs with error status will be removed')) {
        Add-Summary 'Remove Stuck Jobs' 'INFO' 'Skipped by user'
        return
    }
    try {
        $jobs = Get-PrintJob -ErrorAction Stop
        $stuck = @($jobs | Where-Object { $_.Status -match 'Blocked|Error|Offline' })
        if (-not $stuck) {
            Log '  No stuck jobs found.' Green
            Add-Summary 'Remove Stuck Jobs' 'PASS' 'No stuck jobs'
            return
        }
        foreach ($job in $stuck) {
            try {
                Remove-PrintJob -PrinterName $job.PrinterName -Id $job.Id -ErrorAction Stop
                Log ("  Removed stuck job {0} from {1} (status: {2})" -f $job.Id, $job.PrinterName, $job.Status) Green
            } catch {
                Log ("  Failed to remove job {0} from {1}: {2}" -f $job.Id, $job.PrinterName, $_.Exception.Message) Red
            }
        }
        Add-Summary 'Remove Stuck Jobs' 'PASS' ('{0} stuck job(s) processed' -f $stuck.Count)
    } catch {
        Log ('  ERROR: ' + $_.Exception.Message) Red
        Add-Summary 'Remove Stuck Jobs' 'FAIL' $_.Exception.Message
    }
}

function Section-FullDiag {
    Section-ListPrinters
    Section-DefaultPrinter
    Section-TestSpooler
    Section-ShowQueue
    Section-ShowPorts
    Section-ShowDrivers
    Section-TestPrinterIP
    Section-TestPort9100
}

# ------------------------- menu ----------------------------------

function Show-Menu {
    while ($true) {
        Clear-Host
        Write-Host ''
        Write-Host ('=' * 56) -ForegroundColor Green
        Write-Host ('   IT HELPER TOOLKIT - PRINTER FIXER v' + $ToolVersion) -ForegroundColor Green
        Write-Host ('   {0}  |  Admin: {1}' -f $env:COMPUTERNAME, $IsAdmin) -ForegroundColor Gray
        Write-Host ('=' * 56) -ForegroundColor Green
        Write-Host ''
        Write-Host '  DIAGNOSTICS'
        Write-Host '  -----------'
        Write-Host '   1. List All Printers'
        Write-Host '   2. Show Default Printer'
        Write-Host '   3. Test Print Spooler'
        Write-Host '   4. Show Print Queue'
        Write-Host '   5. Show Printer Ports'
        Write-Host '   6. Show Printer Drivers'
        Write-Host '   7. Test Printer IP (Ping)'
        Write-Host '   8. Test TCP Port 9100'
        Write-Host ''
        Write-Host '  REPAIR ACTIONS (require confirmation)'
        Write-Host '  ------------------------------------'
        Write-Host '   9. Restart Print Spooler'
        Write-Host '  10. Clear All Print Queues'
        Write-Host '  11. Remove Stuck Jobs'
        Write-Host ''
        Write-Host '  REPORTS'
        Write-Host '  -------'
        Write-Host '  12. Full Printer Diagnostic'
        Write-Host '  13. Generate Printer Report'
        Write-Host ''
        Write-Host '   0. Exit'
        Write-Host ''
        $c = (Read-Host ' Select').Trim()

        switch ($c) {
            '1'  { Start-Run 'LIST PRINTERS'       { Section-ListPrinters } }
            '2'  { Start-Run 'DEFAULT PRINTER'     { Section-DefaultPrinter } }
            '3'  { Start-Run 'TEST SPOOLER'        { Section-TestSpooler } }
            '4'  { Start-Run 'SHOW QUEUE'          { Section-ShowQueue } }
            '5'  { Start-Run 'PRINTER PORTS'       { Section-ShowPorts } }
            '6'  { Start-Run 'PRINTER DRIVERS'     { Section-ShowDrivers } }
            '7'  { Start-Run 'TEST PRINTER IP'     { Section-TestPrinterIP } }
            '8'  { Start-Run 'TEST TCP 9100'       { Section-TestPort9100 } }
            '9'  { Start-Run 'RESTART SPOOLER'     { Section-RestartSpooler } }
            '10' { Start-Run 'CLEAR QUEUES'        { Section-ClearQueue } }
            '11' { Start-Run 'REMOVE STUCK JOBS'   { Section-RemoveStuckJobs } }
            '12' { Start-Run 'FULL DIAGNOSTIC'     { Section-FullDiag } }
            '13' { Start-Run 'PRINTER REPORT'      { Section-FullDiag } }
            '0'  { return }
        }
    }
}

# ------------------------- dispatch ------------------------------

try {
    switch ($Mode) {
        'list'     { Start-Run 'LIST PRINTERS'       { Section-ListPrinters } }
        'spooler'  { Start-Run 'TEST SPOOLER'        { Section-TestSpooler } }
        'queue'    { Start-Run 'SHOW QUEUE'          { Section-ShowQueue } }
        'ports'    { Start-Run 'PRINTER PORTS'       { Section-ShowPorts } }
        'drivers'  { Start-Run 'PRINTER DRIVERS'     { Section-ShowDrivers } }
        'testip'   { Start-Run 'TEST PRINTER IP'     { Section-TestPrinterIP } }
        'testport' { Start-Run 'TEST TCP 9100'       { Section-TestPort9100 } }
        'stuck'    { Start-Run 'REMOVE STUCK JOBS'   { Section-RemoveStuckJobs } }
        'diag'     { Start-Run 'FULL DIAGNOSTIC'     { Section-FullDiag } }
        'report'   { Start-Run 'PRINTER REPORT'      { Section-FullDiag } }
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
