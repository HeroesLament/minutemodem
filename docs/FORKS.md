# Forks Maintained by MinuteModem

MinuteModem depends on six forks of upstream Membrane Framework
libraries (plus one fork of an internal library). Each fork carries
Windows-MSVC-portability or behavior fixes that aren't yet upstreamed.

This document catalogs **what each fork changes**, **why**, and what
the upstream PR plan looks like.

All forks live in sibling directories under `C:\build\` and are wired
into the umbrella's mix.exs as `path:` deps with `override: true`:

```elixir
{:wx_mvu, path: "C:/build/wx_mvu", override: true},
{:bundlex, path: "C:/build/bundlex", override: true},
{:membrane_portaudio_plugin, path: "C:/build/membrane_portaudio_plugin", override: true},
{:membrane_common_c, path: "C:/build/membrane_common_c", override: true},
{:unifex, path: "C:/build/unifex", override: true},
{:shmex, path: "C:/build/shmex", override: true},
```

Order matters in the override list: the deepest forks first so they
override their hex-version peers consistently.

---

## 1. shmex — `C:\build\shmex`

**Upstream:** <https://github.com/membraneframework/shmex>  
**Why we forked:** Upstream uses POSIX shared memory primitives
(`shm_open`, `mmap`, `ftruncate`, `clock_gettime`) that don't exist
on Windows / MSVC.

### Changes

Five C files in `c_src/shmex/` rewritten to add a `#ifdef _WIN32`
branch alongside the POSIX path:

| File | Change |
|------|--------|
| `c_src/shmex/shmex/lib.h` | `#ifdef _WIN32` includes `<windows.h>`, defines `MAP_FAILED` as `((void*)-1)`, declares Windows-equivalent shim functions |
| `c_src/shmex/shmex/lib.c` | Win32 path uses `CreateFileMappingA` / `MapViewOfFile` / `UnmapViewOfFile` / `CloseHandle` instead of `shm_open` / `mmap` / `munmap` / `close`. `clock_gettime` replaced with `QueryPerformanceCounter`. Removed `_POSIX_C_SOURCE` feature macro (irrelevant on MSVC). |
| `c_src/shmex/shmex.c` | Conditionally include POSIX vs Win32 headers |
| `c_src/shmex/nif/shmex/shmex.c` | Same conditional headers |
| `c_src/shmex/nif/shmex/shmex.h` | Same conditional headers |

### Design notes

- **Win32 named mappings replace POSIX shm.** `CreateFileMappingA` with
  `INVALID_HANDLE_VALUE` creates a pagefile-backed named mapping —
  semantically equivalent to POSIX shared memory.
- **Naming.** POSIX `shm_open` requires a leading `/`; Windows
  `CreateFileMappingA` accepts flat names. The leading `/` is harmless
  on Windows kernel objects, so we kept the existing
  `SHMEX_SHM_NAME_PREFIX = "/shmex-"`.
- **Refcounting.** POSIX needs `shm_unlink` to remove the segment;
  Windows reference-counts handles automatically — closing the last
  one frees the mapping. The `shmex_shm_unlink` Win32 path is a no-op
  beyond closing handles.
- **No struct shape changes.** The `Shmex` struct in `lib.h` is
  identical on both platforms. Win32 stores the `HANDLE` separately
  inside the implementation, not in the struct. This kept the NIF and
  CNode interfaces identical.

### Upstream PR plan

Submit as a single PR with all five files changed. The diff is
self-contained, additive (POSIX paths untouched), and demonstrably
correct (we use it daily). High likelihood of acceptance.

---

## 2. bundlex — `C:\build\bundlex`

**Upstream:** <https://github.com/membraneframework/bundlex>  
**Why we forked:** bundlex's MSVC toolchain support was incomplete and
broken on modern Visual Studio Build Tools. We rewrote
`visual_studio.ex` to make MSVC builds first-class.

### Changes

Two files heavily modified:

#### `lib/bundlex/toolchain/visual_studio.ex`

This is the core toolchain module. Ten distinct fixes:

1. **`vswhere -products *` for BuildTools.** Upstream queried only for
   "Microsoft.VisualStudio.Product.Community/Pro/Enterprise" — missing
   the BuildTools SKU which is the standard CI/dev install. Added
   `-products *` to accept any installed VS product.

2. **`/IMPLIB:<basename>_implib.lib` for LNK1149.** When DLL output and
   import library both use the same base name, MSVC linker errors with
   LNK1149 ("output filename matches input filename"). We rename the
   import lib to `<basename>_implib.lib` to avoid the collision.

