defmodule MinuteModem.MixProject do
  use Mix.Project

  def project do
    [
      name: "MinuteModem",
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: ["lib"],
      releases: releases()
    ]
  end

  defp releases do
    [
      minutemodem_station: [
        applications: [
          crypto: :permanent,
          asn1: :permanent,
          public_key: :permanent,
          ssl: :permanent,
          minutemodem_core: :permanent,
          minutemodem_ui: :permanent,
          license_core: :permanent,
          license_tui: :permanent,
          license_ui: :permanent,
          runtime_tools: :permanent
        ],
        include_erts: true,
        strip_beams: true,
        steps: [
          :assemble,
          &copy_mesa_dlls/1,
          &strip_erts_debug/1,
          &patch_release_bat/1
        ]
      ],
      minutemodem_remote: [
        applications: [
          crypto: :permanent,
          asn1: :permanent,
          public_key: :permanent,
          ssl: :permanent,
          minutemodem_ui: :permanent,
          license_core: :permanent,
          license_tui: :permanent,
          license_ui: :permanent,
          runtime_tools: :permanent
        ],
        include_erts: true,
        strip_beams: true,
        steps: [
          :assemble,
          &copy_mesa_dlls/1,
          &strip_erts_debug/1,
          &patch_release_bat/1
        ]
      ],
      minutemodem_core: [
        applications: [
          crypto: :permanent,
          asn1: :permanent,
          public_key: :permanent,
          ssl: :permanent,
          minutemodem_core: :permanent,
          license_core: :permanent,
          license_tui: :permanent,
          runtime_tools: :permanent
        ],
        include_erts: true,
        strip_beams: true,
        steps: [:assemble, &strip_erts_debug/1, &patch_release_bat/1]
      ],
      license_api: [
        applications: [
          crypto: :permanent,
          asn1: :permanent,
          public_key: :permanent,
          ssl: :permanent,
          license_api: :permanent,
          license_core: :permanent,
          runtime_tools: :permanent
        ],
        include_erts: true,
        strip_beams: true,
        steps: [:assemble, &strip_erts_debug/1, &patch_release_bat/1]
      ]
    ]
  end

  defp deps, do: []

  # ----------------------------------------------------------------------
  # Mesa3D DLL copy step (Windows only).
  # Drops opengl32.dll, libgallium_wgl.dll, dxil.dll into ERTS bin so
  # wxGLCanvas finds Mesa3D's llvmpipe instead of GDI Generic 1.1 over RDP.
  # ----------------------------------------------------------------------

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
    erts_bin =
      Path.join([release.path, "erts-#{release.erts_version}", "bin"])

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

  # ----------------------------------------------------------------------
  # ERTS debug-file strip — removes ~95 MB of .pdb / beam.debug.* files
  # that aren't useful in end-user installs. Only fires on Windows.
  # ----------------------------------------------------------------------

  defp strip_erts_debug(%Mix.Release{} = release) do
    erts_bin =
      Path.join([release.path, "erts-#{release.erts_version}", "bin"])

    if File.dir?(erts_bin) do
      bytes_freed =
        erts_bin
        |> File.ls!()
        |> Enum.filter(&debug_file?/1)
        |> Enum.reduce(0, fn name, acc ->
          path = Path.join(erts_bin, name)
          size = File.stat!(path).size
          File.rm!(path)
          IO.puts("* stripped ERTS debug file: #{name}")
          acc + size
        end)

      IO.puts("* total ERTS debug bytes stripped: #{bytes_freed |> div(1_048_576)} MB")
    end

    release
  end

  defp debug_file?(name) do
    String.ends_with?(name, ".pdb") or
      String.starts_with?(name, "beam.debug.")
  end

  # ----------------------------------------------------------------------
  # Release post-assemble step: surgically patch the generated
  # `bin/<release>.bat` to tolerate install paths containing parentheses
  # (e.g. "Program Files (x86)").
  #
  # Background:
  #   Elixir's release.bat template uses delayed expansion (`!VAR!`)
  #   inside nested `(...)` blocks. cmd.exe parses `(...)` structure
  #   BEFORE expanding delayed variables, so when a delayed variable
  #   expands to a string containing `)` (any path with "(x86)"), cmd
  #   closes the wrong block and crashes with "was unexpected at this
  #   time". This is a well-known sharp edge of cmd.exe + delayed
  #   expansion.
  #
  #   The crash has nothing to do with our code — Elixir's template just
  #   isn't paren-safe.
  #
  # Strategy:
  #   We keep Elixir's bat as the canonical source. After :assemble we
  #   read it, identify the two paren-trap constructs, and rewrite each
  #   into goto-based equivalents that don't nest `(...)` blocks around
  #   delayed-expanded path variables. Semantics are unchanged.
  #
  # Constructs patched:
  #   1. The outer wrapper:
  #        if not "!REL_GOTO!" == "" ( ... goto !REL_GOTO! )
  #      becomes a flat sequence with a leading `if "" goto :skip`.
  #
  #   2. The inner sys.config templating:
  #        findstr ... && ( ... copy ... || (echo ... goto end) )
  #      becomes a sequence of `if errorlevel` checks and gotos.
  #
  # If Elixir's template ever changes, the regexes below will fail to
  # match and the step prints a warning. We'd rather know loudly than
  # silently fail.
  # ----------------------------------------------------------------------

  defp patch_release_bat(%Mix.Release{} = release) do
    bats =
      [
        Path.join([release.path, "bin", "#{release.name}.bat"])
      ] ++
        Path.wildcard(Path.join([release.path, "releases", "*", "*.bat"]))

    IO.puts("  [diag] patch_release_bat release.path=#{release.path}")
    IO.puts("  [diag] patch_release_bat bat_paths=#{inspect(bats)}")

    for bat_path <- bats, File.exists?(bat_path) do
      original = File.read!(bat_path)
      patched = paren_safe_rewrite(original)

      if patched != original do
        File.write!(bat_path, patched)
        rel_name =
          Path.relative_to(bat_path, release.path)

        # Verify on disk after write — make sure something else isn't
        # touching the files we just patched.
        on_disk = File.read!(bat_path)
        on_disk_has_arg_check = String.contains?(on_disk, "_arg_check_")

        IO.puts(
          "* patched #{rel_name} (path=#{bat_path}, in_memory=#{byte_size(patched)}, " <>
            "on_disk=#{byte_size(on_disk)}, has_arg_check=#{on_disk_has_arg_check})"
        )
      end
    end

    release
  end

  # Apply both rewrites. Each operates on its own narrow region. Order
  # matters: the inner findstr block lives inside the outer wrapper, so
  # we rewrite the inner one first while the outer block is still in
  # its original shape (so its boundary regex still matches).
  defp paren_safe_rewrite(content) do
    content
    |> rewrite_findstr_runtime_block()
    |> rewrite_rel_goto_wrapper()
    |> rewrite_release_vsn_for_block()
    |> rewrite_if_not_defined_blocks()
    |> rewrite_elixir_bat_startloop()
    |> rewrite_elixir_bat_arg_handlers()
  end

  # Rewrite:
  #
  #   findstr "RUNTIME_CONFIG=true" "!RELEASE_SYS_CONFIG!.config" >nul 2>&1 && (
  #     set DEFAULT_SYS_CONFIG=!RELEASE_SYS_CONFIG!
  #     set "TIMESTAMP=%TIME::=%"
  #     set RELEASE_SYS_CONFIG=!RELEASE_TMP!\!RELEASE_NAME!-!RELEASE_VSN!-!TIMESTAMP!-!RANDOM!.runtime
  #     mkdir "!RELEASE_TMP!" >nul 2>&1
  #     copy /y "!DEFAULT_SYS_CONFIG!.config" "!RELEASE_SYS_CONFIG!.config" >nul || (
  #       echo Cannot start release because it could not write to "!RELEASE_SYS_CONFIG!.config"
  #       goto end
  #     )
  #   )
  #
  # As a flat goto sequence with no nested `(`.
  defp rewrite_findstr_runtime_block(content) do
    pattern = ~r/
      [ \t]*findstr\s+"RUNTIME_CONFIG=true"\s+"!RELEASE_SYS_CONFIG!\.config"\s+>nul\s+2>&1\s+&&\s+\(\s*\r?\n
      [ \t]*set\s+DEFAULT_SYS_CONFIG=!RELEASE_SYS_CONFIG!\s*\r?\n
      [ \t]*set\s+"TIMESTAMP=%TIME::=%"\s*\r?\n
      [ \t]*set\s+RELEASE_SYS_CONFIG=!RELEASE_TMP!\\!RELEASE_NAME!-!RELEASE_VSN!-!TIMESTAMP!-!RANDOM!\.runtime\s*\r?\n
      [ \t]*mkdir\s+"!RELEASE_TMP!"\s+>nul\s+2>&1\s*\r?\n
      [ \t]*copy\s+\/y\s+"!DEFAULT_SYS_CONFIG!\.config"\s+"!RELEASE_SYS_CONFIG!\.config"\s+>nul\s+\|\|\s+\(\s*\r?\n
      [ \t]*echo\s+Cannot\s+start\s+release\s+because\s+it\s+could\s+not\s+write\s+to\s+"!RELEASE_SYS_CONFIG!\.config"\s*\r?\n
      [ \t]*goto\s+end\s*\r?\n
      [ \t]*\)\s*\r?\n
      [ \t]*\)\r?\n
    /xs

    replacement =
      """
        findstr "RUNTIME_CONFIG=true" "!RELEASE_SYS_CONFIG!.config" >nul 2>&1
        if errorlevel 1 goto runtime_config_done
        set DEFAULT_SYS_CONFIG=!RELEASE_SYS_CONFIG!
        set "TIMESTAMP=%TIME::=%"
        set RELEASE_SYS_CONFIG=!RELEASE_TMP!\\!RELEASE_NAME!-!RELEASE_VSN!-!TIMESTAMP!-!RANDOM!.runtime
        mkdir "!RELEASE_TMP!" >nul 2>&1
        copy /y "!DEFAULT_SYS_CONFIG!.config" "!RELEASE_SYS_CONFIG!.config" >nul
        if errorlevel 1 goto runtime_config_failed
        goto runtime_config_done
      :runtime_config_failed
        echo Cannot start release because it could not write to "!RELEASE_SYS_CONFIG!.config"
        goto end
      :runtime_config_done
      """

    Regex.replace(pattern, content, replacement)
  end

  # Rewrite:
  #
  #   if not "!REL_GOTO!" == "" (
  #     <body>   <-- already-rewritten findstr block lives here
  #
  #     goto !REL_GOTO!
  #   )
  #
  # Into a flat sequence with leading skip-guard:
  #
  #   if "!REL_GOTO!" == "" goto rel_goto_done
  #   <body>
  #
  #   goto !REL_GOTO!
  #   :rel_goto_done
  defp rewrite_rel_goto_wrapper(content) do
    # Match the outer block. The body matches anything up to the closing
    # `)` of the outer block, but we expect the inner findstr block to
    # already have been rewritten into goto form (no nested `(...)`).
    pattern = ~r/
      ^[ \t]*if\s+not\s+"!REL_GOTO!"\s+==\s+""\s+\(\s*\r?\n
      (.*?)
      ^[ \t]*goto\s+!REL_GOTO!\s*\r?\n
      ^[ \t]*\)\s*\r?\n
    /xms

    replacement = """
    if "!REL_GOTO!" == "" goto rel_goto_done
    \\1
    goto !REL_GOTO!
    :rel_goto_done
    """

    Regex.replace(pattern, content, replacement)
  end

  # The RELEASE_VSN defaulting line is special: it nests a `for /f` block
  # inside the `if not defined ( ... )` body, so the simple regex below
  # (which excludes nested parens) deliberately skips it. But this line
  # is the FIRST one to expand `!RELEASE_ROOT!` inside a paren block,
  # which is exactly where (x86) install paths bite us first.
  #
  # Original (one line):
  #   if not defined RELEASE_VSN (for /f "tokens=1,2" %%K in ('type "!RELEASE_ROOT!\releases\start_erl.data"') do (set ERTS_VSN=%%K) && (set RELEASE_VSN=%%L))
  #
  # Rewritten:
  #   if defined RELEASE_VSN goto _defaulted_RELEASE_VSN
  #   for /f "tokens=1,2" %%K in (...) do (set ERTS_VSN=%%K) && (set RELEASE_VSN=%%L)
  #   :_defaulted_RELEASE_VSN
  #
  # The remaining `(...)` blocks after the rewrite belong to `for /f`'s
  # own input/body parsing, which doesn't trip on path-content parens
  # because the variables expanded inside are `%%K` and `%%L` from the
  # for loop, not delayed-expanded paths.
  defp rewrite_release_vsn_for_block(content) do
    pattern = ~r/^([ \t]*)if\s+not\s+defined\s+RELEASE_VSN\s+\((.*)\)\s*\r?\n/m

    Regex.replace(pattern, content, fn _full, indent, body ->
      indent <>
        "if defined RELEASE_VSN goto _defaulted_RELEASE_VSN\r\n" <>
        indent <> String.trim_trailing(body) <> "\r\n" <>
        indent <> ":_defaulted_RELEASE_VSN\r\n"
    end)
  end

  # Rewrite each `if not defined X (set X=...)` line to a goto-based form
  # so that delayed expansion of path variables in the body cannot close
  # the `(` block prematurely.
  #
  # Original form (one line):
  #   if not defined X (set X=...)
  #
  # Rewritten form:
  #   if defined X goto _defaulted_X
  #   set X=...
  #   :_defaulted_X
  #
  # We only target lines whose body has no nested `(` or `)` — that
  # excludes the rare `for /f` defaulting line, whose body uses parens
  # for its own structural reasons. The simple-bodied lines are where
  # the (x86) bug actually bites, since they're the ones that expand
  # `!REL_VSN_DIR!` and friends.
  defp rewrite_if_not_defined_blocks(content) do
    pattern = ~r/^([ \t]*)if\s+not\s+defined\s+(\w+)\s+\(([^()\r\n]+)\)\s*\r?\n/m

    Regex.replace(pattern, content, fn _full, indent, var, body ->
      label = "_defaulted_#{var}"

      indent <>
        "if defined #{var} goto #{label}\r\n" <>
        indent <> String.trim_trailing(body) <> "\r\n" <>
        indent <> ":#{label}\r\n"
    end)
  end

  # ----------------------------------------------------------------------
  # Patch elixir.bat's argument-parsing loop, which assigns `par` from
  # `%~1` and then tests `if "!par!"=="" (...)`. When `!par!` expands to
  # a path containing `(x86)`, cmd's `if` parser splits the comparison
  # value at the `(`, and the script crashes.
  #
  # Original:
  #   :startloop
  #   set "par=%~1"
  #   if "!par!"=="" (
  #     rem skip if no parameter
  #     goto run
  #   )
  #
  # Rewritten:
  #   :startloop
  #   if "%~1"=="" goto run
  #   set "par=%~1"
  #
  # `%~1` is the unexpanded literal arg, which cmd's `if` quotes
  # without expansion shenanigans. Logic is unchanged.
  # ----------------------------------------------------------------------

  defp rewrite_elixir_bat_startloop(content) do
    # Match the pattern very loosely — anything between :startloop and the
    # `goto run` line, as long as we see the broken `if "!par!"==""` test.
    pattern = ~r/:startloop\s*\nset\s+"par=%~1"\s*\nif\s+"!par!"==""\s+\(\s*\n[^)]*\bgoto\s+run\s*\n\s*\)\s*\n/

    replacement =
      ":startloop\nif \"%~1\"==\"\" goto run\nset \"par=%~1\"\n"

    result = Regex.replace(pattern, content, replacement)

    if result == content and String.contains?(content, ":startloop") do
      IO.puts(
        "  [diag] rewrite_elixir_bat_startloop: file has :startloop but " <>
          "regex didn't match — bat structure may differ from expected"
      )
    end

    result
  end

  # ----------------------------------------------------------------------
  # Patch elixir.bat's argument-handler lines.
  #
  # Original form:
  #   if ""==!par:--XYZ=! (BODY)
  #
  # The BODY contains `"%~1"` which expands to the value of the next CLI
  # argument. When that argument is a path containing `(x86)`, the `)`
  # in the path closes the outer `(` block early and cmd dies parsing.
  #
  # Rewritten form:
  #   if not ""==!par:--XYZ=! goto _next_arg_check_<N>
  #   BODY (unwrapped, no parens)
  #   :_next_arg_check_<N>
  #
  # We assign label numbers monotonically so each rewrite gets a unique
  # one. The transformation is purely structural: the body runs only when
  # the test passes, same as the original.
  # ----------------------------------------------------------------------

  defp rewrite_elixir_bat_arg_handlers(content) do
    pattern = ~r/^([ \t]*)if\s+""==!par:([^!]+)!\s+\(([^()\r\n]+)\)\s*\r?\n/m

    scan_count = pattern |> Regex.scan(content) |> length()

    if String.contains?(content, "!par:") do
      IO.puts("  [diag] rewrite_elixir_bat_arg_handlers: found #{scan_count} arg-handler matches")
    end

    Process.put(:arg_handler_idx, 0)

    result =
      Regex.replace(pattern, content, fn _full, indent, suffix, body ->
        idx = Process.get(:arg_handler_idx, 0)
        Process.put(:arg_handler_idx, idx + 1)

        label =
          "_arg_check_#{idx}_" <>
            (suffix |> String.replace(~r/[^A-Za-z0-9]/, "_") |> String.trim_trailing("_"))

        replacement_text =
          indent <>
            "if not \"\"==!par:#{suffix}! goto #{label}\r\n" <>
            indent <> String.trim_trailing(body) <> "\r\n" <>
            indent <> ":#{label}\r\n"

        if idx == 0 do
          IO.puts("  [diag] arg_handler[0] suffix=#{inspect(suffix)} body_len=#{byte_size(body)}")
          IO.puts("  [diag] arg_handler[0] replacement preview:")
          replacement_text |> String.slice(0, 200) |> IO.puts()
        end

        replacement_text
      end)

    Process.delete(:arg_handler_idx)

    if String.contains?(content, "!par:--boot") do
      orig_size = byte_size(content)
      new_size = byte_size(result)
      IO.puts("  [diag] arg_handlers content size: orig=#{orig_size} new=#{new_size}")
      IO.puts("  [diag] arg_handlers contains _arg_check_: #{String.contains?(result, "_arg_check_")}")
    end

    result
  end
end
