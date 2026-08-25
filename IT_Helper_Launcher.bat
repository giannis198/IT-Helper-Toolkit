@echo off
setlocal EnableExtensions
title IT Helper Toolkit - Main Launcher
color 0A

rem ============================================================
rem  IT HELPER TOOLKIT - MAIN LAUNCHER
rem  Unified entry point for all IT Helper tools
rem  Compatible: Windows 10/11, Server 2019/2022/2025
rem ============================================================

rem Get the directory where this launcher is located
set "ROOT=%~dp0"

:MAIN_MENU
cls
echo.
echo ============================================================
echo   IT HELPER TOOLKIT v1.0
echo   Modular IT Support Utilities
echo ============================================================
echo.
echo  DIAGNOSTICS ^& SUPPORT
echo  --------------------
echo   1. PC Quick Support        (system snapshot in 30-60 sec)
echo   2. Network Fixer           (IP/DNS/Winsock/TCP reset + diagnostics)
echo   3. Network Scanner         (LAN discovery, ping sweep, ports, MAC)
echo.
echo  REPAIR ^& RECOVERY
echo  -----------------
echo   4. Windows Repair Tool     (SFC/DISM/CHKDSK/WU repair)
echo   5. RDP Troubleshooter      (service/firewall/port/NLA/config)
echo   6. Printer Fixer           (spooler/queues/drivers/TCP tests)
echo.
echo  HARDWARE ^& DEVICES
echo  ------------------
echo   7. USB / Device Helper     (USB, PnP errors, drivers, storage)
echo.
echo  BACKUP ^& SERVER
echo  ---------------
echo   8. Backup Helper           (Robocopy backup/verify/compare)
echo   9. Server Health Check     (AD/DNS/DHCP/IIS/SQL + core)
echo.
echo   0. Exit
echo.
echo ============================================================
set /p "CHOICE=Select tool [0-9]: "

if "%CHOICE%"=="1" goto TOOL1
if "%CHOICE%"=="2" goto TOOL2
if "%CHOICE%"=="3" goto TOOL3
if "%CHOICE%"=="4" goto TOOL4
if "%CHOICE%"=="5" goto TOOL5
if "%CHOICE%"=="6" goto TOOL6
if "%CHOICE%"=="7" goto TOOL7
if "%CHOICE%"=="8" goto TOOL8
if "%CHOICE%"=="9" goto TOOL9
if "%CHOICE%"=="0" goto EXIT
goto MAIN_MENU

:TOOL1
cls
echo Launching PC Quick Support...
if exist "%ROOT%IT_Helper_PC_Support.bat" (
    start /wait "" "%ROOT%IT_Helper_PC_Support.bat"
) else (
    echo ERROR: IT_Helper_PC_Support.bat not found in %ROOT%.
    pause
)
goto MAIN_MENU

:TOOL2
cls
echo Launching Network Fixer...
if exist "%ROOT%IT_Helper_Network.bat" (
    start /wait "" "%ROOT%IT_Helper_Network.bat"
) else (
    echo ERROR: IT_Helper_Network.bat not found in %ROOT%.
    pause
)
goto MAIN_MENU

:TOOL3
cls
echo Launching Network Scanner...
if exist "%ROOT%IT_Helper_NetworkScanner.bat" (
    start /wait "" "%ROOT%IT_Helper_NetworkScanner.bat"
) else (
    echo ERROR: IT_Helper_NetworkScanner.bat not found in %ROOT%.
    pause
)
goto MAIN_MENU

:TOOL4
cls
echo Launching Windows Repair Tool...
if exist "%ROOT%IT_Helper_WindowsRepair.bat" (
    start /wait "" "%ROOT%IT_Helper_WindowsRepair.bat"
) else (
    echo ERROR: IT_Helper_WindowsRepair.bat not found in %ROOT%.
    pause
)
goto MAIN_MENU

:TOOL5
cls
echo Launching RDP Troubleshooter...
if exist "%ROOT%IT_Helper_RDP.bat" (
    start /wait "" "%ROOT%IT_Helper_RDP.bat"
) else (
    echo ERROR: IT_Helper_RDP.bat not found in %ROOT%.
    pause
)
goto MAIN_MENU

:TOOL6
cls
echo Launching Printer Fixer...
if exist "%ROOT%IT_Helper_Printer.bat" (
    start /wait "" "%ROOT%IT_Helper_Printer.bat"
) else (
    echo ERROR: IT_Helper_Printer.bat not found in %ROOT%.
    pause
)
goto MAIN_MENU

:TOOL7
cls
echo Launching USB / Device Helper...
if exist "%ROOT%IT_Helper_Device.bat" (
    start /wait "" "%ROOT%IT_Helper_Device.bat"
) else (
    echo ERROR: IT_Helper_Device.bat not found in %ROOT%.
    pause
)
goto MAIN_MENU

:TOOL8
cls
echo Launching Backup Helper...
if exist "%ROOT%IT_Helper_Backup.bat" (
    start /wait "" "%ROOT%IT_Helper_Backup.bat"
) else (
    echo ERROR: IT_Helper_Backup.bat not found in %ROOT%.
    pause
)
goto MAIN_MENU

:TOOL9
cls
echo Launching Server Health Check...
if exist "%ROOT%IT_Helper_Server.bat" (
    start /wait "" "%ROOT%IT_Helper_Server.bat"
) else (
    echo ERROR: IT_Helper_Server.bat not found in %ROOT%.
    pause
)
goto MAIN_MENU

:EXIT
echo.
echo Goodbye!
timeout /t 1 /nobreak >nul
exit /b 0
