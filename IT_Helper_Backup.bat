@echo off
setlocal EnableExtensions
title IT Helper Toolkit - Backup Helper
color 0B

rem ============================================================
rem  IT HELPER TOOLKIT - BACKUP HELPER
rem  Single-file: .bat launcher + embedded PowerShell backend
rem  Compatible: Windows 10/11, Server 2019/2022/2025
rem
rem  Usage:
rem    IT_Helper_Backup.bat            interactive menu
rem    IT_Helper_Backup.bat backup     backup folder
rem    IT_Helper_Backup.bat mirror     mirror folder
rem    IT_Helper_Backup.bat profile    backup user profile
rem    IT_Helper_Backup.bat docs       backup documents
rem    IT_Helper_Backup.bat desktop    backup desktop
rem    IT_Helper_Backup.bat verify     verify backup
rem    IT_Helper_Backup.bat compare    compare source/dest
rem    IT_Helper_Backup.bat log        generate backup log
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
set "ITH_PS=%TEMP%\ITH_Backup_%RANDOM%%RANDOM%.ps1"
set "ITH_ERR=%TEMP%\ITH_Backup_err_%RANDOM%.log"
set "ITH_FLAG=%TEMP%\ITH_Backup_done_%RANDOM%.flag"
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
#  IT Helper Toolkit - Backup Helper (backend)
# ==================================================================
param(
    [Parameter(Position = 0)]
    [ValidateSet('menu', 'backup', 'mirror', 'profile', 'docs', 'desktop', 'verify', 'compare', 'log')]
    [string]$Mode = 'menu',

    # Explicit flag path handed over by the launcher. Travels as a
    # command-line argument, so it survives the UAC boundary; falls back
    # to the env var when this backend is run standalone.
    [string]$DoneFlag = $env:ITH_FLAG
)

$ErrorActionPreference = 'Continue'
$ToolVersion = '1.0'
$Stamp   = Get-Date -Format 'yyyyMMdd_HHmmss'
$RunDir  = Join-Path 'C:\ITHelper\Reports' ('Backup_{0}_{1}' -f $env:COMPUTERNAME, $Stamp)
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

function Get-RobocopyPath {
    $rc = $env:SystemRoot + '\System32\robocopy.exe'
    if (Test-Path $rc) { return $rc }
    return 'robocopy.exe'
}

function Run-Robocopy {
    param(
        [string]$Source,
        [string]$Dest,
        [string[]]$Options,
        [string]$Label
    )
    $rcPath = Get-RobocopyPath
    $cmd = @($rcPath, $Source, $Dest) + $Options
    Log ("  Command: {0}" -f ($cmd -join ' ')) Gray
    $output = & $cmd 2>&1
    $exitCode = $LASTEXITCODE
    $output | ForEach-Object { Log ('    ' + $_) }
    return @{ ExitCode = $exitCode; Output = $output }
}

function Parse-RobocopyExitCode {
    param([int]$Code)
    # Robocopy exit codes (bitmask):
    # 0  = No files copied, no failures (source == dest)
    # 1  = Files copied successfully
    # 2  = Extra files in destination (mirror would delete)
    # 4  = Some files mismatched
    # 8  = Some files could not be copied (FAIL)
    # 16 = Fatal error
    # Check FAIL bits FIRST (highest priority)
    if ($Code -band 16) { return @('ERROR', 'Fatal error', 'FAIL') }
    if ($Code -band 8)  { return @('FAIL', 'Some files failed to copy', 'FAIL') }
    if ($Code -band 4)  { return @('MISMATCH', 'Some files mismatched', 'WARN') }
    if ($Code -band 2)  { return @('EXTRA', 'Extra files in destination', 'WARN') }
    if ($Code -band 1)  { return @('COPY', 'Files copied successfully', 'PASS') }
    if ($Code -eq 0)    { return @('MATCH', 'No changes needed', 'INFO') }
    return @('UNKNOWN', "Exit code $Code", 'INFO')
}

