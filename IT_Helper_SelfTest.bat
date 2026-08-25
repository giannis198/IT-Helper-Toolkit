@echo off
setlocal EnableExtensions
title IT Helper Toolkit - Self Test
color 0B

rem ============================================================
rem  IT HELPER TOOLKIT - SELF TEST
rem  Single-file: .bat launcher + embedded PowerShell backend
rem  Validates the entire toolkit before use
rem  Compatible: Windows 10/11, Server 2019/2022/2025
rem
rem  Usage:
rem    IT_Helper_SelfTest.bat         interactive menu
rem    IT_Helper_SelfTest.bat quick   quick validation
rem    IT_Helper_SelfTest.bat full    full validation (default)
rem    IT_Helper_SelfTest.bat payload validate embedded payloads only
rem    IT_Helper_SelfTest.bat env     environment check only
rem    Exit code: 0 = all PASS, 1 = WARN, 2 = FAIL, 250 = crash
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
set "ITH_PS=%TEMP%\ITH_ST_%RANDOM%%RANDOM%.ps1"
set "ITH_ERR=%TEMP%\ITH_ST_err_%RANDOM%.log"
set "ITH_FLAG=%TEMP%\ITH_ST_done_%RANDOM%.flag"
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
powershell -NoProfile -ExecutionPolicy Bypass -File "%ITH_PS%" %ITH_MODE% -DoneFlag "%ITH_FLAG%" -Root "%~dp0" 2>"%ITH_ERR%"
set "ITH_RC=%errorlevel%"

rem Allow filesystem to flush the DoneFlag file before checking
ping 127.0.0.1 -n 2 >nul

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
#  IT Helper Toolkit - Self Test (backend)
# ==================================================================
param(
    [Parameter(Position = 0)]
    [ValidateSet('menu', 'quick', 'full', 'payload', 'env')]
    [string]$Mode = 'full',

    [string]$Root,

    # Explicit flag path handed over by the launcher. Travels as a
    # command-line argument, so it survives the UAC boundary; falls back
    # to the env var when this backend is run standalone.
    [string]$DoneFlag = $env:ITH_FLAG
)

$ErrorActionPreference = 'Continue'
$ToolVersion = '1.0'
$Stamp   = Get-Date -Format 'yyyyMMdd_HHmmss'
$RunDir  = Join-Path 'C:\ITHelper\Reports' ('SelfTest_{0}_{1}' -f $env:COMPUTERNAME, $Stamp)
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

function Test-Command {
    param(
        [string]$Name,
        [scriptblock]$Test,
        [string]$Category = 'COMMAND'
    )
    $script:CurrentGroup = $Category
    try {
        $result = & $Test
        if ($result) {
            Log ("  [PASS] {0}" -f $Name) Green
            Add-Summary $Name 'PASS' ''
        } else {
            Log ("  [FAIL] {0}" -f $Name) Red
            Add-Summary $Name 'FAIL' 'Command returned false'
        }
    } catch {
        Log ("  [FAIL] {0} - {1}" -f $Name, $_.Exception.Message) Red
        Add-Summary $Name 'FAIL' $_.Exception.Message
    }
}

function Test-FileExists {
    param(
        [string]$Path,
        [string]$Name
    )
    $script:CurrentGroup = 'TOOL FILES'
    if (Test-Path -LiteralPath $Path) {
        Log ("  [PASS] {0}" -f $Name) Green
        Add-Summary $Name 'PASS' ''
    } else {
        Log ("  [FAIL] {0} - missing at {1}" -f $Name, $Path) Red
        Add-Summary $Name 'FAIL' ("Missing at {0}" -f $Path)
    }
}

function Test-PSCommand {
    param(
        [string]$Name
    )
    $script:CurrentGroup = 'POWERSHELL CMDLETS'
    try {
        $cmd = Get-Command -Name $Name -ErrorAction Stop
        Log ("  [PASS] {0}" -f $Name) Green
        Add-Summary $Name 'PASS' $cmd.CommandType
    } catch {
        Log ("  [FAIL] {0} - {1}" -f $Name, $_.Exception.Message) Red
        Add-Summary $Name 'FAIL' $_.Exception.Message
    }
}

