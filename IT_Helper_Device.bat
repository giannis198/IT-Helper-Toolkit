@echo off
setlocal EnableExtensions
title IT Helper Toolkit - USB / Device Helper
color 0C

rem ============================================================
rem  IT HELPER TOOLKIT - USB / DEVICE HELPER
rem  Single-file: .bat launcher + embedded PowerShell backend
rem  Compatible: Windows 10/11, Server 2019/2022/2025
rem
rem  Usage:
rem    IT_Helper_Device.bat           interactive menu
rem    IT_Helper_Device.bat usb       list USB devices
rem    IT_Helper_Device.bat problems  show problem devices
rem    IT_Helper_Device.bat errors    Device Manager errors
rem    IT_Helper_Device.bat controllers USB controllers
rem    IT_Helper_Device.bat storage   storage devices
rem    IT_Helper_Device.bat pnp       PnP events
rem    IT_Helper_Device.bat refresh   refresh device list
rem    IT_Helper_Device.bat report    export device report
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
set "ITH_PS=%TEMP%\ITH_Dev_%RANDOM%%RANDOM%.ps1"
set "ITH_ERR=%TEMP%\ITH_Dev_err_%RANDOM%.log"
set "ITH_FLAG=%TEMP%\ITH_Dev_done_%RANDOM%.flag"
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
#  IT Helper Toolkit - USB / Device Helper (backend)
# ==================================================================
param(
    [Parameter(Position = 0)]
    [ValidateSet('menu', 'usb', 'problems', 'errors', 'controllers', 'storage', 'pnp', 'refresh', 'report')]
    [string]$Mode = 'menu',

    # Explicit flag path handed over by the launcher. Travels as a
    # command-line argument, so it survives the UAC boundary; falls back
    # to the env var when this backend is run standalone.
    [string]$DoneFlag = $env:ITH_FLAG
)

$ErrorActionPreference = 'Continue'
$ToolVersion = '1.0'
$Stamp   = Get-Date -Format 'yyyyMMdd_HHmmss'
$RunDir  = Join-Path 'C:\ITHelper\Reports' ('Device_{0}_{1}' -f $env:COMPUTERNAME, $Stamp)
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

