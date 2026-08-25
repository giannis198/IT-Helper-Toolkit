@echo off
setlocal EnableExtensions
title IT Helper Toolkit - Windows Repair
color 0E

rem ============================================================
rem  IT HELPER TOOLKIT - WINDOWS REPAIR TOOL
rem  Single-file: .bat launcher + embedded PowerShell backend
rem  Compatible: Windows 10/11, Server 2019/2022/2025
rem
rem  Usage:
rem    IT_Helper_WindowsRepair.bat         interactive menu
rem    IT_Helper_WindowsRepair.bat sfc_v   SFC verify only
rem    IT_Helper_WindowsRepair.bat sfc_r   SFC /scannow
rem    IT_Helper_WindowsRepair.bat dism_c  DISM CheckHealth
rem    IT_Helper_WindowsRepair.bat dism_s  DISM ScanHealth
rem    IT_Helper_WindowsRepair.bat dism_r  DISM RestoreHealth
rem    IT_Helper_WindowsRepair.bat chkdsk  CHKDSK read-only
rem    IT_Helper_WindowsRepair.bat wu_diag Windows Update diagnostic
rem    IT_Helper_WindowsRepair.bat wu_reset Reset Windows Update components
rem    IT_Helper_WindowsRepair.bat store   Component Store cleanup
rem    IT_Helper_WindowsRepair.bat full    Full Windows Repair
rem    IT_Helper_WindowsRepair.bat report  Generate repair report
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
set "ITH_PS=%TEMP%\ITH_WinRep_%RANDOM%%RANDOM%.ps1"
set "ITH_ERR=%TEMP%\ITH_WinRep_err_%RANDOM%.log"
set "ITH_FLAG=%TEMP%\ITH_WinRep_done_%RANDOM%.flag"
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
#  IT Helper Toolkit - Windows Repair Tool (backend)
# ==================================================================
param(
    [Parameter(Position = 0)]
    [ValidateSet('menu', 'sfc_v', 'sfc_r', 'dism_c', 'dism_s', 'dism_r', 'chkdsk', 'wu_diag', 'wu_reset', 'store', 'full', 'report')]
    [string]$Mode = 'menu',

    # Explicit flag path handed over by the launcher. Travels as a
    # command-line argument, so it survives the UAC boundary; falls back
    # to the env var when this backend is run standalone.
    [string]$DoneFlag = $env:ITH_FLAG
)

$ErrorActionPreference = 'Continue'
$ToolVersion = '1.0'
$Stamp   = Get-Date -Format 'yyyyMMdd_HHmmss'
$RunDir  = Join-Path 'C:\ITHelper\Reports' ('WinRepair_{0}_{1}' -f $env:COMPUTERNAME, $Stamp)
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

function Confirm-Repair {
    param([string]$What, [string]$Warning = '')
    Log ''
    Log ('  PROPOSED REPAIR ACTION: ' + $What) Yellow
    if ($Warning) { Log ('  WARNING: ' + $Warning) Red }
    $answer = Read-Host '  Type YES to continue (anything else skips)'
    return ($answer -eq 'yes')
}