function Validate-Payload {
    param(
        [string]$ToolName,
        [string]$BatPath
    )
    $script:CurrentGroup = 'PAYLOAD VALIDATION'
    try {
        $content = Get-Content -LiteralPath $BatPath -Raw
        $marker = '#__PS_PAYLOAD__'
        $idx = $content.IndexOf($marker)
        if ($idx -lt 0) {
            Log ("  [FAIL] {0} - payload marker not found" -f $ToolName) Red
            Add-Summary ("Payload: {0}" -f $ToolName) 'FAIL' 'Marker missing'
            return
        }
        $payload = $content.Substring($idx + $marker.Length)
        $tmpPath = [System.IO.Path]::GetTempFileName()
        $payload | Set-Content -LiteralPath $tmpPath -Encoding UTF8
        $errs = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($tmpPath, [ref]$null, [ref]$errs)
        Remove-Item -LiteralPath $tmpPath -Force -ErrorAction SilentlyContinue
        if ($errs -and $errs.Count -gt 0) {
            Log ("  [FAIL] {0} - {1} syntax error(s)" -f $ToolName, $errs.Count) Red
            foreach ($e in $errs) {
                Log ("    Line {0}: {1}" -f $e.Extent.StartLineNumber, $e.Message) DarkRed
            }
            Add-Summary ("Payload: {0}" -f $ToolName) 'FAIL' ("{0} syntax errors" -f $errs.Count)
        } else {
            Log ("  [PASS] {0}" -f $ToolName) Green
            Add-Summary ("Payload: {0}" -f $ToolName) 'PASS' 'Syntax OK'
        }
    } catch {
        Log ("  [FAIL] {0} - {1}" -f $ToolName, $_.Exception.Message) Red
        Add-Summary ("Payload: {0}" -f $ToolName) 'FAIL' $_.Exception.Message
    }
}

function Test-BatStructure {
    param(
        [string]$ToolName,
        [string]$BatPath
    )
    $script:CurrentGroup = 'BATCH STRUCTURE'
    try {
        $content = Get-Content -LiteralPath $BatPath -Raw
        $checks = @(
            @{Name='@echo off'; Pattern='^@echo off'}
            @{Name='setlocal'; Pattern='^setlocal'}
            @{Name='Payload marker'; Pattern='#__PS_PAYLOAD__'}
            @{Name='Requires'; Pattern='#Requires -Version 5.1'}
            @{Name='param()'; Pattern='param\('}
            @{Name='DoneFlag mechanism'; Pattern='ITH_FLAG|WDT_FLAG'}
            @{Name='Crash guard'; Pattern='not exist.*ITH_FLAG|not exist.*WDT_FLAG'}
            @{Name='Payload marker unique'; Pattern='#__PS_PAYLOAD__'}
        )
        $failCount = 0
        foreach ($c in $checks) {
            if ($content -match $c.Pattern) {
                Log ("  [PASS] {0}: {1}" -f $ToolName, $c.Name) Green
                Add-Summary ("BAT: {0}" -f $c.Name) 'PASS' ''
            } else {
                Log ("  [FAIL] {0}: {1}" -f $ToolName, $c.Name) Red
                Add-Summary ("BAT: {0}" -f $c.Name) 'FAIL' 'Missing or malformed'
                $failCount++
            }
        }
        $markers = [regex]::Matches($content, '#__PS_PAYLOAD__').Count
        if ($markers -eq 1) {
            Log ("  [PASS] {0}: Single payload marker" -f $ToolName) Green
            Add-Summary "BAT: Payload Marker Count" 'PASS' ''
        } else {
            Log ("  [FAIL] {0}: {1} payload markers (expected 1)" -f $ToolName, $markers) Red
            Add-Summary "BAT: Payload Marker Count" 'FAIL' ("{0} markers found" -f $markers)
        }
        if ($failCount -eq 0 -and $markers -eq 1) {
            Add-Summary ("BAT Structure: {0}" -f $ToolName) 'PASS' 'All checks passed'
        } else {
            Add-Summary ("BAT Structure: {0}" -f $ToolName) 'FAIL' ("{0} checks failed" -f $failCount)
        }
    } catch {
        Log ("  [FAIL] {0} - {1}" -f $ToolName, $_.Exception.Message) Red
        Add-Summary ("BAT Structure: {0}" -f $ToolName) 'FAIL' $_.Exception.Message
    }
}

