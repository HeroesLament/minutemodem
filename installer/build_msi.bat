@echo off
:: ----------------------------------------------------------------------
:: build_msi.bat - Build the MinuteModem MSI installer.
::
:: Prerequisites:
::   - .NET SDK 8.0+ on PATH
::   - wix v7+: dotnet tool install --global wix
::   - WixToolset.UI.wixext: wix extension add -g WixToolset.UI.wixext
::   - EULA accepted: wix eula accept wix7
::   - A built release at _build\prod\rel\minutemodem_station\
::
:: Output: installer\dist\MinuteModem-<version>.msi
::
:: When you bump the umbrella mix.exs version, also bump VERSION below.
:: We could parse mix.exs for the version automatically but the layered
:: quote escaping between cmd.exe and any tool we'd shell out to (findstr,
:: powershell, etc.) is brittle enough that hardcoding here is a more
:: pleasant trade-off.
:: ----------------------------------------------------------------------

setlocal

set "VERSION=0.1.0"

:: Resolve repo root from this script's location.
set "SCRIPT_DIR=%~dp0"
pushd "%SCRIPT_DIR%.." >nul
set "REPO_ROOT=%CD%"
popd >nul

set "RELEASE_DIR=%REPO_ROOT%\_build\prod\rel\minutemodem_station"
set "INSTALLER_DIR=%REPO_ROOT%\installer"
set "DIST_DIR=%INSTALLER_DIR%\dist"
set "WXS_FILE=%INSTALLER_DIR%\MinuteModem.wxs"

if not exist "%RELEASE_DIR%\bin\minutemodem_station.bat" (
    echo [error] Release not found at: %RELEASE_DIR%
    echo Build it first with: mix release minutemodem_station --overwrite
    exit /b 1
)

where wix >nul 2>&1
if errorlevel 1 (
    echo [error] wix is not on PATH. Run the build shell or install with:
    echo     dotnet tool install --global wix
    echo     wix eula accept wix7
    echo     wix extension add -g WixToolset.UI.wixext
    exit /b 1
)

echo.
echo === Building MinuteModem MSI ===
echo Version:     %VERSION%
echo Release dir: %RELEASE_DIR%
echo Output dir:  %DIST_DIR%
echo.

if not exist "%DIST_DIR%" mkdir "%DIST_DIR%"

set "MSI_OUT=%DIST_DIR%\MinuteModem-%VERSION%.msi"

wix build -acceptEula wix7 -ext WixToolset.UI.wixext -d "ReleaseDir=%RELEASE_DIR%" -d "Version=%VERSION%" "%WXS_FILE%" -o "%MSI_OUT%"

if errorlevel 1 (
    echo.
    echo [error] wix build failed
    exit /b 1
)

echo.
echo === MSI built successfully ===
echo %MSI_OUT%

endlocal
