# Build Environment

This document describes the toolchain MinuteModem requires on a
Windows development machine and how the build shell (`minutemodem-build-shell.cmd`)
ties everything together.

> **Future direction:** This setup is currently manual. Eventually
> `scripts/Setup-Windows.ps1` (using `winget`) plus a `mix mm.setup`
> task should automate as much as possible. Until then, follow this
> document by hand.

## Required Toolchain

### Erlang/OTP 28

The Erlang VM hosting the BEAM. We use OTP 28 specifically because
it ships modern wx bindings (wxWidgets 3.2+) which our UI depends on.

- Install location: `C:\Program Files\Erlang OTP\` (default for the
  official Windows installer)
- Source: <https://www.erlang.org/downloads>

Verify with `erl -version`.

### Elixir 1.19+

The language. Installed via Chocolatey:

```cmd
choco install elixir
```

- Install location: `C:\ProgramData\chocolatey\lib\elixir\tools\bin\`
- Source: <https://elixir-lang.org/install.html#windows>

Verify with `elixir --version`. Should report Erlang/OTP 28.

### Visual Studio 2022 BuildTools

The MSVC toolchain, Windows SDK, and CMake. Building NIFs from source
requires these.

- Install location:
  `C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\`
- Required workloads: "Desktop development with C++" (provides MSVC,
  Windows SDK, CMake)
- Source: <https://visualstudio.microsoft.com/downloads/> (scroll
  down to "Tools for Visual Studio" → "Build Tools for Visual
  Studio 2022")

The full Visual Studio Community / Pro / Enterprise IDE also works,
but BuildTools is sufficient and smaller (~7 GB vs ~20+ GB).

### .NET 8 SDK

Required by the WiX v7 toolset (which ships as a `dotnet tool`).

- Install location: `C:\Program Files\dotnet\`
- Source: <https://dotnet.microsoft.com/download/dotnet/8.0>
  (pick "Build apps - SDK", x64 Windows installer)

Verify with `dotnet --version`. Should report 8.x.x.

### WiX Toolset v7

Builds the MSI installer.

```cmd
dotnet tool install --global wix
wix eula accept wix7
wix extension add -g WixToolset.UI.wixext
```

The `eula accept` step is required since WiX v6+ enforces the Open
Source Maintenance Fee EULA. The fee only applies to organizations
generating >$10K/year in revenue, but acknowledgment is required
either way.

- Install location: `%USERPROFILE%\.dotnet\tools\wix.exe`
- Source: <https://wixtoolset.org/>

Verify with `wix --version`. Should report `7.x.x+...`.

### PortAudio (built from source)

Cross-platform audio I/O library used by `membrane_portaudio_plugin`.

We build PortAudio from source because the Windows binary distributions
are inconsistent and hard to integrate with our MSVC toolchain. The
build:

```cmd
git clone https://github.com/PortAudio/portaudio.git C:\build\portaudio-src
cd C:\build\portaudio-src
mkdir build
cd build
cmake -G "Visual Studio 17 2022" -A x64 -DCMAKE_INSTALL_PREFIX=C:\build\portaudio\install ..
cmake --build . --config Release --target install
```

After this, the layout at `C:\build\portaudio\install\` is:

```
C:\build\portaudio\install\
├── bin\portaudio.dll
├── include\portaudio.h
└── lib\portaudio.lib
```

Our fork of `membrane_portaudio_plugin` (at `C:\build\membrane_portaudio_plugin`)
is hardcoded to look at `C:/build/portaudio/install`. If you change
the install location, update its `bundlex.exs` too.

### Mesa3D 26+

Software OpenGL implementation, bundled into the release for RDP
support. See [`MESA_OPENGL.md`](MESA_OPENGL.md) for the full story.

- Install location: `C:\build\mesa3d-<version>-release-msvc\x64\`
- Source: <https://github.com/pal1000/mesa-dist-win/releases>
  (pick the `release-msvc` x64 variant)

The `mix.exs` is hardcoded to a specific version path (currently
26.0.5). Update the `@mesa_root` module attribute when upgrading.

### Forks of upstream Membrane libraries

Several upstream Membrane Framework dependencies needed Windows MSVC
fixes that aren't yet upstreamed. These are checked out as sibling
directories and referenced via `path:` deps in our umbrella's mix.exs:

```
C:\build\
├── shmex\                          (Win32 file mapping port)
├── bundlex\                        (MSVC toolchain support)
├── unifex\                         (codegen MSVC compatibility)
├── membrane_common_c\              (MSVC fixes)
├── membrane_portaudio_plugin\      (Windows portaudio config)
└── wx_mvu\                         (sizer propagation, layout fixes)
```

These are documented separately. See FORKS.md (TODO).

## The Build Shell

`C:\build\minutemodem-build-shell.cmd` is the entry point for daily
development. It:

1. Loads the MSVC environment via `vcvarsall.bat -arch=x64`. This
   makes `cl.exe`, `link.exe`, `cmake.exe`, etc. available on PATH
   and sets `LIB`, `INCLUDE`, etc. to point at the right Windows SDK
   headers and libraries.
2. Adds Elixir's `bin` to PATH.
3. Adds .NET SDK's `bin` to PATH.
4. Adds dotnet global tools to PATH (where WiX lives).
5. Changes to the project directory.
6. Drops into a cmd shell.

```bat
@echo off
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\Common7\Tools\VsDevCmd.bat" -arch=x64
set PATH=C:\ProgramData\chocolatey\lib\elixir\tools\bin;%PATH%
set PATH=C:\Program Files\dotnet;%PATH%
set PATH=%USERPROFILE%\.dotnet\tools;%PATH%
cd /d C:\build\minutemodem\apps\minutemodem_ui
cmd
```

**Always work inside this shell.** PowerShell and the default cmd
prompt won't have the right toolchain on PATH, and you'll get
mysterious errors like "cl.exe is not recognized" or "wix is not
recognized."

## Daily Development Loop

```cmd
:: Open the build shell (gives you a properly configured cmd window)
C:\build\minutemodem-build-shell.cmd

