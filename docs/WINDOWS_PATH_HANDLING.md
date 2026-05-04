# Windows Parenthesized Path Handling

This document describes how MinuteModem makes Elixir releases robust to
Windows install paths containing parentheses — most notably
`C:\Program Files (x86)\`, the default 32-bit Program Files location, and
any user-chosen path that includes `(` or `)`.

## The Problem

Elixir's `mix release` task generates Windows batch files
(`bin/<release>.bat`, `releases/<vsn>/elixir.bat`, `releases/<vsn>/iex.bat`)
that drive the Erlang VM at runtime. These templates are written using
**delayed expansion** (the `!VAR!` syntax inside `setlocal enabledelayedexpansion`
blocks) and frequently nest variable expansions inside `(...)` blocks.

`cmd.exe` parses the structure of `(...)` blocks **before** expanding
delayed variables. When a delayed variable expands to a string containing
a literal `)` — which happens any time a path variable contains
`(x86)` — cmd's paren-matcher closes the wrong block. The script aborts
with cryptic errors like:

```
\MinuteModem\releases\0.1.0\sys"" was unexpected at this time.
```

This isn't a bug in MinuteModem. It's a long-standing sharp edge in
Elixir's bat templates that bites any release installed to a path
containing parentheses. Most Elixir users never hit it because they
either (a) never make a release, (b) install to a path without parens,
or (c) deploy to Linux. We hit it because we ship a Windows MSI, and
respecting the user's chosen install path means accepting whatever
Windows says is "Program Files".

## The Fix

We do **not** modify Elixir itself. Instead, the umbrella's `mix.exs`
adds a release step that **patches the generated bat files in place**
after `:assemble`. The patcher transforms specific paren-trap constructs
into goto-based equivalents that cmd's structure-parser can handle
regardless of what delayed-expanded variables contain.

The transformations preserve identical semantics — same control flow,
same side effects, same exit conditions. They only restructure how the
flow is expressed in batch syntax.

### Configuration

In the umbrella's `mix.exs`, every release config that includes a `.bat`
launcher (i.e. all of them, on Windows) has a `:steps` list that ends
with the patcher:

```elixir
minutemodem_station: [
  applications: [...],
  include_erts: true,
  strip_beams: true,
  steps: [
    :assemble,
    &copy_mesa_dlls/1,
    &strip_erts_debug/1,
    &patch_release_bat/1
  ]
]
```

### The Patcher

`patch_release_bat/1` walks every `.bat` file under the release tree:

- `bin/<release>.bat` — the user-facing launcher
- `releases/<vsn>/elixir.bat` — Elixir's CLI argument parser
- `releases/<vsn>/iex.bat` — IEx's wrapper around elixir.bat
- `releases/<vsn>/env.bat` — user-overridable defaults

Each file is read, run through `paren_safe_rewrite/1`, and written back
if the content changed.

### Five Paren-Trap Constructs Rewritten

The rewrite chain composes five focused regex transformations, each
targeting one specific construct in Elixir's bat templates.

#### 1. `if not "!REL_GOTO!" == "" (...)` outer wrapper

Original (in `bin/<release>.bat`):

```bat
if not "!REL_GOTO!" == "" (
  ... runtime config templating ...
  goto !REL_GOTO!
)
```

Rewritten:

```bat
if "!REL_GOTO!" == "" goto rel_goto_done
... runtime config templating ...
goto !REL_GOTO!
:rel_goto_done
```

#### 2. `findstr ... && (...)` runtime config block

Original:

```bat
findstr "RUNTIME_CONFIG=true" "!RELEASE_SYS_CONFIG!.config" >nul 2>&1 && (
  set DEFAULT_SYS_CONFIG=!RELEASE_SYS_CONFIG!
  ...
  copy /y "!DEFAULT_SYS_CONFIG!.config" "!RELEASE_SYS_CONFIG!.config" >nul || (
    echo Cannot start release because it could not write to "!RELEASE_SYS_CONFIG!.config"
    goto end
  )
)
```

Rewritten as a flat `if errorlevel` chain with goto labels — no nested
parens around path variables.

#### 3. `if not defined RELEASE_VSN (for /f ... do (...))` defaulting

Original:

```bat
if not defined RELEASE_VSN (for /f "tokens=1,2" %%K in ('type "!RELEASE_ROOT!\releases\start_erl.data"') do (set ERTS_VSN=%%K) && (set RELEASE_VSN=%%L))
```

The outer `if not defined ( ... )` wraps a `for /f` whose input file
path expands `!RELEASE_ROOT!`. With `(x86)` in the path, the outer
block closes early.

Rewritten:

```bat
if defined RELEASE_VSN goto _defaulted_RELEASE_VSN
for /f "tokens=1,2" %%K in ('type "!RELEASE_ROOT!\releases\start_erl.data"') do (set ERTS_VSN=%%K) && (set RELEASE_VSN=%%L)
:_defaulted_RELEASE_VSN
```

The `for /f`'s own `(...)` blocks remain — those are fine because their
expansions are loop variables (`%%K`, `%%L`), not delayed-expanded paths.

#### 4. `if not defined X (set X=!Y!\suffix)` env defaulting

Many lines in the prologue follow this pattern:

```bat
if not defined RELEASE_TMP (set RELEASE_TMP=!RELEASE_ROOT!\tmp)
if not defined RELEASE_VM_ARGS (set RELEASE_VM_ARGS=!REL_VSN_DIR!\vm.args)
if not defined RELEASE_SYS_CONFIG (set RELEASE_SYS_CONFIG=!REL_VSN_DIR!\sys)
... etc ...
```

Each one expands a path variable inside `(...)`. The patcher rewrites
each as:

```bat
if defined RELEASE_TMP goto _defaulted_RELEASE_TMP
set RELEASE_TMP=!RELEASE_ROOT!\tmp
:_defaulted_RELEASE_TMP
```

#### 5. elixir.bat's `:startloop` parameter loop

Original:

```bat
:startloop
set "par=%~1"
if "!par!"=="" (
  rem skip if no parameter
  goto run
)
```

The `if "!par!"==""` test compares `par`'s value (which becomes a
path argument). When that path contains `(x86)`, the `if`'s comparison
parsing breaks.

Rewritten:

```bat
:startloop
if "%~1"=="" goto run
set "par=%~1"
```

`%~1` is the literal arg as cmd received it — quoted properly, no
delayed-expansion gotchas.

#### 6. elixir.bat's argument handlers (27 of them)

Every line that handles a CLI flag taking a value:

```bat
if ""==!par:--boot=!                (set "parsErlang=!parsErlang! -boot "%~1"" && shift && goto startloop)
if ""==!par:--erl-config=!          (set "parsErlang=!parsErlang! -config "%~1"" && shift && goto startloop)
... etc ...
```

The body contains `"%~1"` — when expanded for `--erl-config`, that
becomes `"C:\Program Files (x86)\MinuteModem\releases\0.1.0\sys"`. The
`(x86)` closes the outer `(` block.

Each handler is rewritten as:

```bat
if not ""==!par:--boot=! goto _arg_check_2___boot
set "parsErlang=!parsErlang! -boot "%~1"" && shift && goto startloop
:_arg_check_2___boot
```

The label is generated from the flag name plus a unique counter, ensuring
no label collisions across the 27 rewrites.

## Why This Approach

There were three options:

1. **Refuse to support paths with parens** — tell users to install
   somewhere "safe". Rejected because Windows itself defaults to
   `Program Files (x86)` for 32-bit installers, and we have to respect
   user choice.

2. **Replace the bat files entirely** with our own templates. Rejected
   because Elixir's templates handle a lot of subtle cases (cookies,
   distribution flags, runtime config templating, etc.) that we'd have
   to re-implement and keep up to date with upstream changes.

3. **Surgically patch the upstream templates after they're generated**.
   Chosen. The patches are narrow regex transformations targeting
   specific known-broken constructs. If Elixir's templates change
   shape, the regexes won't match and we'll get a clear failure rather
   than silent breakage.

## Failure Modes

The patcher is **defensive**: each rewrite checks whether its target
pattern actually exists. If a future Elixir version restructures the
bat templates, individual rewrites will simply not match — the bat
gets passed through unchanged for those constructs, and we'll see the
old paren-trap errors at runtime. That's a loud failure, easy to
diagnose: re-examine the generated bat, find the new construct, add a
new regex rewrite to handle it.

The patcher **does not** silently substitute heuristic content. Every
transformation is anchored to a specific structural pattern that
matches one and only one construct.

## Maintenance

If `mix release` ever stops producing the expected paren-trap constructs
(e.g. Elixir upstream fixes them), the patcher's regexes will fail to
match, and the bat files will pass through unchanged. That's the
correct behavior: nothing to patch means nothing to do. The patcher
costs nothing when it has nothing to do.

If new paren-trap constructs appear in future Elixir versions, follow
the existing pattern:

1. Identify the broken construct via `@echo on` debugging — copy the
   bat to a debug name, replace `@echo off` with `@echo on`, run with
   the actual launch arguments. The line printed immediately before
   "was unexpected at this time" is the breaker.
2. Write a regex that matches just that construct.
3. Write a goto-based rewrite that preserves semantics.
4. Add it to the `paren_safe_rewrite/1` pipeline.
5. Verify with the same `@echo on` trick that the new bat reaches the
   end of its execution without parser errors.

## Upstream Status

This issue should be reported to the Elixir core team. The fix is well
understood (this document), the fix is mechanically applicable to the
template generation in `lib/mix/lib/mix/release.ex`, and it would benefit
every Elixir Windows MSI shipper. Worth opening an issue at
<https://github.com/elixir-lang/elixir/issues> describing the problem
with a minimal reproduction (a release installed to `C:\Test (x86)\app\`
producing the parser error). If maintainers agree, propose patches.

For now, MinuteModem owns the workaround in its own `mix.exs` and ships
working MSI installers regardless of where the user installs.

## Files Touched

- `mix.exs` — `paren_safe_rewrite/1` and its component rewrites,
  plus the `&patch_release_bat/1` step in each release's `:steps` list.

## Files Generated

- `_build/<env>/rel/<release>/bin/<release>.bat` — patched
- `_build/<env>/rel/<release>/releases/<vsn>/elixir.bat` — patched
- `_build/<env>/rel/<release>/releases/<vsn>/iex.bat` — passed through
  (no paren traps in its template)
- `_build/<env>/rel/<release>/releases/<vsn>/env.bat` — passed through
  (no paren traps in its template)

## Verification

After `mix release minutemodem_station --overwrite`, the source release
tree's `releases/<vsn>/elixir.bat` should contain:

```bat
:startloop
if "%~1"=="" goto run
set "par=%~1"
```

(instead of the original three-line `if "!par!"==""` block) and ~27
`:_arg_check_*` labels (one per CLI arg handler).

After install, the same is true at
`C:\Program Files (x86)\MinuteModem\releases\<vsn>\elixir.bat`, and
`bin\minutemodem_station.bat start_iex` from that directory boots the
release without parser errors.