function Start-Run {
    param([string]$GroupLabel, [scriptblock]$Pipeline)
    $script:Results = New-Object System.Collections.Generic.List[object]
    Log ('=' * 62) DarkCyan
    Log ('  IT HELPER SELF TEST v' + $ToolVersion + '  -  GROUP: ' + $GroupLabel) Cyan
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

    $overall = 'READY'
    if     ($fail -gt 0) { $overall = 'NOT READY - ' + $fail + ' FAILURE(S)' }
    elseif ($warn -gt 0) { $overall = 'REVIEW NEEDED - ' + $warn + ' WARNING(S)' }

    Log ''
    Log '+============================================+' Cyan
    Log '|         SELF TEST RESULT                   |' Cyan
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
        if ($fail -gt 0) { exit 2 }
        elseif ($warn -gt 0) { exit 1 }
        else { exit 0 }
    }
}

# ------------------------- test sections ------------------------------

function Section-Environment {
    $script:CurrentGroup = 'ENVIRONMENT'
    Log ''; Log ('=' * 56) DarkCyan; Log ('  ENVIRONMENT CHECK') Cyan; Log ('=' * 56) DarkCyan

    $os = Get-CimInstance Win32_OperatingSystem
    Log ("  OS: {0} (Build {1})" -f $os.Caption.Trim(), $os.BuildNumber) Gray
    Add-Summary 'OS Version' 'INFO' ("{0} build {1}" -f $os.Caption.Trim(), $os.BuildNumber)

    $psVer = $PSVersionTable.PSVersion
    Log ("  PowerShell: {0}" -f $psVer.ToString()) Gray
    $psOk = $psVer.Major -ge 5
    Log ("  PowerShell 5.1+: {0}" -f $(if ($psOk) { 'PASS' } else { 'FAIL' })) $(if ($psOk) { 'Green' } else { 'Red' })
    Add-Summary 'PowerShell Version' $(if ($psOk) { 'PASS' } else { 'FAIL' }) $psVer.ToString()

    Log ("  Administrator: {0}" -f $(if ($IsAdmin) { 'YES' } else { 'NO' })) $(if ($IsAdmin) { 'Green' } else { 'Red' })
    Add-Summary 'Administrator' $(if ($IsAdmin) { 'PASS' } else { 'FAIL' }) ''

    Log ("  SystemRoot: {0} {1}" -f $env:SystemRoot, $(if (Test-Path -LiteralPath $env:SystemRoot) { '[EXISTS]' } else { '[MISSING]' })) Green
    Log ("  TEMP: {0} {1}" -f $env:TEMP, $(if (Test-Path -LiteralPath $env:TEMP) { '[EXISTS]' } else { '[MISSING]' })) Green
    Log ("  ITHelper: C:\ITHelper {0}" -f $(if (Test-Path -LiteralPath 'C:\ITHelper') { '[EXISTS]' } else { '[MISSING]' })) $(if (Test-Path -LiteralPath 'C:\ITHelper') { 'Green' } else { 'Yellow' })
    Add-Summary 'Core Paths' 'INFO' ''

    try {
        $netVer = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -Name Release -ErrorAction Stop
        $release = $netVer.Release
        if ($release -eq 528040) { $netDesc = '4.8' }
        elseif ($release -eq 461808) { $netDesc = '4.7.2' }
        elseif ($release -eq 461308) { $netDesc = '4.7.1' }
        elseif ($release -eq 460798) { $netDesc = '4.7' }
        elseif ($release -eq 394802) { $netDesc = '4.6.2' }
        elseif ($release -eq 394254) { $netDesc = '4.6.1' }
        elseif ($release -eq 393295) { $netDesc = '4.6' }
        else { $netDesc = "Unknown (Release: $release)" }
        Log ("  .NET Framework: {0}" -f $netDesc) Gray
        Add-Summary '.NET Framework' 'INFO' $netDesc
    } catch {
        Log '  .NET Framework: Unknown' Yellow
    }
}

