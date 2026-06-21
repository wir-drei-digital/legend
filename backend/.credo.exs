# Credo configuration. See `mix help credo` and https://hexdocs.pm/credo.
#
# Checks come from three sources, merged together:
#   1. Credo's built-in default checks (no explicit `checks:` block here, so
#      the full default set runs — adding an explicit list would SHADOW the
#      plugin-contributed checks below).
#   2. ExSlop  — AI-slop detection checks (https://github.com/elixir-vibe/ex_slop).
#   3. AshCredo — Ash-framework checks (https://ash-credo.hexdocs.pm).
#
# Both plugins inject their checks via `checks: %{extra: ...}`, so to tune a
# specific check, add it under a `checks:` map using `enabled:`/`disabled:` (the
# map form merges with the plugin extras; a bare list would replace them). Run
# `mix credo.gen.config` if you want the full annotated default check list.
%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/"],
        excluded: [~r"/_build/", ~r"/deps/", ~r"/node_modules/"]
      },
      plugins: [
        {ExSlop, []},
        {AshCredo, []}
      ],
      strict: false,
      parse_timeout: 5000,
      color: true
    }
  ]
}