function Start-Run {
    param([string]$GroupLabel, [scriptblock]$Pipeline)
    $script:Results = New-Object System.Collections.Generic.List[object]
    Log ('=' * 62) DarkCyan
    Log ('  IT HELPER BACKUP HELPER v' + $ToolVersion + '  -  GROUP: ' + $GroupLabel) Cyan
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
    Log '|           BACKUP HELPER RESULT             |' Cyan
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

# ------------------------- backup sections ------------------------------

function Get-SourcePath {
    param([string]$Prompt, [string]$Default)
    $path = Read-Host ("  {0} [default: {1}]" -f $Prompt, $Default)
    if (-not $path) { $path = $Default }
    $path = $path.Trim('"')
    if (-not (Test-Path -LiteralPath $path)) {
        Log ("  Source path does not exist: {0}" -f $path) Red
        return $null
    }
    return $path
}

function Get-DestPath {
    param([string]$Prompt)
    $path = Read-Host $Prompt
    if (-not $path) { return $null }
    $path = $path.Trim('"')
    # Handle root drive paths (e.g., D:\)
    $parent = Split-Path -Parent $path
    if (-not $parent) {
        # Path is a root drive (e.g., D:\) - use the path itself as parent
        $parent = $path
    }
    if (-not (Test-Path -LiteralPath $parent)) {
        try { New-Item -ItemType Directory -Path $parent -Force | Out-Null } catch { }
    }
    return $path
}

function Section-BackupFolder {
    param(
        [string]$Prompt = 'Source folder',
        [string]$Default = "$env:USERPROFILE\Documents"
    )
    Log '  Backup Folder (Robocopy /E /COPY:DAT /R:3 /W:5):' Gray
    $src = Get-SourcePath $Prompt $Default
    if (-not $src) { Add-Summary 'Backup Folder' 'FAIL' 'Invalid source'; return }
    $dest = Get-DestPath 'Destination folder'
    if (-not $dest) { Add-Summary 'Backup Folder' 'FAIL' 'Invalid destination'; return }

    $opts = @('/E', '/COPY:DAT', '/R:3', '/W:5', '/V', '/NP', '/LOG+:' + (Join-Path $RunDir 'robocopy.log'))
    $result = Run-Robocopy -Source $src -Dest $dest -Options $opts -Label 'Backup'
    $parsed = Parse-RobocopyExitCode $result.ExitCode
    Log ("  Result: {0} - {1}" -f $parsed[0], $parsed[1]) $(if ($parsed[2] -eq 'FAIL') { 'Red' } elseif ($parsed[2] -eq 'WARN') { 'Yellow' } else { 'Green' })
    Add-Summary 'Backup Folder' $parsed[2] ("{0} -> {1} : {2}" -f $src, $dest, $parsed[1])
}

function Section-MirrorFolder {
    Log '  Mirror Folder (Robocopy /MIR /COPY:DAT /R:3 /W:5):' Gray
    Log '  WARNING: /MIR will DELETE files in destination that do not exist in source!' Red
    $src = Get-SourcePath 'Source folder' "$env:USERPROFILE\Documents"
    if (-not $src) { Add-Summary 'Mirror Folder' 'FAIL' 'Invalid source'; return }
    $dest = Get-DestPath 'Destination folder'
    if (-not $dest) { Add-Summary 'Mirror Folder' 'FAIL' 'Invalid destination'; return }

    if (-not (Read-Host '  Type YES to proceed with MIRROR (deletes extras)') -eq 'YES') {
        Add-Summary 'Mirror Folder' 'INFO' 'Skipped by user'
        return
    }

    $opts = @('/MIR', '/COPY:DAT', '/R:3', '/W:5', '/V', '/NP', '/LOG+:' + (Join-Path $RunDir 'robocopy.log'))
    $result = Run-Robocopy -Source $src -Dest $dest -Options $opts -Label 'Mirror'
    $parsed = Parse-RobocopyExitCode $result.ExitCode
    Log ("  Result: {0} - {1}" -f $parsed[0], $parsed[1]) $(if ($parsed[2] -eq 'FAIL') { 'Red' } elseif ($parsed[2] -eq 'WARN') { 'Yellow' } else { 'Green' })
    Add-Summary 'Mirror Folder' $parsed[2] ("{0} -> {1} : {2}" -f $src, $dest, $parsed[1])
}

function Section-BackupProfile {
    Log '  Backup User Profile (Documents, Desktop, Pictures, Downloads, Favorites):' Gray
    $src = $env:USERPROFILE
    $dest = Get-DestPath 'Destination root folder (will create username subfolder)'
    if (-not $dest) { Add-Summary 'Backup Profile' 'FAIL' 'Invalid destination'; return }
    $dest = Join-Path $dest ($env:USERNAME + '_Profile_' + (Get-Date -Format 'yyyyMMdd'))

    $folders = @('Documents', 'Desktop', 'Pictures', 'Downloads', 'Favorites', 'Music', 'Videos')
    $opts = @('/E', '/COPY:DAT', '/R:3', '/W:5', '/V', '/NP', '/LOG+:' + (Join-Path $RunDir 'robocopy.log'))
    $totalCopied = 0; $totalFailed = 0
    foreach ($f in $folders) {
        $srcPath = Join-Path $src $f
        $destPath = Join-Path $dest $f
        if (Test-Path -LiteralPath $srcPath) {
            Log ("  Backing up {0}..." -f $f) Cyan
            $result = Run-Robocopy -Source $srcPath -Dest $destPath -Options $opts -Label "Profile-$f"
            $parsed = Parse-RobocopyExitCode $result.ExitCode
            if ($parsed[2] -eq 'PASS') { $totalCopied++ } elseif ($parsed[2] -eq 'FAIL') { $totalFailed++ }
        }
    }
    $status = if ($totalFailed -gt 0) { 'FAIL' } elseif ($totalCopied -gt 0) { 'PASS' } else { 'INFO' }
    Add-Summary 'Backup Profile' $status ("{0} folders copied, {1} failed" -f $totalCopied, $totalFailed)
}

function Section-BackupDocs {
    Section-BackupFolder -Prompt 'Source folder' -Default "$env:USERPROFILE\Documents"
}

function Section-BackupDesktop {
    Section-BackupFolder -Prompt 'Source folder' -Default "$env:USERPROFILE\Desktop"
}

function Section-VerifyBackup {
    Log '  Verify Backup (Robocopy /L /E /COPY:DAT):' Gray
    $src = Get-SourcePath 'Source folder' "$env:USERPROFILE\Documents"
    if (-not $src) { Add-Summary 'Verify Backup' 'FAIL' 'Invalid source'; return }
    $dest = Get-DestPath 'Destination folder'
    if (-not $dest) { Add-Summary 'Verify Backup' 'FAIL' 'Invalid destination'; return }

    $opts = @('/L', '/E', '/COPY:DAT', '/V', '/NP', '/LOG+:' + (Join-Path $RunDir 'robocopy_verify.log'))
    $result = Run-Robocopy -Source $src -Dest $dest -Options $opts -Label 'Verify'
    $parsed = Parse-RobocopyExitCode $result.ExitCode
    Log ("  Result: {0} - {1}" -f $parsed[0], $parsed[1]) $(if ($parsed[2] -eq 'FAIL') { 'Red' } elseif ($parsed[2] -eq 'WARN') { 'Yellow' } else { 'Green' })
    Add-Summary 'Verify Backup' $parsed[2] ("{0} vs {1} : {2}" -f $src, $dest, $parsed[1])
}

function Section-CompareBackup {
    Log '  Compare Source vs Destination (Robocopy /L /MIR /COPY:DAT):' Gray
    $src = Get-SourcePath 'Source folder' "$env:USERPROFILE\Documents"
    if (-not $src) { Add-Summary 'Compare Backup' 'FAIL' 'Invalid source'; return }
    $dest = Get-DestPath 'Destination folder'
    if (-not $dest) { Add-Summary 'Compare Backup' 'FAIL' 'Invalid destination'; return }

    $opts = @('/L', '/MIR', '/COPY:DAT', '/V', '/NP', '/LOG+:' + (Join-Path $RunDir 'robocopy_compare.log'))
    $result = Run-Robocopy -Source $src -Dest $dest -Options $opts -Label 'Compare'
    $parsed = Parse-RobocopyExitCode $result.ExitCode
    Log ("  Result: {0} - {1}" -f $parsed[0], $parsed[1]) $(if ($parsed[2] -eq 'FAIL') { 'Red' } elseif ($parsed[2] -eq 'WARN') { 'Yellow' } else { 'Green' })
    Add-Summary 'Compare Backup' $parsed[2] ("{0} vs {1} : {2}" -f $src, $dest, $parsed[1])
}

function Section-BackupLog {
    Log '  Recent Backup Logs:' Gray
    $logDir = 'C:\ITHelper\Reports'
    $logs = Get-ChildItem -Path $logDir -Filter 'robocopy*.log' -Recurse -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 10
    if ($logs) {
        Log (($logs | Select-Object Name, @{n='Modified';e={$_.LastWriteTime}}, @{n='SizeKB';e={[math]::Round($_.Length/1KB,1)}}, DirectoryName | Format-Table -AutoSize | Out-String).TrimEnd())
    } else {
        Log '  No robocopy logs found in C:\ITHelper\Reports' Yellow
    }
    Add-Summary 'Backup Logs' 'INFO' ('{0} log(s) found' -f @($logs).Count)
}

# ------------------------- menu ----------------------------------

function Show-Menu {
    while ($true) {
        Clear-Host
        Write-Host ''
        Write-Host ('=' * 56) -ForegroundColor Green
        Write-Host ('   IT HELPER TOOLKIT - BACKUP HELPER v' + $ToolVersion) -ForegroundColor Green
        Write-Host ('   {0}  |  Admin: {1}' -f $env:COMPUTERNAME, $IsAdmin) -ForegroundColor Gray
        Write-Host ('=' * 56) -ForegroundColor Green
        Write-Host ''
        Write-Host '  BACKUP OPERATIONS'
        Write-Host '  -----------------'
        Write-Host '   1. Backup Folder (incremental)'
        Write-Host '   2. Mirror Folder (exact copy, deletes extras)'
        Write-Host '   3. Backup User Profile (Documents, Desktop, Pictures...)'
        Write-Host '   4. Backup Documents'
        Write-Host '   5. Backup Desktop'
        Write-Host ''
        Write-Host '  VERIFICATION'
        Write-Host '  ------------'
        Write-Host '   6. Verify Backup (what would copy)'
        Write-Host '   7. Compare Source vs Destination'
        Write-Host ''
        Write-Host '  LOGS'
        Write-Host '  ----'
        Write-Host '   8. View Recent Backup Logs'
        Write-Host ''
        Write-Host '   0. Exit'
        Write-Host ''
        $c = (Read-Host ' Select').Trim()

        switch ($c) {
            '1' { Start-Run 'BACKUP FOLDER'    { Section-BackupFolder } }
            '2' { Start-Run 'MIRROR FOLDER'    { Section-MirrorFolder } }
            '3' { Start-Run 'BACKUP PROFILE'   { Section-BackupProfile } }
            '4' { Start-Run 'BACKUP DOCS'      { Section-BackupDocs } }
            '5' { Start-Run 'BACKUP DESKTOP'   { Section-BackupDesktop } }
            '6' { Start-Run 'VERIFY BACKUP'    { Section-VerifyBackup } }
            '7' { Start-Run 'COMPARE BACKUP'   { Section-CompareBackup } }
            '8' { Start-Run 'BACKUP LOGS'      { Section-BackupLog } }
            '0' { return }
        }
    }
}

# ------------------------- dispatch ------------------------------

try {
    switch ($Mode) {
        'backup' { Start-Run 'BACKUP FOLDER'    { Section-BackupFolder } }
        'mirror' { Start-Run 'MIRROR FOLDER'    { Section-MirrorFolder } }
        'profile'{ Start-Run 'BACKUP PROFILE'   { Section-BackupProfile } }
        'docs'   { Start-Run 'BACKUP DOCS'      { Section-BackupDocs } }
        'desktop'{ Start-Run 'BACKUP DESKTOP'   { Section-BackupDesktop } }
        'verify' { Start-Run 'VERIFY BACKUP'    { Section-VerifyBackup } }
        'compare'{ Start-Run 'COMPARE BACKUP'   { Section-CompareBackup } }
        'log'    { Start-Run 'BACKUP LOGS'      { Section-BackupLog } }
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