function Section-CoreCommands {
    $script:CurrentGroup = 'CORE COMMANDS'
    Log ''; Log ('=' * 56) DarkCyan; Log ('  CORE COMMANDS / CMDLETS') Cyan; Log ('=' * 56) DarkCyan

    $coreCmdlets = 'Get-CimInstance','Get-NetAdapter','Get-NetIPConfiguration','Get-PhysicalDisk','Get-PnpDevice',
        'Get-WinEvent','Get-Service','Get-Process','Get-NetRoute','Get-NetNeighbor',
        'Get-DnsClientServerAddress','Get-NetConnectionProfile','Resolve-DnsName','Test-Connection',
        'Get-Service','Get-Process','Start-Service','Stop-Service','Restart-Service',
        'Disable-NetAdapter','Enable-NetAdapter','Set-DnsClientServerAddress','Resolve-DnsName','Test-Connection',
        'New-Item','Remove-Item','Start-Process','Start-Transcript','Stop-Transcript'

    foreach ($c in $coreCmdlets) {
        Test-PSCommand -Name $c
    }

    $optCmdlets = 'Get-Printer','Get-PrinterPort','Get-PrinterDriver','Get-PrintJob',
        'Get-DnsServerZone','Get-DnsServerStatistics','Get-DhcpServerv4Scope'

    foreach ($c in $optCmdlets) {
        $script:CurrentGroup = 'OPTIONAL/ROLE-DEPENDENT'
        try {
            $cmd = Get-Command -Name $c -ErrorAction Stop
            Log ("  [INFO] {0} - available ({1})" -f $c, $cmd.CommandType) Cyan
            Add-Summary $c 'INFO' ("Role-dependent: {0}" -f $cmd.CommandType)
        } catch {
            Log ("  [INFO] {0} - not available (role/module not installed)" -f $c) Yellow
            Add-Summary $c 'INFO' 'Role/module not installed'
        }
    }

    $extCmds = 'pnputil.exe','robocopy.exe','sfc.exe','dism.exe','netsh.exe',
        'ipconfig.exe','chkdsk.exe','arp.exe','route.exe','net.exe','sc.exe','reg.exe'

    foreach ($c in $extCmds) {
        try {
            $cmd = Get-Command -Name $c -CommandType Application -ErrorAction Stop
            Log ("  [PASS] {0}" -f $c) Green
            Add-Summary $c 'PASS' $cmd.Source
        } catch {
            Log ("  [FAIL] {0} - not found" -f $c) Red
            Add-Summary $c 'FAIL' 'Executable not found'
        }
    }

    $optCmds = 'wmic.exe'
    foreach ($c in $optCmds) {
        $script:CurrentGroup = 'OPTIONAL/LEGACY'
        try {
            $cmd = Get-Command -Name $c -CommandType Application -ErrorAction Stop
            Log ("  [INFO] {0} - available (legacy)" -f $c) Cyan
            Add-Summary $c 'INFO' 'Legacy command available'
        } catch {
            Log ("  [INFO] {0} - not available (legacy)" -f $c) Yellow
            Add-Summary $c 'INFO' 'Legacy command not available'
        }
    }
}

