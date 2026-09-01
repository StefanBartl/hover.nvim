---@module 'scripts.gen_map'
--- CLI entry point for hover.nvim's module map.
---
---   nvim --headless -l scripts/gen_map.lua                    # regenerate
---   nvim --headless -l scripts/gen_map.lua --check            # verify, write nothing
---   nvim --headless -l scripts/gen_map.lua --check --lenient  # fail on staleness only
---   nvim --headless -l scripts/gen_map.lua --full             # + LuaLS enrichment
---
--- Everything above the options table is copied verbatim from
--- documentation.nvim's `scripts/gen_map.lua`; see its docs/REUSE.md.
---
--- `docs/map/` is gitignored, so `--check` is deliberately NOT run in CI: it
--- compares the freshly generated map against the files on disk, and on a
--- fresh checkout there are none -- the comparison would then fail on every
--- run regardless of the actual state of the code.

local root = vim.uv.cwd():gsub("\\", "/"):gsub("/+$", "")
vim.opt.runtimepath:prepend(root)

--- Put a dependency on the runtimepath, if it is not already reachable.
---
--- A headless `nvim -l` run starts with no plugin manager, so nothing beyond
--- `root` is on the rtp -- `documentation` and `lib.nvim` both have to be
--- found by hand. Three candidates, in descending order of explicitness: an
--- environment variable (what CI sets), a `.deps/` checkout (what CI clones
--- into), and a sibling checkout (what a local development tree looks like).
---@param modname string A module the dependency provides, used as the probe.
---@param dirname string Repository directory name.
local function ensure(modname, dirname)
  if pcall(require, modname) then
    return
  end
  -- Built with explicit indices, not a `{a, b, c}` literal fed to `ipairs`:
  -- the environment-variable candidate is `nil` whenever it is unset -- the
  -- normal case for CI, which relies on the `.deps/<dirname>` candidate below
  -- instead -- and a table literal with `nil` in its first slot makes
  -- `ipairs` stop immediately without ever inspecting the slots after it,
  -- silently skipping every other candidate regardless of whether the
  -- directory actually exists.
  local candidates = {}
  local env_dir = vim.env[dirname:upper():gsub("[.-]", "_") .. "_DIR"]
  if env_dir and env_dir ~= "" then
    candidates[#candidates + 1] = env_dir
  end
  candidates[#candidates + 1] = root .. "/.deps/" .. dirname
  candidates[#candidates + 1] = vim.fs.dirname(root) .. "/" .. dirname
  for _, dir in ipairs(candidates) do
    if vim.fn.isdirectory(dir) == 1 then
      vim.opt.runtimepath:prepend(dir)
      if pcall(require, modname) then
        return
      end
    end
  end
  io.stderr:write(("gen_map: %s not found (probed require('%s')).\n"):format(dirname, modname))
  io.stderr:write(
    ("  Set %s_DIR, clone it to .deps/%s, or check it out beside this repo.\n"):format(
      dirname:upper():gsub("[.-]", "_"),
      dirname
    )
  )
  os.exit(1)
end

ensure("lib.nvim.fs.read", "lib.nvim")
ensure("documentation.core.cli", "documentation.nvim")

local opts = require("documentation.config").build(root, {
  source = "lua/hover",
  title = "hover.nvim",
  out_dir = "docs/map",
  repo_url = "https://github.com/StefanBartl/hover.nvim",
  branch = "main",

  -- Three invariants that would otherwise rot in silence. Each is stated as a
  -- design rule in the module headers; without a check, a rule in prose is a
  -- statement of intent and nothing more.
  layers = {
    -- `classify` is pure: a target string in, a typed target out, with no I/O
    -- beyond one `fs_stat`. The moment it reads configuration, the decision
    -- about what a target IS starts depending on what is switched on, and the
    -- same text classifies differently in two sessions.
    {
      from = "hover.classify",
      to = "hover.config",
      why = "classification is pure -- what a target is does not depend on what is switched on",
    },
    -- The switch table drives the routes, not the other way round. A switch
    -- reaching back into the command layer would mean adding one requires
    -- touching both, which is exactly the drift the single table prevents.
    {
      from = "hover.switches",
      to = "hover.bindings.usrcmds",
      why = "the switch table drives the command routes, never the reverse",
    },
    -- The previewers take their options as an argument (`Hover.PreviewOpts`)
    -- and never look them up. That is what keeps every preview testable
    -- without a configured session.
    {
      from = "hover.preview",
      to = "hover.config",
      why = "previewers take their options as an argument instead of reading configuration",
    },
  },
})

local code = require("documentation.core.cli").run(opts, _G.arg or {})
vim.cmd("cq " .. code)