3. **`/D BUNDLEX_<INTERFACE>` macros.** unifex's tie-headers conditionally
   compile based on `BUNDLEX_NIF` vs `BUNDLEX_CNODE` macros. Bundlex on
   Linux passed these via `gcc -D`; the MSVC path was missing them.
   Added `/D BUNDLEX_<INTERFACE>` matching the interface name.

4. **`/std:c11`.** Match the Unix toolchain's C11 standard. Without
   this, MSVC defaults to C89 and rejects C11-isms in the source.

5. **`/experimental:c11atomics` for MSVC 17.5+.** C11 atomics support
   requires this flag on Visual Studio 17.5 and later. Bundlex's old
   path didn't include it and atomic-using code would fail to compile.

6. **`lib_dirs` and `linker_flags` consumption.** Bundlex's MSVC branch
   wasn't reading the `lib_dirs:` or `linker_flags:` keys from natives
   specs. We now emit these as `/LIBPATH:<dir>` and pass through
   linker flags verbatim.

7. **Per-source obj naming with SHA1.** When two source files in the
   same NIF have the same basename (e.g. `lib.c` from shmex and from
   bunch_native), MSVC's default obj naming (`<basename>.obj`) collides
   in the working dir. We name objs `<basename>_<sha1>.obj` where
   sha1 is hashed from the full path.

8. **Per-native obj working subdirectory.** When two NIFs build in
   the same parent dir, their objs collide. Each native gets its own
   working subdir.

9. **`.bat` trampoline for cmd.exe 8191-char limit.** On Windows, cmd
   has a hard 8191-character command-line limit. Big NIF builds with
   many include dirs and lib paths blow past this. We write a
   `.bat` file with the full command and invoke it via `cmd /c`,
   sidestepping the direct-invocation length limit.

10. **Runtime DLL copy via `find_sibling_dll/2`.** When a NIF links
    against a third-party DLL (like `portaudio.dll`), the loader must
    find that DLL at runtime. Bundlex's Linux path used `RPATH`; on
    Windows there's no equivalent. We copy the sibling DLL into the
    NIF's `priv/` directory at build time so it's discoverable.

#### `lib/bundlex/build_script.ex`

Modified to write the long compile/link command to a `.bat` file
instead of invoking it directly. This is the consumer of fix #9 above.

### Upstream PR plan

This is a substantial PR — touches the heart of the MSVC toolchain.
Recommend splitting into smaller logical PRs:

1. **`vswhere -products *` and `/D BUNDLEX_<INTERFACE>`** — small,
   uncontroversial. Send first.
2. **Per-source obj SHA1 naming + per-native subdir** — fixes a real
   collision problem, well-scoped.
3. **`/IMPLIB`, `/std:c11`, `/experimental:c11atomics`, lib_dirs,
   linker_flags** — bundle as "MSVC modernization."
4. **`.bat` trampoline + sibling DLL copy** — the deployment-related
   bits, can stand on their own.

Some of these are likely to be merged quickly (vswhere, BUNDLEX_*); the
trampoline and DLL copy may need more discussion.

---

## 3. unifex — `C:\build\unifex`

**Upstream:** <https://github.com/membraneframework/unifex>  
**Fork base:** Originally HeroesLament's fork; now contains additional
codegen portability work.  
**Why we forked:** unifex's code generator emits **GCC statement
expressions** (`({ ... ; expr; })`) — a non-standard GCC extension that
MSVC rejects entirely. We refactored the codegen to emit portable
ISO C using static helper functions instead.

### Changes

Two categories of fixes.

#### Codegen portability (the big one)

The original codegen had **24 sites across 12 files** emitting GCC
statement expressions:

| File | Sites | Status |
|------|-------|--------|
| `code_generators/nif.ex` (`generate_tuple_maker`) | 1 | **Refactored** |
| `code_generator/base_types/list.ex` | 4 | **NIF serialize refactored**; NIF parse, both CNode methods still pending |
| `code_generator/base_types/struct.ex` | 4 | **NIF serialize refactored**; NIF parse, both CNode methods still pending |
| `code_generator/base_types/enum.ex` | 5 | `enum_native_name/1` extracted as public helper; statement-expression refactor pending |
| `code_generator/base_types/atom.ex` | 1 | Pending |
| `code_generator/base_types/bool.ex` | 1 | Pending |
| `code_generator/base_types/int.ex` | 2 | Pending |
| `code_generator/base_types/int64.ex` | 2 | Pending |
| `code_generator/base_types/uint64.ex` | 1 | Pending |
| `code_generator/base_types/state.ex` | 1 | Pending |
| `code_generator/base_types/string.ex` | 1 | Pending |
| `code_generator/base_types/unsigned.ex` | 2 | Pending |
| **CNode codegen** | several | Pending — Windows port also requires Winsock, separately |

#### What "refactored" means

Two new files:

- **NEW** `lib/unifex/helper_accumulator.ex` — an OTP `Agent` that
  holds the list of static helper functions to emit at file scope.
  Each call to `generate_arg_serialize` (etc.) pushes a helper into
  the accumulator and returns just the call expression.
- **MODIFIED** `lib/unifex/app.ex` — adds `Unifex.HelperAccumulator` to
  the supervision tree alongside the existing `Unifex.Counter`.

The pattern for each site:

```elixir
# OLD: emits GCC statement expression inline
def generate_arg_serialize(name, ctx) do
  ~g"""
  ({
    ERL_NIF_TERM list = enif_make_list(env, 0);
    for(int i = #{name}_length-1; i >= 0; i--) {
      list = enif_make_list_cell(env, ..., list);
    }
    list;
  })
  """
end

# NEW: emits a static helper at file scope; returns call expression
def generate_arg_serialize(name, ctx) do
  counter = Unifex.Counter.get_and_increment()
  helper_name = "unifex_serialize_list_#{counter}"

  helper = ~g"""
  static ERL_NIF_TERM #{helper_name}(UnifexEnv *env, #{native_type} *arr, unsigned int len) {
    ERL_NIF_TERM list = enif_make_list(env, 0);
    for (int i = (int)len - 1; i >= 0; i--) {
      list = enif_make_list_cell(env, ..., list);
    }
    return list;
  }
  """

  Unifex.HelperAccumulator.push(helper)
  ~g<#{helper_name}(env, #{name}, #{name}_length)>
end
```

Then `code_generators/nif.ex`'s `generate_source/1` was updated to
drain the accumulator at the end and emit the helpers between
`#include "<name>.h"` and the function bodies.

#### Other fixes