function Section-ToolFiles {
    $script:CurrentGroup = 'TOOL FILES'
    Log ''; Log ('=' * 56) DarkCyan; Log ('  TOOL FILES') Cyan; Log ('=' * 56) DarkCyan

    $root = $Root
    if (-not $root) { $root = $env:ITH_ROOT }
    if (-not $root) { $root = (Get-Location).Path + '\' }

    $tools = @(
        'IT_Helper_Network.bat',
        'IT_Helper_PC_Support.bat',
        'IT_Helper_Printer.bat',
        'IT_Helper_RDP.bat',
        'IT_Helper_WindowsRepair.bat',
        'IT_Helper_Backup.bat',
        'IT_Helper_NetworkScanner.bat',
        'IT_Helper_Device.bat',
        'IT_Helper_Server.bat',
        'IT_Helper_Launcher.bat',
        'IT_Helper_SelfTest.bat'
    )

    foreach ($t in $tools) {
        $full = Join-Path $root $t
        Test-FileExists -Path $full -Name $t
    }
}

function Section-PayloadValidation {
    $script:CurrentGroup = 'PAYLOAD VALIDATION'
    Log ''; Log ('=' * 56) DarkCyan; Log ('  EMBEDDED PAYLOAD SYNTAX VALIDATION') Cyan; Log ('=' * 56) DarkCyan

    $root = $Root
    if (-not $root) { $root = $env:ITH_ROOT }
    if (-not $root) { $root = (Get-Location).Path + '\' }

    $toolList = @(
        @{Name='Network';           File='IT_Helper_Network.bat'},
        @{Name='PC Support';        File='IT_Helper_PC_Support.bat'},
        @{Name='Printer';           File='IT_Helper_Printer.bat'},
        @{Name='RDP';               File='IT_Helper_RDP.bat'},
        @{Name='Windows Repair';    File='IT_Helper_WindowsRepair.bat'},
        @{Name='Backup';            File='IT_Helper_Backup.bat'},
        @{Name='Network Scanner';   File='IT_Helper_NetworkScanner.bat'},
        @{Name='Device';            File='IT_Helper_Device.bat'},
        @{Name='Server';            File='IT_Helper_Server.bat'}
    )

    foreach ($t in $toolList) {
        $full = Join-Path $root $t.File
        if (Test-Path -LiteralPath $full) {
            Validate-Payload -ToolName $t.Name -BatPath $full
            Test-BatStructure -ToolName $t.Name -BatPath $full
        } else {
            Log ("  [SKIP] {0} - file not found" -f $t.Name) Yellow
            Add-Summary ("Payload: {0}" -f $t.Name) 'SKIP' 'File missing'
        }
    }
}

function Section-CoreChecks {
    $script:CurrentGroup = 'CORE CHECKS'
    Log ''; Log ('=' * 56) DarkCyan; Log ('  ADDITIONAL CORE CHECKS') Cyan; Log ('=' * 56) DarkCyan

    try {
        $testDir = 'C:\ITHelper\Reports'
        if (-not (Test-Path $testDir)) { New-Item -ItemType Directory -Path $testDir -Force | Out-Null }
        $testFile = Join-Path $testDir 'selftest_write.tmp'
        'test' | Set-Content -LiteralPath $testFile -Force
        Remove-Item -LiteralPath $testFile -Force
        Log '  Reports directory writable: YES' Green
        Add-Summary 'Reports Directory' 'PASS' 'Writable'
    } catch {
        Log ('  Reports directory writable: NO - ' + $_.Exception.Message) Red
        Add-Summary 'Reports Directory' 'FAIL' $_.Exception.Message
    }

    try {
        $testLog = Join-Path $env:TEMP 'selftest_transcript.tmp'
        Start-Transcript -Path $testLog -Force | Out-Null
        Stop-Transcript | Out-Null
        Remove-Item -LiteralPath $testLog -Force -ErrorAction SilentlyContinue
        Log '  Transcript capability: YES' Green
        Add-Summary 'Transcript' 'PASS' 'Working'
    } catch {
        Log ('  Transcript capability: NO - ' + $_.Exception.Message) Red
        Add-Summary 'Transcript' 'FAIL' $_.Exception.Message
    }

    if ($IsAdmin) {
        Log '  UAC elevation: ALREADY ADMIN' Green
        Add-Summary 'UAC Elevation' 'PASS' 'Already elevated'
    } else {
        Log '  UAC elevation: Will prompt on run' Yellow
        Add-Summary 'UAC Elevation' 'INFO' 'Requires elevation on launch'
    }
}

function Invoke-Quick {
    Section-Environment
    Section-CoreCommands
    Section-ToolFiles
}

function Invoke-Full {
    Section-Environment
    Section-CoreCommands
    Section-ToolFiles
    Section-PayloadValidation
    Section-CoreChecks
}

function Invoke-PayloadOnly {
    Section-PayloadValidation
}

function Invoke-EnvOnly {
    Section-Environment
}

function Show-Menu {
    while ($true) {
        Clear-Host
        Write-Host ''
        Write-Host ('=' * 56) -ForegroundColor Green
        Write-Host ('   IT HELPER TOOLKIT - SELF TEST v' + $ToolVersion) -ForegroundColor Green
        Write-Host ('   {0}  |  Admin: {1}' -f $env:COMPUTERNAME, $IsAdmin) -ForegroundColor Gray
        Write-Host ('=' * 56) -ForegroundColor Green
        Write-Host ''
        Write-Host '   1. QUICK TEST        (environment + core commands + tool files)'
        Write-Host '   2. FULL TEST         (all checks + payload validation)'
        Write-Host '   3. PAYLOAD ONLY      (embedded syntax validation only)'
        Write-Host '   4. ENVIRONMENT ONLY  (OS, PS version, admin, paths)'
        Write-Host ''
        Write-Host '   0. Exit'
        Write-Host ''
        $c = (Read-Host ' Select').Trim()

        switch ($c) {
            '1' { Start-Run 'QUICK TEST'        { Invoke-Quick } }
            '2' { Start-Run 'FULL TEST'         { Invoke-Full } }
            '3' { Start-Run 'PAYLOAD VALIDATION' { Invoke-PayloadOnly } }
            '4' { Start-Run 'ENVIRONMENT ONLY'  { Invoke-EnvOnly } }
            '0' { return }
        }
    }
}

try {
    switch ($Mode) {
        'quick'   { Start-Run 'QUICK TEST'        { Invoke-Quick } }
        'full'    { Start-Run 'FULL TEST'         { Invoke-Full } }
        'payload' { Start-Run 'PAYLOAD VALIDATION' { Invoke-PayloadOnly } }
        'env'     { Start-Run 'ENVIRONMENT ONLY'  { Invoke-EnvOnly } }
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
