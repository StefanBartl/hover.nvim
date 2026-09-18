-- scripts/minimal_init.lua -- headless test bootstrap for hover.nvim.
--
-- Run from the repo root:
--   nvim --clean --headless -u scripts/minimal_init.lua \
--     -c "PlenaryBustedDirectory TESTS/ { minimal_init = 'scripts/minimal_init.lua', sequential = true }"
--
-- (scripts/test.sh wraps exactly that.) `-u` rather than `-c luafile` after
-- startup matters: 'runtimepath' additions must land before Neovim's own
-- plugin/ scan, which is what registers plenary's :PlenaryBusted* commands in
-- the first place -- appending rtp afterwards leaves those commands
-- undefined. `--clean` matters too: without it 'runtimepath' still defaults to
-- stdpath('config')/stdpath('data') -- a real user's own Neovim config,
-- plugins and all -- which is not what a CI run (or anyone else's machine)
-- should be exercising.
vim.opt.rtp:append(vim.fn.getcwd())

--- lib.nvim is a *hard* runtime dependency here (notify, bindings.autocmd,
--- debounce, image_preview, net.curl, memo.lru, strings.width): hover.nvim's
--- own modules `require("lib.*")` with no fallback, so the specs cannot run
--- without it on the rtp. plenary.nvim is the busted-compatible harness the
--- specs are written against.
---
--- Three ways each can be found, in descending order of explicitness: an
--- explicit env var (`LIB_NVIM_DIR`/`PLENARY_DIR`), a `.deps/<name>` checkout
--- (what CI uses -- see .github/workflows/ci.yml), or a sibling checkout next
--- to this repo (`../lib.nvim`, `../plenary.nvim`) for a contributor who
--- already has both cloned that way.
---
--- On failure it names all three and exits 1. A test bootstrap that gives up
--- quietly is worse than one that fails: the specs then report `module '...'
--- not found`, which looks like a defect in the code just changed (`NEW-40`).
---@param env_var string
---@param deps_name string
---@param marker string module `require()`d to confirm the directory is right
local function add_dep(env_var, deps_name, marker)
  if pcall(require, marker) then
    return
  end
  local candidates = {}
  local env_val = vim.env[env_var]
  if env_val and env_val ~= "" then
    candidates[#candidates + 1] = env_val
  end
  candidates[#candidates + 1] = vim.fn.getcwd() .. "/.deps/" .. deps_name
  candidates[#candidates + 1] = vim.fs.dirname(vim.fn.getcwd()) .. "/" .. deps_name
  for _, dir in ipairs(candidates) do
    if dir and vim.fn.isdirectory(dir) == 1 then
      vim.opt.rtp:append(dir)
      if pcall(require, marker) then
        return
      end
    end
  end
  io.stderr:write(("scripts/minimal_init.lua: %s not found.\n"):format(deps_name))
  io.stderr:write(
    ("  Set %s, or clone it to .deps/%s, or place it beside this repo.\n"):format(
      env_var,
      deps_name
    )
  )
  os.exit(1)
end

--- images.nvim is *optional*, unlike the two above, and the difference is
--- deliberate: hover.nvim runs without it, and only the zoom specs need it --
--- only for the half that shells out to ImageMagick. Absent, those skip and
--- say so, the same stance images.nvim takes in its own `convert_spec`. A
--- missing optional dependency must not fail a run the way a missing harness
--- does (`NEW-40` is about the harness).
--- **The candidate list is built rather than written as a literal, and that is
--- not a style choice.** It was a literal whose first entry was
--- `vim.env[env_var]`, and with the variable unset that is a `nil` at index 1
--- -- a hole, which `ipairs` stops at immediately. The loop below ran **zero**
--- times, so neither the `.deps/` checkout nor the sibling was ever tried, and
--- images.nvim was found only by anyone who happened to have the environment
--- variable exported. `#t` reports 3 for `{ nil, "a", "b" }` while `ipairs`
--- yields nothing, which is why it reads as a three-element list.
---
--- `add_dep` above builds its list the careful way and always did. This one
--- did not, and the two were written the same afternoon.
---@param env_var string
---@param deps_name string
---@param marker string
local function add_optional(env_var, deps_name, marker)
  if pcall(require, marker) then
    return
  end
  local candidates = {}
  local env_val = vim.env[env_var]
  if env_val and env_val ~= "" then
    candidates[#candidates + 1] = env_val
  end
  candidates[#candidates + 1] = vim.fn.getcwd() .. "/.deps/" .. deps_name
  candidates[#candidates + 1] = vim.fs.dirname(vim.fn.getcwd()) .. "/" .. deps_name

  for _, dir in ipairs(candidates) do
    if dir and dir ~= "" and vim.fn.isdirectory(dir) == 1 then
      vim.opt.rtp:append(dir)
      if pcall(require, marker) then
        return
      end
    end
  end
end

add_dep("LIB_NVIM_DIR", "lib.nvim", "lib.nvim.notify")
-- ui.nvim is optional in the plugin itself (status_view.lua pcalls ui.kit
-- and hover.nvim falls back to a plain message without it), but
-- TESTS/status_view_spec.lua asserts the board actually opens, so the suite
-- cannot pass without it -- same treatment as lib.nvim above.
add_dep("UI_NVIM_DIR", "ui.nvim", "ui.kit")
add_dep("PLENARY_DIR", "plenary.nvim", "plenary")
add_optional("IMAGES_NVIM_DIR", "images.nvim", "images.convert")

--- No first-run popup during a test run, and the reason is a red macOS leg
--- rather than tidiness.
---
--- `hover.setup()` calls `lib.nvim.deps.show_once("hover.nvim")`, which opens
--- a floating window listing the declared external tools that are missing --
--- deliberately through `vim.schedule`, so it lands on the *next* event-loop
--- tick rather than inline. A spec that calls `setup()` and then waits gets
--- that float inside its own wait, out of nowhere, and
--- `TESTS/status_view_spec.lua` read it as the dwell tooltip firing 1.8
--- seconds early.
---
--- Two things made it look like a macOS bug. It shows only where a declared
--- tool is actually missing, which is a property of the runner, not of the
--- code; and it is marked seen on disk
--- (`stdpath("cache")/lib.nvim/cache/lib.nvim.deps.first_run.json`), once per
--- cache directory, so only the *first* spec child in a whole run can see it
--- at all. Two spec files call `setup()` -- `registry_spec` and
--- `status_view_spec` -- and which one plenary schedules first differs per
--- platform: `registry_spec` went first on Linux and Windows and quietly
--- absorbed the popup, `status_view_spec` went first on macOS and asserted
--- against it.
---
--- `vim.g.lib_nvim_deps_disable_first_run` is that popup's own documented
--- opt-out, and it is the right one here for a second reason: it declines
--- *without* marking anything seen. Running the suite therefore no longer
--- consumes the contributor's real first-run popup for hover.nvim in their
--- own Neovim, which it had been doing every time.
vim.g.lib_nvim_deps_disable_first_run = true
