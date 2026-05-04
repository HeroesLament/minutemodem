# Building MinuteModem

This document covers the full build process for MinuteModem on each
supported platform: macOS, Linux, and Windows. The Windows path
additionally covers MSI packaging via WiX.

For the toolchain itself (what to install and where it goes), see
[`docs/BUILD_ENVIRONMENT.md`](docs/BUILD_ENVIRONMENT.md). This document
assumes the toolchain is already in place and focuses on the build
commands themselves.

> **Note on releases.** MinuteModem defines four release configurations
> in the umbrella's `mix.exs`:
>
> - `minutemodem_station` — full app: UI + core + audio. The default
>   end-user release.
> - `minutemodem_remote` — UI-only, connects to a remote core.
> - `minutemodem_core` — headless core only, no UI.
> - `license_api` — license issuance HTTP API, separate deployment.
>
> All examples below use `minutemodem_station`. Substitute the others
> as needed.

---

## macOS

### Prerequisites

- Erlang/OTP 28 with wxWidgets support (`brew install erlang`)
- Elixir 1.19+ (`brew install elixir`)
- Rust toolchain (`brew install rust`) — for the MELP/PHY native crates
- PortAudio (`brew install portaudio`)

### Build

From the umbrella root:

```bash
cd ~/src/minutemodem
mix deps.get
mix compile
```

Run interactively for development:

```bash
iex -S mix
```

### Release

```bash
export MIX_ENV=prod
export MM_UNLOCKED=true   # bypasses license gate during local testing
mix release minutemodem_station --overwrite
```

Output goes to:

```
_build/prod/rel/minutemodem_station/
```

Run the release:

```bash
_build/prod/rel/minutemodem_station/bin/minutemodem_station start_iex
```

### Notes for macOS

- The `rel/station/env.sh.eex` config sets `RELEASE_DISTRIBUTION=sname`
  and `RELEASE_NODE=station` for the station release. These take effect
  on macOS releases.
- `rel/station/vm.args.eex` sets `+P 1048576` (process limit for
  Membrane pipelines) and `-heart` (auto-restart on crash). Both apply.
- macOS distribution is currently source-based; we don't yet build a
  `.app` bundle or `.pkg` installer. Run from the release directory or
  copy it elsewhere.
- For a packaged macOS distribution, `scripts/build_macos.sh` exists
  but is not maintained as part of the current Windows-focused effort.

---

## Linux

### Prerequisites

- Erlang/OTP 28 with wxWidgets and crypto support (varies by distro;
  on Ubuntu, `apt install erlang-base erlang-dev erlang-wx
  erlang-crypto`)
- Elixir 1.19+ (recommend asdf or mise to pin)
- GCC (`apt install build-essential`)
- Rust toolchain (`rustup`)
- PortAudio dev headers (`apt install portaudio19-dev`)

### Build

Same as macOS:

```bash
cd ~/src/minutemodem
mix deps.get
mix compile
```

### Release

```bash
export MIX_ENV=prod
export MM_UNLOCKED=true
mix release minutemodem_station --overwrite
_build/prod/rel/minutemodem_station/bin/minutemodem_station start_iex
```

### Notes for Linux

- All four release configurations build cleanly on Linux. The
  `minutemodem_remote` and `minutemodem_core` releases are deployment
  targets we expect to use most often on Linux servers.
- `rel/<release>/env.sh.eex` and `rel/<release>/vm.args.eex` apply to
  Linux releases identically to macOS.
- For the headless `minutemodem_core` release on a server:

  ```bash
  mix release minutemodem_core --overwrite
  _build/prod/rel/minutemodem_core/bin/minutemodem_core daemon
  ```

  The `daemon` command starts the release in the background. Use
  `start_iex` only for foreground/interactive testing.

---

## Windows

Windows is the most involved path. The toolchain has more pieces, the
MSI packaging is its own distinct step, and there are several
Windows-specific concerns documented elsewhere
([`docs/MESA_OPENGL.md`](docs/MESA_OPENGL.md),
[`docs/WINDOWS_PATH_HANDLING.md`](docs/WINDOWS_PATH_HANDLING.md)).

### Prerequisites

See [`docs/BUILD_ENVIRONMENT.md`](docs/BUILD_ENVIRONMENT.md) for full
toolchain setup. Briefly:

- Erlang/OTP 28
- Elixir 1.19+ (via Chocolatey)
- Visual Studio 2022 BuildTools with the C++ workload
- .NET 8 SDK
- WiX Toolset v7 (installed as a `dotnet tool`)
- PortAudio built from source at `C:\build\portaudio\install\`
- Mesa3D 26+ at `C:\build\mesa3d-<version>-release-msvc\x64\`
- Six forked dependencies under `C:\build\<name>\`
  (see [`docs/FORKS.md`](docs/FORKS.md))

### The build shell

**Always work inside the build shell.** It loads the MSVC environment
and adds Elixir, .NET, and WiX to PATH:

```cmd
C:\build\minutemodem-build-shell.cmd
```

PowerShell and the default cmd prompt won't have the right tools on
PATH and will fail with cryptic errors like "cl.exe is not
recognized."

### Building (release only)

The Windows path is **release-focused**. Local `iex -S mix` development
works on Windows too, but the GUI on Windows over RDP requires the
release tree (which contains Mesa) — interactive `iex -S mix` over RDP
won't render the UI correctly. For UI work, build a release.

```cmd
cd C:\build\minutemodem
set "MIX_ENV=prod"
set "MM_UNLOCKED=true"
mix deps.get
mix release minutemodem_station --overwrite
```

The `set "VAR=value"` form (with quotes around the whole assignment)
prevents trailing-whitespace bugs that occur with `set VAR=value &
next_command`.

What you should see during release:

- bundlex output for each native NIF (shmex, unifex, membrane,
  portaudio sink/source/devices)
- `* patched bin/minutemodem_station.bat for parenthesized install
  paths`
- `* patched releases/<vsn>/elixir.bat for parenthesized install paths`

The patcher messages indicate that `mix.exs`'s post-assemble step
successfully rewrote Elixir's release scripts to handle paths
containing parentheses (like `Program Files (x86)`). See
[`docs/WINDOWS_PATH_HANDLING.md`](docs/WINDOWS_PATH_HANDLING.md) for
why this matters.

The release lands at:

```
C:\build\minutemodem\_build\prod\rel\minutemodem_station\
```

Run the release directly (no installer):

```cmd
"C:\build\minutemodem\_build\prod\rel\minutemodem_station\bin\minutemodem_station.bat" start_iex
```

### Building the MSI installer

After a successful release build, package as an MSI:

```cmd
cd C:\build\minutemodem
installer\build_msi.bat
```

Output:

```
installer\dist\MinuteModem-0.1.0.msi
```

The MSI is roughly 60–100 MB depending on whether Mesa3D and ERTS
debug PDBs are included.

#### What's inside the MSI

- The complete release tree from
  `_build\prod\rel\minutemodem_station\`
- All BEAM bytecode, ERTS, configuration, Mesa3D OpenGL DLLs
- Two Start Menu shortcuts under "Northwest Tech":
  - **MinuteModem** — GUI only, no console (production end-user)
  - **MinuteModem (Console)** — GUI plus iex prompt for diagnostics
- Per-machine install (requires UAC elevation at install time)

#### Installing for testing

```cmd
:: Uninstall any prior version
msiexec /x C:\build\minutemodem\installer\dist\MinuteModem-0.1.0.msi /quiet
ping -n 11 127.0.0.1 >nul

:: Install fresh
msiexec /i C:\build\minutemodem\installer\dist\MinuteModem-0.1.0.msi /quiet
ping -n 16 127.0.0.1 >nul