| File | Change |
|------|--------|
| `c_src/unifex/nif/unifex/unifex.c` | Replaced `enum { TMP_LEN = 6 };` declaration that triggered a true MSVC ICE (internal compiler error). Used `#define TMP_LEN 6` instead. |
| `bundlex.exs` | Added `case Bundlex.get_target().os` branch that skips the `cnode` interface on Windows (the cnode code uses POSIX sockets that don't yet have a Win32 port). |

### Upstream PR plan

This is the most complex fork. The codegen refactor should go upstream
as a clean PR with these properties:

1. **Backward compatible.** Trivial base types continue to return plain
   strings; the new map-shape (`%{helpers: _, expression: _}`) is
   opt-in. Out-of-tree base type implementations don't need to change.
2. **Bundle complete.** Submit only after refactoring all 24 sites,
   not partial. Half-done is harder to review.
3. **CNode Windows port** is a separate, larger PR. POSIX sockets →
   Winsock is a real porting job.
4. **Companion test.** Build membrane_common_c with the patched unifex
   and assert no statement-expression artifacts in the generated `.c`
   files.

Estimated remaining work: ~half a working day to finish the remaining
18 base-type sites, mechanical at this point since the pattern is
established.

---

## 4. membrane_common_c — `C:\build\membrane_common_c`

**Upstream:** <https://github.com/membraneframework/membrane_common_c>  
**Why we forked:** Two MSVC compatibility issues plus one logic bug.

### Changes

| File | Change |
|------|--------|
| `c_src/membrane/membrane.h` | Removed `#ifdef __GNUC__` guard around `<stdint.h>`. MSVC also has `<stdint.h>` (since VS 2010). Pre-GCC-only guard is wrong; we always need it. |
| `c_src/membrane_ringbuffer/ringbuffer.c` | Added 4 explicit `(char *)` casts where MSVC's stricter type checking flagged C2036 ("size of '*' is unknown"). |
| `c_src/membrane_ringbuffer/ringbuffer.c:122` | **Logic bug:** an off-by-one in the wrap-around check. Caught while diagnosing the C2036. To be filed as a separate upstream bug fix PR — independent of MSVC. |

### Upstream PR plan

Two PRs:

1. **MSVC compatibility:** the `<stdint.h>` and `(char *)` cast fixes.
   Trivial, additive, no-risk.
2. **The wrap-around logic bug.** Independent of Windows. Smaller
   focused PR with a regression test.

---

## 5. membrane_portaudio_plugin — `C:\build\membrane_portaudio_plugin`

**Upstream:** <https://github.com/membraneframework/membrane_portaudio_plugin>  
**Why we forked:** Hard-coded PortAudio paths on Windows, plus needs
the bundlex DLL-copy mechanism.

### Changes

Single-file change to `bundlex.exs` adding a Windows branch:

```elixir
case Bundlex.get_target().os do
  "windows" ->
    @windows_portaudio_root "C:/build/portaudio/install"

    [
      includes: ["#{@windows_portaudio_root}/include"],
      lib_dirs: ["#{@windows_portaudio_root}/lib"],
      libs: ["portaudio"],
      sources: [...]
    ]

  _ ->
    # Original Linux/macOS branch
    [...]
end
```

This wires PortAudio's MSVC-built install at `C:\build\portaudio\install\`
into the NIF build (consuming bundlex's `lib_dirs` and `linker_flags`
fix from above).

### Why hard-coded?

The path is hard-coded because there's no good cross-platform mechanism
in upstream PortAudio to discover its install location. On Linux,
pkg-config does this; on macOS, Homebrew has standard paths; on
Windows, neither exists in any standard form.

For deployment: anyone reproducing this build needs to install
PortAudio to the same path or update `bundlex.exs`. Documented in
`BUILD_ENVIRONMENT.md`.

### Upstream PR plan

Submit a PR adding the Windows branch with the path as a configurable
module attribute, plus documentation explaining how to set it. Lower
priority than the other forks since it's more of a "your config goes
here" fix than a real porting issue.

---

## 6. wx_mvu — `C:\build\wx_mvu`

**Upstream:** <https://github.com/HeroesLament/wx_mvu>  
**Note:** This is **our own library**, not someone else's. The fork is
just where we develop changes before pushing back.  
**Why we forked here:** Three distinct fixes, all motivated by getting
MinuteModem's UI rendering correctly on wxMSW.

### Changes

| File | Change |
|------|--------|
| `lib/wx_mvu.ex` | Moved from project root to `lib/wx_mvu.ex`. Standard Elixir layout. |
| `lib/wx_mvu/renderer/intents/panel.ex` | Fixed `:wxSizer.add` keyword form to list-of-tuples form. The keyword form silently dropped `proportion`; the list-of-tuples form is unambiguous. |
| `lib/wx_mvu/renderer/intents/layout.ex` | Same `:wxSizer.add` fix in 4 sites. Plus added `propagate_layout_up/1` which walks the parent chain calling `:wxWindow.layout/1` at each level. wxMSW (Windows backend) is strict about layout propagation; without this, child panels in tabbed notebooks render as 20×0 sliver. wxOSX (macOS) is more forgiving and didn't show the bug. |

### Why the 20×0 GLCanvas?

The cascade was: notebook → page panel → ops_root panel → spectrogram
GLCanvas. Each level had its own sizer with `proportion: 1, flag: :expand`.
The keyword form of `:wxSizer.add` silently ignored `proportion`,
defaulting it to 0 ("don't grow"). On macOS this still worked because
wxOSX's auto-layout fills available space; on Windows, the sizers
respected the broken `proportion: 0` and gave the canvas no room.

Even after fixing the keyword/list-of-tuples issue, wxMSW required
`:wxWindow.layout/1` to be called on each parent in the chain when
a child's content changes. That's what `propagate_layout_up/1` does.

### Upstream PR plan

These are our own changes; no upstream to PR. They've been pushed
back to <https://github.com/HeroesLament/wx_mvu> via direct commit.

---

## Maintenance

When updating any fork:

1. Pull upstream changes (or rebase) into the local fork.
2. Resolve any conflicts with our changes.
3. From the umbrella root, force-recompile that dep:

   ```cmd
   mix deps.compile <fork_name> --force
   ```

4. Build a release and verify it still works:

   ```cmd
   mix release minutemodem_station --overwrite
   ```

5. Push the fork's branch.

When a fix gets accepted upstream:

1. Pull from upstream master.
2. Verify our local branch is now ancestor of master (i.e. the upstream
   merge contains our changes).
3. Switch the umbrella's `mix.exs` to use the upstream version
   (`{:foo, "~> X.Y"}`), removing the `path:` override.
4. Test thoroughly — the upstream merge may have introduced changes
   beyond just our PR.
5. Eventually decommission the local fork directory.

## Build verification

After any fork change, this is the standard end-to-end verification:

```cmd
cd C:\build\minutemodem
set "MIX_ENV=prod"
set "MM_UNLOCKED=true"
mix deps.compile <fork_name> --force
mix release minutemodem_station --overwrite
installer\build_msi.bat
msiexec /x C:\build\minutemodem\installer\dist\MinuteModem-0.1.0.msi /quiet
ping -n 11 127.0.0.1 >nul
rmdir /s /q "C:\Program Files (x86)\MinuteModem" 2>nul
msiexec /i C:\build\minutemodem\installer\dist\MinuteModem-0.1.0.msi INSTALLFOLDER="C:\Program Files (x86)\MinuteModem" /quiet
ping -n 31 127.0.0.1 >nul
"C:\Program Files (x86)\MinuteModem\bin\minutemodem_station.bat" start_iex
```

If the iex prompt opens, audio pipeline boots, scenes render, and no
NIF load errors appear in the logs — the fork is working.
