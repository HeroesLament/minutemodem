# MinuteModem Installer

WiX Toolset v7 source for building the MinuteModem MSI on Windows.

## Prerequisites (one-time setup)

1. **.NET SDK 8.0 or later**

   https://dotnet.microsoft.com/download

   Verify with `dotnet --version`.

2. **WiX Toolset v7+** as a .NET global tool

   ```cmd
   dotnet tool install --global wix
   wix --version
   ```

3. **WiX UI extension** (provides the install-wizard pages)

   ```cmd
   wix extension add -g WixToolset.UI.wixext
   ```

4. **Accept the WiX EULA once**

   WiX v7 enforces the Open Source Maintenance Fee EULA. The fee only
   applies to organizations generating >$10K/year in revenue, but the
   acknowledgement is required regardless:

   ```cmd
   wix eula accept wix7
   ```

5. **`wix.exe` and `dotnet.exe` on PATH**

   The build shell at `C:\build\minutemodem-build-shell.cmd` already
   adds `C:\Program Files\dotnet` and `%USERPROFILE%\.dotnet\tools`.

## Building

From the repo root in a build shell:

```cmd
:: 1. Build a stripped, Mesa-bundled prod release
set MIX_ENV=prod
set MM_UNLOCKED=true
mix release minutemodem_station --overwrite

:: 2. Build the MSI
installer\build_msi.bat
```

Output lands at `installer\dist\MinuteModem-<version>.msi`.

## What the MSI does

- Per-machine install (admin elevation required) to
  `C:\Program Files\Northwest Tech\MinuteModem\`
- Two Start Menu shortcuts under `Northwest Tech\`:
  - **MinuteModem** — `start` mode, GUI only, no console (end-user)
  - **MinuteModem (Console)** — `start_iex` mode, console with iex
    prompt for diagnostics
- Registered with Programs & Features as "MinuteModem" by manufacturer
  "Northwest Tech"
- Major-upgrade aware: installing a higher version automatically
  uninstalls the lower one
- User data at `%LOCALAPPDATA%\MinuteModem\` is **not touched** by
  install/uninstall — license keys, the SQLite DB, and any user prefs
  survive across upgrades and uninstalls

## Files

- `MinuteModem.wxs` — WiX source. Hardcoded UpgradeCode (don't change
  it) and shortcut component GUID. Both must remain stable across
  versions for upgrades to work cleanly.
- `build_msi.bat` — wrapper around `wix build` with version detection
  and path resolution.
- `dist/` — output directory for built MSIs (gitignored).

## Testing the MSI

The MSI can be installed silently for testing:

```cmd
msiexec /i installer\dist\MinuteModem-0.1.0.msi /quiet /l*v install.log
```

Or interactively:

```cmd
installer\dist\MinuteModem-0.1.0.msi
```

To uninstall:

```cmd
msiexec /x installer\dist\MinuteModem-0.1.0.msi /quiet
```

## Future improvements

- **Code signing.** Real shipping MSIs are signed with an Authenticode
  cert to avoid SmartScreen warnings on download. Add a `signtool sign`
  step after `wix build`.
- **Custom icon.** Currently the shortcut icon is extracted from
  `erl.exe`. Replace `Icon SourceFile=` in `MinuteModem.wxs` with a path
  to a real `.ico` once we have one.
- **Desktop shortcut.** Could add a third shortcut directly on the
  desktop. Currently start-menu only.
- **EULA / license dialog.** The current installer skips the
  click-through EULA page. If MinuteModem ships with formal terms of
  use, swap `WixUI_InstallDir` for `WixUI_Mondo` and add a
  `WixVariable WixUILicenseRtf` pointing at a license RTF.
