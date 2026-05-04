# Mesa3D OpenGL Bundling

This document describes why MinuteModem ships Mesa3D's software-renderer
DLLs alongside the Erlang runtime, and how the release process gets
them into the right place.

## The Problem

MinuteModem's UI uses `wxGLCanvas` (via `wx_mvu`) for the spectrogram
view. wxGLCanvas requires an OpenGL 3.0+ context to compile and run
modern shaders.

When MinuteModem is launched over a Windows Remote Desktop (RDP)
session, Windows substitutes its built-in **GDI Generic** OpenGL
implementation for the host's hardware GPU driver. GDI Generic is
**OpenGL 1.1**, full stop. No matter what GPU the host machine has —
RTX 4090, integrated graphics, virtualized DXVK — RDP serves
GDI Generic 1.1 to the client.

When wxGLCanvas tries to acquire an OpenGL 3.0 context against
GDI Generic, it gets back nothing usable. The error surfaces as:

```
wglGetCurrentContext is not set this will not work
```

...and any GL-rendered scene (the spectrogram, in our case) renders as
a blank or garbage canvas.

This is **not** a wxWidgets bug, an Erlang bug, or a wx_mvu bug. It's
Microsoft's deliberate design: RDP doesn't forward 3D graphics
acceleration. The fix has to live in our application's deployment.

## The Fix

Mesa3D is a software OpenGL implementation. It ships an `opengl32.dll`
that, when placed next to the executable, takes precedence over Windows'
system `opengl32.dll` due to Windows' DLL search order. Mesa's loader
then dispatches to its companion DLL (`libgallium_wgl.dll`), which
contains a complete OpenGL 4.5 implementation rendered in software via
LLVM (the "llvmpipe" backend).

Performance is much slower than hardware-accelerated GL, but for a
spectrogram view it's plenty fast — we're rendering perhaps a few
thousand vertices per frame, not photorealistic 3D scenes. And it works
identically over RDP, native console sessions, and headless VMs.

The drop-in fix: copy three Mesa DLLs (`opengl32.dll`,
`libgallium_wgl.dll`, `dxil.dll`) into the same directory as `erl.exe`,
which is the BEAM VM's binary. Erlang's wxGLCanvas implementation
loads OpenGL via standard Win32 `LoadLibrary("opengl32.dll")` — and
because `erl.exe`'s directory is searched first, our bundled Mesa wins.

## Implementation

Mesa is fetched manually as a one-time setup step:

```
C:\build\mesa3d-26.0.5-release-msvc\
└── x64\
    ├── opengl32.dll          (~140 KB — the shim/loader)
    ├── libgallium_wgl.dll    (~60 MB — the actual GL renderer)
    └── dxil.dll              (~1.4 MB — Direct3D shader compiler,
                                          used internally by Mesa)
```

Source: <https://github.com/pal1000/mesa-dist-win/releases>. Pick the
"release-msvc" variant of the latest x64 build.

The umbrella's `mix.exs` defines a `copy_mesa_dlls/1` step that runs
after `:assemble` and copies these three DLLs into the release's ERTS
bin directory:

```elixir
@mesa_root "C:/build/mesa3d-26.0.5-release-msvc/x64"
@mesa_dlls ~w(opengl32.dll libgallium_wgl.dll dxil.dll)

defp copy_mesa_dlls(%Mix.Release{} = release) do
  case :os.type() do
    {:win32, _} -> do_copy_mesa_dlls(release)
    _ -> :ok
  end
  release
end

defp do_copy_mesa_dlls(release) do
  erts_bin = Path.join([release.path, "erts-#{release.erts_version}", "bin"])
  if File.dir?(@mesa_root) do
    for dll <- @mesa_dlls do
      src = Path.join(@mesa_root, dll)
      dst = Path.join(erts_bin, dll)
      if File.exists?(src) do
        File.cp!(src, dst)
        IO.puts("* copied Mesa DLL: #{dll}")
      else
        IO.warn("Mesa DLL not found at #{src}; skipping")
      end
    end
  else
    IO.warn(
      "Mesa3D directory not found at #{@mesa_root}; " <>
        "OpenGL over RDP will fall back to GDI Generic 1.1."
    )
  end
  :ok
end
```

The step is wired into `minutemodem_station` and `minutemodem_remote`
release configs (the two that ship a UI):

```elixir
minutemodem_station: [
  applications: [...],
  include_erts: true,
  strip_beams: true,
  steps: [
    :assemble,
    &copy_mesa_dlls/1,      # ← here
    &strip_erts_debug/1,
    &patch_release_bat/1
  ]
]
```

After `mix release`, the ERTS bin directory contains both the BEAM
binaries and the Mesa DLLs:

```
_build/prod/rel/minutemodem_station/erts-16.4/bin/
├── erl.exe
├── erlexec.exe
├── beam.smp.dll
├── opengl32.dll              ← Mesa shim
├── libgallium_wgl.dll        ← Mesa renderer
├── dxil.dll                  ← Mesa internal
└── ... (other ERTS files)
```

When the MSI is built from this tree, the DLLs are bundled automatically
via the WiX `<Files>` glob, which captures everything under the release
path.

## Defensive Behavior

If the Mesa source directory at `@mesa_root` doesn't exist, the step
**logs a warning and continues**. It does not fail the build. The
rationale: someone cloning the repo to do non-UI work (license_api
backend, a remote core release, etc.) shouldn't be blocked by a missing
Mesa install. They get a clear warning telling them where to download
Mesa from if they need it.

If individual Mesa DLLs are missing within an existing directory (e.g.
a partial download), each missing file is logged and the step continues.

## Performance Notes

Software-rendered OpenGL is, of course, slower than hardware. Some
rough numbers from the spectrogram view at 1280×720:

- Native console session, hardware GL: ~600 fps
- RDP session, Mesa llvmpipe: ~120 fps
- RDP session, GDI Generic 1.1 (no Mesa): doesn't render

For the spectrogram, 120 fps is comfortably above what we display
(60 fps target). The only practical downside is CPU usage: Mesa burns
roughly one core's worth of compute when actively rendering. For an
ALE radio app that spends most of its time idle waiting for audio
samples, this is acceptable.

## Upgrading Mesa

When a new Mesa release is wanted:

1. Download the new build from <https://github.com/pal1000/mesa-dist-win/releases>.
   Pick the `mesa3d-<version>-release-msvc` x64 zip.
2. Extract to `C:\build\mesa3d-<version>-release-msvc\`.
3. Update the version in `mix.exs`:

   ```elixir
   @mesa_root "C:/build/mesa3d-<NEW_VERSION>-release-msvc/x64"
   ```

4. Rebuild release: `mix release minutemodem_station --overwrite`.
5. The build output should print three `* copied Mesa DLL:` lines.
6. Test: launch the release, navigate to the Ops tab (which has the
   spectrogram canvas). It should render without OpenGL errors in the
   logs.

There's no need to keep the old Mesa directory around — the path is the
only thing that needs to point at the right version.

## Why Not Just Detect and Error Out Without Mesa?

We could have the application detect that it's running over RDP and
refuse to start, asking the user to install Mesa themselves. We chose
not to because:

1. Mesa works on non-RDP sessions too. The DLLs in `erl.exe`'s
   directory are loaded preferentially over the system DLLs, so even
   on a console session with hardware GL available, we use Mesa. This
   means consistent rendering behavior everywhere.
2. Asking end users to install Mesa is a deployment burden we don't
   want to push onto them.
3. The 60 MB cost of bundling `libgallium_wgl.dll` is reasonable for
   the reliability we get.

## Why Not Use a Different GUI Toolkit?

We use wxWidgets because Erlang/OTP ships with `:wx`, the native
wxWidgets bindings. wx is a proven, maintained, cross-platform GUI
toolkit; rebuilding the UI on a different toolkit (Tauri, Webview, etc.)
would be a much bigger undertaking than shipping Mesa.

## Verification

After installing the MSI, check that Mesa is in place:

```cmd
dir "C:\Program Files\Northwest Tech\MinuteModem\erts-16.4\bin\opengl32.dll"
dir "C:\Program Files\Northwest Tech\MinuteModem\erts-16.4\bin\libgallium_wgl.dll"
```

Both should exist and be the right sizes (~140 KB and ~60 MB
respectively).

When running the app, the renderer logs should NOT contain
`wglGetCurrentContext is not set` — that error is the canary indicating
GDI Generic 1.1 is being used. Healthy startup logs include:

```
[info] Renderer: OpenGL initialized
```

(Or absence of OpenGL-related warnings, depending on log verbosity.)

## Files Touched

- `mix.exs` — `copy_mesa_dlls/1` and the `&copy_mesa_dlls/1` step in
  `minutemodem_station` and `minutemodem_remote` release configs.

## Future Improvements

- **Mesa version bump automation.** Currently the version is hardcoded
  in `mix.exs` as a module attribute. Could fetch the latest release
  metadata from GitHub and bump automatically, but version pinning is
  also a feature: we don't want a Mesa update to break rendering
  silently.
- **Detect RDP at runtime and only enable software rendering then.**
  Possible but complicated, and currently provides no benefit (the cost
  of using Mesa on a console session is negligible since hardware GL
  isn't generally a bottleneck for this app).
- **Fallback to ANGLE.** Microsoft's ANGLE library translates OpenGL ES
  to Direct3D 11. It works over RDP because Direct3D 11 is forwarded
  by RDP's RemoteFX path. Trade-off: ANGLE is OpenGL ES, not desktop
  OpenGL, so wx's Erlang bindings would need adjustment. Mesa is a
  cleaner fit.
  