-- TESTS/minimal_init.lua -- puts this plugin and its dependencies on the runtimepath.
--
--   nvim -n -i NONE --headless -u TESTS/minimal_init.lua ...
--
-- It runs nothing itself. A dependency that cannot be found is FATAL (NEW-40): the message names
-- all four places that were searched and the process exits with code 1, so that a run which could
-- not load its dependency never looks green. Each dependency <name> is looked up in, in this order:
--   1. $<NAME>_DIR                  (lib.nvim -> $LIB_NVIM_DIR)
--   2. <repo>/.deps/<name>          (what CI checks out)
--   3. <repo>/../<name>             (a sibling checkout)
--   4. stdpath('data')/lazy/<name>  (what a plugin manager installed)
-- An override (1) that is set but wrong decides alone; it is never skipped.

local this = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(this)))

local DEPS = { "testing.nvim", "lib.nvim", "ui.nvim" }

---@type table<string, string>
local MARKERS = { ["lib.nvim"] = "lua/lib/nvim", ["testing.nvim"] = "lua/testing" }

---@param name string
---@return string
local function env_name(name)
  return (name:upper():gsub("[^%w]", "_")) .. "_DIR"
end

---@param dir string|nil
---@param marker string
---@return boolean
local function valid(dir, marker)
  return dir ~= nil and dir ~= "" and vim.fn.isdirectory(dir .. "/" .. marker) == 1
end

local found, failures = {}, {}
for _, name in ipairs(DEPS) do
  local marker = MARKERS[name] or "lua"
  local override = vim.env[env_name(name)]
  local places = {
    { "$" .. env_name(name), override },
    { (".deps/%s"):format(name), root .. "/.deps/" .. name },
    { ("../%s"):format(name), vim.fs.dirname(root) .. "/" .. name },
    {
      ("stdpath('data')/lazy/%s"):format(name),
      vim.fs.normalize(vim.fn.stdpath("data")) .. "/lazy/" .. name,
    },
  }
  local hit
  if override ~= nil and override ~= "" then
    if valid(override, marker) then
      hit = override
    end
  else
    for i = 2, #places do
      if valid(places[i][2], marker) then
        hit = places[i][2]
        break
      end
    end
  end
  if hit then
    found[name] = hit
  else
    local lines = { ("error: dependency '%s' not found. Searched, in this order:"):format(name) }
    for i, p in ipairs(places) do
      lines[#lines + 1] = ("  %d. %s (%s)"):format(i, p[1], p[2] or "unset")
    end
    lines[#lines + 1] = ("Set $%s, or clone it to .deps/%s, or place it beside this repo."):format(
      env_name(name),
      name
    )
    failures[#failures + 1] = table.concat(lines, "\n")
  end
end

if #failures > 0 then
  io.stderr:write(table.concat(failures, "\n"), "\n")
  os.exit(1)
end

vim.opt.rtp:prepend(root)
for _, name in ipairs(DEPS) do
  vim.opt.rtp:append(found[name])
end

-- Carried over from scripts/minimal_init.lua (removed by the migration): what the suite needs
-- besides the runtimepath. Review each block; the diff of the removed file shows all of it.

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

-- ui.nvim is optional in the plugin itself (status_view.lua pcalls ui.kit
-- and hover.nvim falls back to a plain message without it), but
-- TESTS/status_view_spec.lua asserts the board actually opens, so the suite
-- cannot pass without it -- same treatment as lib.nvim above.
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
--- `status_view_spec` -- and which one the old runner schedules first differs per
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

-- Swap and shada stay off for the whole suite, including the old runner's child
-- processes that reuse this file: stale swap files fail suites with E326.
vim.o.swapfile = false
vim.o.shadafile = "NONE"

return { root = root, deps = found }
