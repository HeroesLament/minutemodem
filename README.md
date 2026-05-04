# MinuteModem

ALE radio software for Windows. Native MSVC build, real-time audio I/O,
software-rendered OpenGL spectrogram, deployable as a per-machine MSI
installer.

## Quick start

> First-time setup is involved. See
> [`docs/BUILD_ENVIRONMENT.md`](docs/BUILD_ENVIRONMENT.md) for the
> required toolchain (Erlang, Elixir, MSVC, .NET SDK, WiX, PortAudio,
> Mesa3D).

Once the environment is set up, daily development is:

```cmd
:: Open the build shell (sets up MSVC, dotnet, WiX paths)
C:\build\minutemodem-build-shell.cmd

:: Build a prod release
set MIX_ENV=prod
set MM_UNLOCKED=true
mix release minutemodem_station --overwrite

:: Run it directly
_build\prod\rel\minutemodem_station\bin\minutemodem_station.bat start_iex

:: ...or package as an MSI
installer\build_msi.bat
```

The MSI lands at `installer\dist\MinuteModem-<version>.msi`. Double-click
to install (per-machine, requires UAC). Start menu gets two shortcuts
under "Northwest Tech":

- **MinuteModem** — GUI only, no console (end-user experience)
- **MinuteModem (Console)** — GUI plus iex prompt for diagnostics

## What's in here

MinuteModem is an Elixir umbrella with native MSVC NIFs, a wxWidgets
GUI, and an audio pipeline built on Membrane Framework. The umbrella
structure:

```
apps/
├── minutemodem_core/       Audio pipeline, ALE link layer, persistence,
│                           rig control, modem implementations
├── minutemodem_ui/         wxWidgets GUI (scenes, renderer, OpenGL canvas)
├── minutemodem_simnet/     HF channel simulation for offline testing
├── minutemodem_client/     DTE client for external integrations
├── license_core/           License key validation
├── license_tui/            Terminal-mode license entry
├── license_ui/             GUI license entry
└── license_api/            License key issuance API (separate release)
```

Native code lives in `apps/minutemodem_core/native/` (Rust crates for
MELP voice codec and PHY modem) and across several forks of upstream
Membrane libraries that needed Windows MSVC support.

## Releases

Four release configurations are defined in the umbrella's `mix.exs`:

| Release              | Purpose                                   |
| -------------------- | ----------------------------------------- |
| `minutemodem_station` | Full app: UI, core, audio, all rigs       |
| `minutemodem_remote`  | UI-only, connects to a remote core node   |
| `minutemodem_core`    | Headless core, no GUI                     |
| `license_api`         | License issuance HTTP API                 |

`minutemodem_station` is the one shipped via MSI. The others are for
deployment scenarios we'll grow into.

## Documentation

| Document | Topic |
| -------- | ----- |
| [`docs/BUILD_ENVIRONMENT.md`](docs/BUILD_ENVIRONMENT.md) | Toolchain setup, build shell, dependencies |
| [`docs/WINDOWS_PATH_HANDLING.md`](docs/WINDOWS_PATH_HANDLING.md) | How we make releases robust to `Program Files (x86)` and other parenthesized install paths |
| [`docs/MESA_OPENGL.md`](docs/MESA_OPENGL.md) | Why Mesa3D ships with the release, how it enables wxGLCanvas to work over RDP |
| [`installer/README.md`](installer/README.md) | WiX v7 MSI build process |

## License

Proprietary. Built and maintained by Northwest Tech.