:: From the project root...
cd C:\build\minutemodem

:: For local dev — runs in dev mode against your dev DB
mix deps.get        (one-time, after pulling new deps)
iex -S mix          (or `mix run --no-halt` for non-interactive)

:: For prod release testing
set MIX_ENV=prod
set MM_UNLOCKED=true
mix release minutemodem_station --overwrite
_build\prod\rel\minutemodem_station\bin\minutemodem_station.bat start_iex

:: For MSI build
installer\build_msi.bat
```

## Environment Variables

| Variable | Purpose |
| -------- | ------- |
| `MIX_ENV` | `dev`, `prod`, or `test`. Mix uses this to pick the build tree. |
| `MM_UNLOCKED` | When `true`, bypasses the license gate. Required for development since the released `LicenseCore.enabled?` check uses `compile_env`, so changing it requires a `mix deps.clean license_core --build` after toggling. |
| `MM_DATA_DIR` | Override the runtime data directory. Defaults are platform-aware via `runtime.exs`. |
| `MM_CORE_NODE` | For remote-UI deployments, points at the core node's distributed name. Defaults to local node when unset. |

Set these in the build shell or before `mix release`. PowerShell uses
`$env:VAR = "value"` syntax, cmd uses `set VAR=value`. **Watch out for
trailing whitespace in `set`** — `set VAR=value & next_command` puts a
literal space at the end of `value`. Use `set "VAR=value"` to be safe.

## Common Gotchas

### "cl.exe is not recognized"
Not in the build shell. Open `C:\build\minutemodem-build-shell.cmd`.

### "wix is not recognized"
Either the build shell wasn't opened, or .NET tools aren't on PATH.
Verify with `where wix`. If it's not found, check that `%USERPROFILE%\.dotnet\tools`
is in PATH.

### "MIX_ENV=dev" when expected prod
Either you forgot `set MIX_ENV=prod`, or you set it in PowerShell (where
the syntax is different). Use `echo "[%MIX_ENV%]"` to verify; if it
shows `[prod ]` (with trailing space), use `set "MIX_ENV=prod"` instead.

### "Erlang/OTP version mismatch"
Elixir from Chocolatey expects the OTP version it was compiled against.
If you upgrade OTP independently, Elixir may stop working. Reinstall
Elixir to match: `choco upgrade elixir -y`.

### Build failures after `mix clean`
`mix clean` removes compiled output but can leave deps in a
half-compiled state. Recover with `mix deps.compile --force` to
recompile all deps from source.

### License gate not bypassing
Setting `MM_UNLOCKED=true` doesn't help unless `license_core` was
recompiled with that env in scope. Run:
```cmd
set MM_UNLOCKED=true
mix deps.clean license_core --build
mix deps.compile license_core
```

## What Should Be Documented But Isn't Yet

- **`scripts/Setup-Windows.ps1`** — bootstrap script that uses winget
  to install everything on a fresh machine. Doesn't exist yet.
- **`mix mm.setup`** — Elixir-side helper that downloads Mesa, builds
  PortAudio, accepts the WiX EULA. Doesn't exist yet.
- **`FORKS.md`** — comprehensive list of every fork we maintain, what
  it changes, and the upstream-PR plan. Lives in journal entries
  currently.

These are deferred until they become pain points (e.g. someone else
joins the project).

## Verification Checklist

A fresh build shell should be able to do all of these without errors:

```cmd
where erl                      :: should print c:\program files\erlang otp\bin\erl.exe
where elixir                   :: should print c:\programdata\chocolatey\...\elixir.bat
where mix                      :: should print c:\programdata\chocolatey\...\mix.bat
where dotnet                   :: should print c:\program files\dotnet\dotnet.exe
where wix                      :: should print c:\users\<you>\.dotnet\tools\wix.exe
where cl                       :: should print a path inside Visual Studio's MSVC tools
where cmake                    :: should print a path inside Visual Studio's CMake
dir C:\build\portaudio\install :: should show bin\, include\, lib\
dir C:\build\mesa3d-26.0.5-release-msvc\x64 :: should show opengl32.dll etc.
```

If any of these fail, the corresponding tool isn't installed or isn't
on the build shell's PATH.