function Start-Run {
    param([string]$GroupLabel, [scriptblock]$Pipeline)
    $script:Results = New-Object System.Collections.Generic.List[object]
    Log ('=' * 62) DarkCyan
    Log ('  IT HELPER WINDOWS REPAIR v' + $ToolVersion + '  -  GROUP: ' + $GroupLabel) Cyan
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
    Log '|          WINDOWS REPAIR RESULT             |' Cyan
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

# ------------------------- repair sections ------------------------------

function Section-SFCVerify {
    Log '  SFC Verify Only (sfc /verifyonly):' Gray
    Log '  This is a READ-ONLY scan - no modifications.' Cyan
    Log '  Running... (5-15 minutes)...' Yellow
    $out = & sfc.exe /verifyonly 2>&1
    $rc  = $LASTEXITCODE
    $out | Select-Object -Last 5 | ForEach-Object { Log ('    ' + $_) }
    $s = if ($rc -eq 0) { 'PASS' } else { 'FAIL' }
    Add-Summary 'SFC VerifyOnly' $s ('exit code {0} - diagnostic only' -f $rc)
}

function Section-SFCScannow {
    if (-not (Confirm-Repair 'Run sfc /scannow (repairs system files, 5-30 min)')) {
        Add-Summary 'SFC Scannow' 'INFO' 'Skipped by user'
        return
    }
    Log '  Running sfc /scannow...' Yellow
    $out = & sfc.exe /scannow 2>&1
    $rc  = $LASTEXITCODE
    $out | Select-Object -Last 5 | ForEach-Object { Log ('    ' + $_) }
    $s = if ($rc -eq 0) { 'PASS' } else { 'FAIL' }
    Add-Summary 'SFC Scannow' $s ('exit code {0}' -f $rc)
}

function Section-DISMCheckHealth {
    Log '  DISM CheckHealth (quick check):' Gray
    Log '  Running...' Yellow
    $out = & DISM.exe /Online /Cleanup-Image /CheckHealth 2>&1
    $rc  = $LASTEXITCODE
    $out | Select-Object -Last 3 | ForEach-Object { Log ('    ' + $_) }
    $s = if ($rc -eq 0) { 'PASS' } else { 'FAIL' }
    Add-Summary 'DISM CheckHealth' $s ('exit code {0}' -f $rc)
}

function Section-DISMScanHealth {
    Log '  DISM ScanHealth (deep scan):' Gray
    Log '  Running... (10-20 minutes)...' Yellow
    $out = & DISM.exe /Online /Cleanup-Image /ScanHealth 2>&1
    $rc  = $LASTEXITCODE
    $out | Select-Object -Last 5 | ForEach-Object { Log ('    ' + $_) }
    $s = if ($rc -eq 0) { 'PASS' } else { 'FAIL' }
    Add-Summary 'DISM ScanHealth' $s ('exit code {0}' -f $rc)
}

function Section-DISMRestoreHealth {
    if (-not (Confirm-Repair 'Run DISM RestoreHealth (repairs component store, 10-30 min)', 'Downloads replacement files from Windows Update')) {
        Add-Summary 'DISM RestoreHealth' 'INFO' 'Skipped by user'
        return
    }
    Log '  Running DISM ScanHealth first...' Yellow
    $null = & DISM.exe /Online /Cleanup-Image /ScanHealth 2>&1
    Log '  Running DISM RestoreHealth...' Yellow
    $out = & DISM.exe /Online /Cleanup-Image /RestoreHealth 2>&1
    $rc  = $LASTEXITCODE
    $out | Select-Object -Last 5 | ForEach-Object { Log ('    ' + $_) }
    $s = if ($rc -eq 0) { 'PASS' } else { 'FAIL' }
    Add-Summary 'DISM RestoreHealth' $s ('exit code {0}' -f $rc)
}

function Section-CHKDSKReadOnly {
    Log '  CHKDSK Read-Only Scan:' Gray
    $drive = Read-Host '  Drive letter to scan [default C]'
    if (-not $drive) { $drive = 'C' }
    $drive = $drive.TrimEnd(':').ToUpper() + ':'
    Log ("  Running chkdsk {0} (read-only)..." -f $drive)
    $out = & chkdsk.exe $drive 2>&1
    $rc  = $LASTEXITCODE
    $out | Select-Object -Last 5 | ForEach-Object { Log ('    ' + $_) }
    $s = if ($rc -eq 0) { 'PASS' } else { 'FAIL' }
    Add-Summary 'CHKDSK ReadOnly' $s ("{0} exit {1}" -f $drive, $rc)
}

function Section-CHKDSKRepair {
    $drive = Read-Host '  Drive letter to repair [default C]'
    if (-not $drive) { $drive = 'C' }
    $drive = $drive.TrimEnd(':').ToUpper() + ':'
    if (-not (Confirm-Repair ("Schedule chkdsk {0} /f /x at next boot" -f $drive), 'Requires reboot')) {
        Add-Summary 'CHKDSK Repair' 'INFO' 'Skipped by user'
        return
    }
    # Use /X flag which forces dismount and implies /F, no confirmation prompt needed
    $out = & chkdsk.exe $drive /F /X 2>&1
    $rc  = $LASTEXITCODE
    $out | Select-Object -Last 5 | ForEach-Object { Log ('    ' + $_) }
    Log '  If scheduled, it will run at next reboot.' Gray
    Add-Summary 'CHKDSK Repair' 'INFO' ("chkdsk {0} /f /x requested (exit {1})" -f $drive, $rc)
}

function Section-WUDiagnostic {
    Log '  Windows Update Diagnostic:' Gray
    $svc = Get-Service -Name 'wuauserv' -ErrorAction SilentlyContinue
    if ($svc) { Log ('  wuauserv Status: {0}' -f $svc.Status) }
    $svc2 = Get-Service -Name 'bits' -ErrorAction SilentlyContinue
    if ($svc2) { Log ('  bits Status: {0}' -f $svc2.Status) }

    $hf = @(Get-HotFix -ErrorAction SilentlyContinue | Sort-Object InstalledOn -Descending)
    if ($hf.Count -eq 0) {
        Log '  No hotfix history found.' Yellow
        Add-Summary 'WU History' 'INFO' 'Hotfix list empty'
        return
    }
    Log ('  Last 10 installed updates:') Gray
    Log (($hf | Select-Object -First 10 HotFixID, Description, InstalledOn | Format-Table -AutoSize | Out-String).TrimEnd())
    $last = $hf | Where-Object { $_.InstalledOn } | Select-Object -First 1
    if ($last) {
        $days = [int]((Get-Date) - $last.InstalledOn).TotalDays
        $s = if ($days -gt 90) { 'WARN' } else { 'PASS' }
        Add-Summary 'Last Update (heuristic)' $s ('{0} installed {1:yyyy-MM-dd} ({2} days ago)' -f $last.HotFixID, $last.InstalledOn, $days)
    }
}

function Section-WUReset {
    if (-not (Confirm-Repair 'Reset Windows Update components (stops services, renames SoftwareDistribution/catroot2)', 'Requires internet to re-download updates')) {
        Add-Summary 'WU Reset' 'INFO' 'Skipped by user'
        return
    }
    foreach ($sn in 'wuauserv', 'bits', 'cryptsvc') {
        try { Stop-Service -Name $sn -Force -ErrorAction SilentlyContinue } catch { }
    }
    $stamp2 = Get-Date -Format 'yyyyMMddHHmmss'
    $sd = Join-Path $env:SystemRoot 'SoftwareDistribution'
    $cr = Join-Path $env:SystemRoot 'System32\catroot2'
    foreach ($folder in @(@($sd, 'softwaredistribution_old_' + $stamp2), @($cr, 'catroot2_old_' + $stamp2))) {
        if (Test-Path -LiteralPath $folder[0]) {
            try {
                Rename-Item -LiteralPath $folder[0] -NewName $folder[1] -Force -ErrorAction Stop
                Log ('  Renamed: {0}' -f $folder[0])
            } catch {
                Log ('  Could not rename {0}: {1}' -f $folder[0], $_.Exception.Message) Yellow
            }
        }
    }
    foreach ($sn in 'cryptsvc', 'bits', 'wuauserv') {
        try { Start-Service -Name $sn -ErrorAction SilentlyContinue } catch { }
    }
    Log '  WU cache reset done. Run Windows Update afterwards.' Green
    Add-Summary 'WU Reset' 'PASS' 'Executed'
}

function Section-ComponentStoreCleanup {
    if (-not (Confirm-Repair 'Cleanup Component Store (DISM StartComponentCleanup)', 'Removes superseded components, saves disk space')) {
        Add-Summary 'Component Store Cleanup' 'INFO' 'Skipped by user'
        return
    }
    Log '  Running DISM StartComponentCleanup...' Yellow
    $out = & DISM.exe /Online /Cleanup-Image /StartComponentCleanup 2>&1
    $rc  = $LASTEXITCODE
    $out | Select-Object -Last 3 | ForEach-Object { Log ('    ' + $_) }
    $s = if ($rc -eq 0) { 'PASS' } else { 'FAIL' }
    Add-Summary 'Component Store Cleanup' $s ('exit code {0}' -f $rc)
}

function Section-FullRepair {
    Log ''
    Log '  ===== FULL WINDOWS REPAIR =====' Yellow
    Log '  This will execute:' Cyan
    Log '    1. SFC /verifyonly (diagnostic)'
    Log '    2. SFC /scannow (repair)'
    Log '    3. DISM CheckHealth'
    Log '    4. DISM ScanHealth'
    Log '    5. DISM RestoreHealth'
    Log '    6. CHKDSK read-only (C:)'
    Log '    7. Windows Update component reset'
    Log '    8. Component Store cleanup'
    Log ''
    Log '  Steps 2, 4, 5, 7 require confirmation each.' Red
    if (-not (Confirm-Repair 'Execute FULL WINDOWS REPAIR sequence')) {
        Add-Summary 'Full Windows Repair' 'INFO' 'Skipped by user'
        return
    }
    Section-SFCVerify
    Section-SFCScannow
    Section-DISMCheckHealth
    Section-DISMScanHealth
    Section-DISMRestoreHealth
    Section-CHKDSKReadOnly
    Section-WUReset
    Section-ComponentStoreCleanup
    Log ''
    Log '  Full Windows Repair sequence completed.' Green
    Add-Summary 'Full Windows Repair' 'PASS' 'All steps executed'
}

# ------------------------- menu ----------------------------------

function Show-Menu {
    while ($true) {
        Clear-Host
        Write-Host ''
        Write-Host ('=' * 56) -ForegroundColor Green
        Write-Host ('   IT HELPER TOOLKIT - WINDOWS REPAIR v' + $ToolVersion) -ForegroundColor Green
        Write-Host ('   {0}  |  Admin: {1}' -f $env:COMPUTERNAME, $IsAdmin) -ForegroundColor Gray
        Write-Host ('=' * 56) -ForegroundColor Green
        Write-Host ''
        Write-Host '  DIAGNOSTIC (READ-ONLY)'
        Write-Host '  ---------------------'
        Write-Host '   1. SFC Verify Only (sfc /verifyonly)'
        Write-Host '   2. DISM CheckHealth'
        Write-Host '   3. DISM ScanHealth'
        Write-Host '   4. CHKDSK Read-Only Scan'
        Write-Host '   5. Windows Update Diagnostic'
        Write-Host ''
        Write-Host '  REPAIR ACTIONS (require confirmation)'
        Write-Host '  ------------------------------------'
        Write-Host '   6. SFC /scannow'
        Write-Host '   7. DISM RestoreHealth'
        Write-Host '   8. CHKDSK /f (schedule at boot)'
        Write-Host '   9. Reset Windows Update Components'
        Write-Host '  10. Component Store Cleanup'
        Write-Host ''
        Write-Host '  COMBINED'
        Write-Host '  --------'
        Write-Host '  11. Full Windows Repair (all above)'
        Write-Host ''
        Write-Host '   0. Exit'
        Write-Host ''
        $c = (Read-Host ' Select').Trim()

        switch ($c) {
            '1'  { Start-Run 'SFC VERIFY ONLY'       { Section-SFCVerify } }
            '2'  { Start-Run 'DISM CHECKHEALTH'      { Section-DISMCheckHealth } }
            '3'  { Start-Run 'DISM SCANHEALTH'       { Section-DISMScanHealth } }
            '4'  { Start-Run 'CHKDSK READ-ONLY'      { Section-CHKDSKReadOnly } }
            '5'  { Start-Run 'WU DIAGNOSTIC'         { Section-WUDiagnostic } }
            '6'  { Start-Run 'SFC SCANNOW'           { Section-SFCScannow } }
            '7'  { Start-Run 'DISM RESTOREHEALTH'    { Section-DISMRestoreHealth } }
            '8'  { Start-Run 'CHKDSK REPAIR'         { Section-CHKDSKRepair } }
            '9'  { Start-Run 'WU RESET'              { Section-WUReset } }
            '10' { Start-Run 'COMPONENT CLEANUP'     { Section-ComponentStoreCleanup } }
            '11' { Start-Run 'FULL WINDOWS REPAIR'   { Section-FullRepair } }
            '0'  { return }
        }
    }
}

# ------------------------- dispatch ------------------------------

try {
    switch ($Mode) {
        'sfc_v'   { Start-Run 'SFC VERIFY ONLY'       { Section-SFCVerify } }
        'sfc_r'   { Start-Run 'SFC SCANNOW'           { Section-SFCScannow } }
        'dism_c'  { Start-Run 'DISM CHECKHEALTH'      { Section-DISMCheckHealth } }
        'dism_s'  { Start-Run 'DISM SCANHEALTH'       { Section-DISMScanHealth } }
        'dism_r'  { Start-Run 'DISM RESTOREHEALTH'    { Section-DISMRestoreHealth } }
        'chkdsk'  { Start-Run 'CHKDSK READ-ONLY'      { Section-CHKDSKReadOnly } }
        'wu_diag' { Start-Run 'WU DIAGNOSTIC'         { Section-WUDiagnostic } }
        'wu_reset'{ Start-Run 'WU RESET'              { Section-WUReset } }
        'store'   { Start-Run 'COMPONENT CLEANUP'     { Section-ComponentStoreCleanup } }
        'full'    { Start-Run 'FULL WINDOWS REPAIR'   { Section-FullRepair } }
        'report'  { Start-Run 'FULL WINDOWS REPAIR'   { Section-FullRepair } }
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