:: Verify and run
"C:\Program Files\Northwest Tech\MinuteModem\bin\minutemodem_station.bat" start_iex
```

The `ping -n N 127.0.0.1 >nul` is a portable way to wait roughly N-1
seconds for the install to finish. `msiexec` returns immediately even
though the install is still running. Insufficient wait time produces
"file not found" errors.

#### Testing parenthesized install paths

The marquee Windows feature is install-path robustness. Test the
default 32-bit path:

```cmd
msiexec /i C:\build\minutemodem\installer\dist\MinuteModem-0.1.0.msi INSTALLFOLDER="C:\Program Files (x86)\MinuteModem" /quiet
ping -n 16 127.0.0.1 >nul
"C:\Program Files (x86)\MinuteModem\bin\minutemodem_station.bat" start_iex
```

If the app boots into iex without parser errors like `\MinuteModem\
releases\0.1.0\sys"" was unexpected at this time`, the patcher worked.

### Recompiling individual deps

When iterating on one of the forked dependencies (`shmex`, `bundlex`,
`unifex`, `membrane_common_c`, `membrane_portaudio_plugin`, `wx_mvu`):

```cmd
cd C:\build\minutemodem
mix deps.compile <dep_name> --force
```

Then rebuild the release as above. The `--force` is required because
mix's dependency-change detection doesn't always notice edits to
files inside a `path:` dependency.

### Cleaning up build state

If the build gets confused (mix.exs changes not picked up, dep
compile cache stale, etc.):

```cmd
mix clean
mix deps.compile --force
mix release minutemodem_station --overwrite
```

`mix clean` only removes top-level build outputs; `mix deps.compile
--force` rebuilds all deps. Together they're the closest thing to a
"start over" without losing the deps directory entirely.

If the issue persists, the heavy hammer:

```cmd
rmdir /s /q _build
mix deps.get
mix deps.compile
mix release minutemodem_station --overwrite
```

This re-fetches and recompiles from scratch. Takes 5-10 minutes.

---

## Cross-platform notes

### Environment variables

| Variable | Purpose |
|----------|---------|
| `MIX_ENV` | `dev`, `prod`, or `test`. Default is `dev`. |
| `MM_UNLOCKED` | Set to `true` to bypass the license gate during development. Affects `license_core`, which uses compile-time env via `Application.compile_env/3`. After toggling, run `mix deps.compile license_core --build` to rebuild it. |
| `MM_DATA_DIR` | Override the runtime data directory. Defaults are platform-aware in `runtime.exs`: `%LOCALAPPDATA%\MinuteModem` on Windows, `~/Library/Application Support/MinuteModem` on macOS, `~/.local/share/MinuteModem` on Linux. |
| `MM_CORE_NODE` | For `minutemodem_remote` and `minutemodem_ui`, points at the core node's distributed name. Defaults to local node when unset. |

### `rel/<name>/env.sh.eex` and `vm.args.eex`

These are EEx templates that Mix processes during release assembly to
produce the final `env.sh` and `vm.args` for each release. They live
under `rel/<release_name>/` in the source tree:

```
rel/
├── core/
│   └── env.sh.eex
├── remote/
│   ├── env.sh.eex
│   └── vm.args.eex
└── station/
    ├── env.sh.eex
    └── vm.args.eex
```

These customize:

- **Distribution mode** (`name` for distributed, `sname` for local-only)
- **Node naming** (e.g. `core@hostname`, `station`, `ui@hostname`)
- **`-heart`** for automatic restart on crash
- **`+P 1048576`** to raise the process limit for Membrane pipelines

The `.sh.eex` files are no-ops on Windows (Mix uses `.bat.eex`
templates there, which it auto-generates from defaults).

### Native artifacts

Several apps include Rust crates that compile to NIFs:

```
apps/minutemodem_core/native/
├── melpe/         (MELP voice codec)
└── phy_modem/     (PHY layer modulation/demodulation)

apps/minutemodem_simnet/native/
└── channel_physics/

apps/minutemodem_ui/native/
└── ui_dsp/        (FFT, analytic signal, meters)
```

These build automatically as part of `mix compile` via Rustler. They
require a Rust toolchain on PATH. On a release build, the compiled
`.dll`/`.so`/`.dylib` files are copied into each app's `priv/native/`
directory and bundled into the release tree.

### Verification

After any build, the same end-to-end verification works on all
platforms (with platform-appropriate path separators and shell
syntax):

```bash
# Linux/macOS
_build/prod/rel/minutemodem_station/bin/minutemodem_station start_iex
```

```cmd
:: Windows (release)
_build\prod\rel\minutemodem_station\bin\minutemodem_station.bat start_iex

:: Windows (installed via MSI)
"C:\Program Files\Northwest Tech\MinuteModem\bin\minutemodem_station.bat" start_iex
```

If iex prompt opens, supervision tree starts cleanly, and audio
pipeline initializes without NIF load errors, the build is healthy.