function Start-Run {
    param([string]$GroupLabel, [scriptblock]$Pipeline)
    $script:Results = New-Object System.Collections.Generic.List[object]
    Log ('=' * 62) DarkCyan
    Log ('  IT HELPER USB / DEVICE HELPER v' + $ToolVersion + '  -  GROUP: ' + $GroupLabel) Cyan
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
    Log '|        USB / DEVICE HELPER RESULT          |' Cyan
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

# ------------------------- device sections ------------------------------

function Section-USBDevices {
    Log '  USB Devices (via Get-PnpDevice):' Gray
    try {
        $devs = Get-PnpDevice -Class 'USB' -ErrorAction Stop -PresentOnly |
            Select-Object Status, Class, FriendlyName, InstanceId, @{n='HardwareID';e={($_.HardwareID -join ', ')}}
        if ($devs) {
            Log (($devs | Format-Table -AutoSize -Wrap | Out-String).TrimEnd())
            Add-Summary 'USB Devices' 'INFO' ("{0} device(s)" -f @($devs).Count)
        } else {
            Log '  No USB devices found.' Yellow
            Add-Summary 'USB Devices' 'INFO' 'None'
        }
    } catch {
        Log '  ERROR: ' + $_.Exception.Message Red
        Add-Summary 'USB Devices' 'FAIL' $_.Exception.Message
    }
}

function Section-ProblemDevices {
    Log '  Problem Devices (ConfigManagerErrorCode != 0):' Gray
    try {
        $problems = Get-PnpDevice -PresentOnly -ErrorAction Stop |
            Where-Object { $_.ConfigManagerErrorCode -and $_.ConfigManagerErrorCode -ne 0 } |
            Select-Object Status, Class, FriendlyName, ConfigManagerErrorCode, InstanceId
        if ($problems) {
            $errMap = @{
                1  = 'Device not configured correctly'
                2  = 'Driver not loaded'
                3  = 'Driver corrupted or system low on resources'
                4  = 'Device not working properly'
                5  = 'Driver needs resource'
                6  = 'Boot configuration conflicts'
                7  = 'Cannot filter'
                8  = 'Driver loader missing'
                9  = 'Device not identified'
                10 = 'Device cannot start'
                11 = 'Device failed'
                12 = 'Cannot find enough free resources'
                13 = 'Cannot verify resources'
                14 = 'Cannot start'
                15 = 'Device has a problem'
                16 = 'Cannot identify all resources'
                17 = 'Device needs reinstall'
                18 = 'Reinstall drivers'
                19 = 'Registry corrupted'
                20 = 'Driver invalid'
                21 = 'System failure'
                22 = 'Device disabled'
                23 = 'System failure'
                24 = 'Device not present'
                25 = 'Invalid API'
                26 = 'No driver'
                27 = 'Driver invalid'
                28 = 'Driver corrupted'
                29 = 'Resources invalid'
                30 = 'Device not responding'
                31 = 'Device not working'
            }
            Log (($problems | Select-Object Status, Class, FriendlyName,
                @{n='ErrorCode';e={$_.ConfigManagerErrorCode}},
                @{n='ErrorDesc';e={$errMap[$_.ConfigManagerErrorCode]}},
                InstanceId | Format-Table -AutoSize -Wrap | Out-String).TrimEnd())
            Add-Summary 'Problem Devices' 'WARN' ("{0} device(s) with errors" -f @($problems).Count)
        } else {
            Log '  No problem devices found.' Green
            Add-Summary 'Problem Devices' 'PASS' 'None'
        }
    } catch {
        Log '  ERROR: ' + $_.Exception.Message Red
        Add-Summary 'Problem Devices' 'FAIL' $_.Exception.Message
    }
}

function Section-DMErrors {
    Log '  Device Manager Errors (Detailed):' Gray
    try {
        $devs = Get-PnpDevice -PresentOnly -ErrorAction Stop |
            Where-Object { $_.ConfigManagerErrorCode -and $_.ConfigManagerErrorCode -ne 0 }
        if ($devs) {
            foreach ($d in $devs) {
                Log ('') 
                Log ('  Device: {0}' -f $d.FriendlyName) Cyan
                Log ('    Class          : {0}' -f $d.Class)
                Log ('    InstanceID     : {0}' -f $d.InstanceId)
                Log ('    Status         : {0}' -f $d.Status)
                Log ('    Error Code     : {0}' -f $d.ConfigManagerErrorCode)
                Log ('    HardwareIDs    : {0}' -f ($d.HardwareID -join ', '))
                # Get driver details if available
                try {
                    $drv = Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_DriverVersion' -ErrorAction SilentlyContinue
                    if ($drv) { Log ('    Driver Version : {0}' -f $drv.Data) }
                } catch { }
            }
            Add-Summary 'DM Errors Detail' 'INFO' ("{0} device(s)" -f @($devs).Count)
        } else {
            Log '  No Device Manager errors.' Green
            Add-Summary 'DM Errors Detail' 'PASS' 'None'
        }
    } catch {
        Log '  ERROR: ' + $_.Exception.Message Red
        Add-Summary 'DM Errors Detail' 'FAIL' $_.Exception.Message
    }
}

function Section-USBControllers {
    Log '  USB Controllers:' Gray
    try {
        $ctrls = Get-PnpDevice -Class 'USB' -ErrorAction Stop |
            Where-Object { $_.FriendlyName -match 'Controller|Hub|Root|Host' } |
            Select-Object Status, FriendlyName, InstanceId, @{n='HardwareID';e={($_.HardwareID -join ', ')}}
        if ($ctrls) {
            Log (($ctrls | Format-Table -AutoSize -Wrap | Out-String).TrimEnd())
            Add-Summary 'USB Controllers' 'INFO' ("{0} controller(s)/hub(s)" -f @($ctrls).Count)
        } else {
            Log '  No USB controllers found.' Yellow
            Add-Summary 'USB Controllers' 'INFO' 'None'
        }
    } catch {
        Log '  ERROR: ' + $_.Exception.Message Red
        Add-Summary 'USB Controllers' 'FAIL' $_.Exception.Message
    }
}

function Section-StorageDevices {
    Log '  Storage Devices:' Gray
    try {
        $disks = Get-PhysicalDisk -ErrorAction Stop |
            Select-Object FriendlyName, MediaType, BusType, @{n='SizeGB';e={[math]::Round($_.Size/1GB)}}, HealthStatus, OperationalStatus, SerialNumber
        if ($disks) {
            Log (($disks | Format-Table -AutoSize | Out-String).TrimEnd())
            foreach ($d in $disks) {
                $s = if ($d.HealthStatus -eq 'Healthy') { 'PASS' } elseif ($d.HealthStatus -eq 'Warning') { 'WARN' } else { 'FAIL' }
                Add-Summary 'Storage Device' $s ("{0}: {1}" -f $d.FriendlyName, $d.HealthStatus)
            }
        } else {
            Log '  No physical disks found.' Yellow
            Add-Summary 'Storage Devices' 'INFO' 'None'
        }
    } catch {
        Log '  ERROR: ' + $_.Exception.Message Red
        Add-Summary 'Storage Devices' 'FAIL' $_.Exception.Message
    }

    Log ''
    Log '  Volumes:' Gray
    try {
        $vols = Get-Volume -ErrorAction Stop | Where-Object { $_.DriveLetter } |
            Select-Object DriveLetter, FileSystemLabel, FileSystem, @{n='SizeGB';e={if($_.Size){[math]::Round($_.Size/1GB,1)}}}, HealthType, OperationalStatus
        Log (($vols | Format-Table -AutoSize | Out-String).TrimEnd())
    } catch { }
}

function Section-PnPEvents {
    Log '  Recent PnP Events (System Log, last 24h):' Gray
    try {
        $events = Get-WinEvent -FilterHashtable @{ LogName='System'; ProviderName='Microsoft-Windows-Kernel-PnP'; StartTime=(Get-Date).AddDays(-1) } -MaxEvents 50 -ErrorAction Stop
        if ($events) {
            Log (($events | Select-Object TimeCreated, Id, LevelDisplayName, @{n='Message';e={($_.Message -split "`r?`n")[0]}} | Format-Table -AutoSize -Wrap | Out-String).TrimEnd())
            Add-Summary 'PnP Events' 'INFO' ("{0} event(s)" -f @($events).Count)
        } else {
            Log '  No PnP events in last 24h.' Gray
            Add-Summary 'PnP Events' 'INFO' 'None'
        }
    } catch {
        Log '  ERROR: ' + $_.Exception.Message Red
        Add-Summary 'PnP Events' 'FAIL' $_.Exception.Message
    }
}

function Section-RefreshDevices {
    if (-not $IsAdmin) {
        Log '  Administrator privileges required for device refresh.' Red
        Add-Summary 'Refresh Devices' 'FAIL' 'Not admin'
        return
    }
    if (-not (Read-Host '  This will scan for hardware changes. Continue? (y/n)') -eq 'y') {
        Add-Summary 'Refresh Devices' 'INFO' 'Skipped by user'
        return
    }
    Log '  Scanning for hardware changes...' Cyan
    $out = & pnputil.exe /scan-devices 2>&1
    $rc = $LASTEXITCODE
    $out | ForEach-Object { Log ('    ' + $_) }
    if ($rc -eq 0) {
        Log '  Hardware scan completed.' Green
        Add-Summary 'Refresh Devices' 'PASS' 'Scan completed'
    } else {
        Log ("  pnputil exited with code {0}" -f $rc) Red
        Add-Summary 'Refresh Devices' 'FAIL' ("Exit code {0}" -f $rc)
    }
}

function Section-DeviceReport {
    Section-USBDevices
    Section-ProblemDevices
    Section-DMErrors
    Section-USBControllers
    Section-StorageDevices
    Section-PnPEvents
}

# ------------------------- menu ----------------------------------

function Show-Menu {
    while ($true) {
        Clear-Host
        Write-Host ''
        Write-Host ('=' * 56) -ForegroundColor Green
        Write-Host ('   IT HELPER TOOLKIT - USB / DEVICE HELPER v' + $ToolVersion) -ForegroundColor Green
        Write-Host ('   {0}  |  Admin: {1}' -f $env:COMPUTERNAME, $IsAdmin) -ForegroundColor Gray
        Write-Host ('=' * 56) -ForegroundColor Green
        Write-Host ''
        Write-Host '  DEVICE INVENTORY'
        Write-Host '  ----------------'
        Write-Host '   1. List USB Devices'
        Write-Host '   2. Show Problem Devices (ConfigManagerErrorCode != 0)'
        Write-Host '   3. Device Manager Errors (Detailed)'
        Write-Host '   4. USB Controllers / Hubs'
        Write-Host '   5. Storage Devices (Disks + Volumes)'
        Write-Host ''
        Write-Host '  EVENTS & ACTIONS'
        Write-Host '  ----------------'
        Write-Host '   6. PnP Events (last 24h)'
        Write-Host '   7. Refresh Device List (Scan for hardware changes)'
        Write-Host ''
        Write-Host '  REPORTS'
        Write-Host '  -------'
        Write-Host '   8. Full Device Report'
        Write-Host '   9. Export Device Report'
        Write-Host ''
        Write-Host '   0. Exit'
        Write-Host ''
        $c = (Read-Host ' Select').Trim()

        switch ($c) {
            '1' { Start-Run 'USB DEVICES'      { Section-USBDevices } }
            '2' { Start-Run 'PROBLEM DEVICES'  { Section-ProblemDevices } }
            '3' { Start-Run 'DM ERRORS'        { Section-DMErrors } }
            '4' { Start-Run 'USB CONTROLLERS'  { Section-USBControllers } }
            '5' { Start-Run 'STORAGE DEVICES'  { Section-StorageDevices } }
            '6' { Start-Run 'PNP EVENTS'       { Section-PnPEvents } }
            '7' { Start-Run 'REFRESH DEVICES'  { Section-RefreshDevices } }
            '8' { Start-Run 'FULL REPORT'      { Section-DeviceReport } }
            '9' { Start-Run 'EXPORT REPORT'    { Section-DeviceReport } }
            '0' { return }
        }
    }
}

# ------------------------- dispatch ------------------------------

try {
    switch ($Mode) {
        'usb'      { Start-Run 'USB DEVICES'      { Section-USBDevices } }
        'problems' { Start-Run 'PROBLEM DEVICES'  { Section-ProblemDevices } }
        'errors'   { Start-Run 'DM ERRORS'        { Section-DMErrors } }
        'controllers'{ Start-Run 'USB CONTROLLERS' { Section-USBControllers } }
        'storage'  { Start-Run 'STORAGE DEVICES'  { Section-StorageDevices } }
        'pnp'      { Start-Run 'PNP EVENTS'       { Section-PnPEvents } }
        'refresh'  { Start-Run 'REFRESH DEVICES'  { Section-RefreshDevices } }
        'report'   { Start-Run 'FULL REPORT'      { Section-DeviceReport } }
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