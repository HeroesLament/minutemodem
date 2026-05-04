:: ----------------------------------------------------------------------
:: build_msi.bat - Build the MinuteModem MSI installer.
::
:: Prerequisites:
::   - .NET SDK 8.0+ on PATH (provides `dotnet`)
::   - wix v7+ installed via `dotnet tool install --global wix`
::   - WixToolset.UI.wixext extension added globally:
::         wix extension add -g WixToolset.UI.wixext
::   - OSMF EULA accepted once per machine:
::         wix eula accept wix7
::   - A built release at _build\prod\rel\minutemodem_station\
::         (run `mix release minutemodem_station --overwrite` first)
::
:: Output:
::   installer\dist\MinuteModem-<version>.msi
:: ----------------------------------------------------------------------

setlocal EnableExtensions EnableDelayedExpansion

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
    echo.
    echo [error] Release not found at:
    echo     %RELEASE_DIR%
    echo.
    echo Build it first with:
    echo     cd %REPO_ROOT%
    echo     set MIX_ENV=prod
    echo     set MM_UNLOCKED=true
    echo     mix release minutemodem_station --overwrite
    exit /b 1
)

:: Pull version from the umbrella mix.exs. Looks for `version: "x.y.z"` in
:: the project block. Prefer this over hardcoding so MSI version follows
:: the release.
set "VERSION="
for /f "tokens=2 delims==," %%V in ('findstr /R /C:"version: \"" "%REPO_ROOT%\mix.exs"') do (
    set "RAW=%%V"
    set "RAW=!RAW: =!"
    set "RAW=!RAW:"=!"
    if "!VERSION!"=="" set "VERSION=!RAW!"
)

if "%VERSION%"=="" (
    echo [error] Could not determine version from mix.exs
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

wix build ^
    -acceptEula wix7 ^
    -ext WixToolset.UI.wixext ^
    -d "ReleaseDir=%RELEASE_DIR%" ^
    -d "Version=%VERSION%" ^
    "%WXS_FILE%" ^
    -o "%MSI_OUT%"

if errorlevel 1 (
    echo.
    echo [error] wix build failed
    exit /b 1
)

echo.
echo === MSI built successfully ===
echo %MSI_OUT%
echo.

for %%F in ("%MSI_OUT%") do (
    set /a "MSI_MB=%%~zF / 1048576"
    echo Size: !MSI_MB! MB
)

endlocal
