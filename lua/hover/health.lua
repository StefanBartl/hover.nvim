---@module 'hover.health'
---@brief `:checkhealth hover`.
---@description
--- Checks truth, not presence (`REL-17`). Three kinds of question:
---
---  1. **Is the hard dependency really there?** `lib.nvim` is required
---     without a fallback, so a missing one is an error, not a note -- and
---     saying so here beats a stack trace on the first `CursorHold`.
---  2. **Does each soft dependency actually answer?** There is one check per
---     `pcall(require, ...)` the code performs, and each asks for the entry
---     point that is actually called rather than just whether the module
---     loads. A plugin that is installed but too old to have
---     `images.anchor` degrades exactly like a missing one, and only a check
---     that asks for the function can tell you which it is.
---  3. **Is the configuration self-consistent?** The two combinations that
---     silently do nothing -- "manual mode with no key to trigger it" and
---     "everything switched off" -- are reported here, because nothing on
---     screen distinguishes them from a broken plugin.
---
---@see hover.switches
---@see hover.config

local M = {}

local health = vim.health

---@internal
--- Report a soft dependency: installed and answering, installed but not
--- answering, or absent -- three states, three different messages, because
--- they need three different fixes.
---@param module string module to `require`
---@param entry string|nil function the code actually calls on it
---@param what string what this plugin loses without it
---@return nil
local function soft(module, entry, what)
  local ok, mod = pcall(require, module)
  if not ok or type(mod) ~= "table" then
    health.info(("%s: not installed -- %s"):format(module, what))
    return
  end
  if entry and type(mod[entry]) ~= "function" then
    health.warn(
      ("%s: installed, but %s.%s is missing -- %s"):format(module, module, entry, what),
      { "Update the plugin; this entry point is what hover.nvim calls." }
    )
    return
  end
  health.ok(("%s: available"):format(module))
end

---@internal
--- The hard dependency, and the specific modules of it this plugin uses. A
--- present-but-partial lib.nvim is a real state (it is pinned by commit in
--- every consumer's lockfile), and it fails at the first hover rather than
--- at load.
---@return boolean ok
local function check_lib()
  local ok = pcall(require, "lib.nvim.notify")
  if not ok then
    health.error("lib.nvim: not found", {
      "hover.nvim requires it -- add StefanBartl/lib.nvim to `dependencies`.",
    })
    return false
  end

  local missing = {}
  for _, module in ipairs({
    "lib.nvim.bindings.autocmd",
    "lib.nvim.bindings.usercmd.composer",
    "lib.nvim.debounce",
    "lib.nvim.image_preview",
    "lib.nvim.net.curl",
    "lib.nvim.notify",
    "lib.lua.memo.lru",
    "lib.lua.strings.width",
  }) do
    if not pcall(require, module) then
      missing[#missing + 1] = module
    end
  end

  if #missing > 0 then
    health.warn(
      ("lib.nvim: found, but %d module(s) missing: %s"):format(
        #missing,
        table.concat(missing, ", ")
      ),
      { "Your lib.nvim is probably pinned to an older commit than this plugin expects." }
    )
    return true
  end

  health.ok("lib.nvim: available")
  return true
end

---@internal
--- The state every switch is in, plus the two combinations that look like a
--- defect from the outside.
---@return nil
local function check_config()
  local config = require("hover.config")
  local mode = config.mode()

  if mode == "off" then
    health.warn("mode: off -- nothing hovers", {
      "`:Hover mode auto` turns it back on for this session.",
      "`vim.g.hover_disable` also forces this, and outranks any setup() call.",
    })
  else
    health.ok(("mode: %s"):format(mode))
  end

  if mode == "manual" then
    local keymaps = config.get().keymaps
    local show = type(keymaps) == "table" and keymaps.show
    if not show or show == "" or (type(show) == "table" and #show == 0) then
      health.warn("manual mode with no key bound to show a hover", {
        "`:Hover show` works, but a key is what this mode is for:",
        '  require("hover").setup({ keymaps = { show = "<leader>k" } })',
      })
    end
  end

  local any = false
  for _, s in ipairs(require("hover.switches").status()) do
    if s.enabled then
      any = true
    end
    health.info(("%-22s %s"):format(s.label, s.enabled and "on" or "off"))
  end

  if not any and mode ~= "off" then
    health.warn("every preview class is switched off -- no target can produce a float", {
      "`:Hover status` lists them; `:Hover paths on` is the usual one to restore.",
    })
  end

  -- Reported because it is otherwise invisible and can be load-bearing: a
  -- family added to the code set switches the bare-path hover off in that
  -- language, silently, everywhere that family appears. Anyone debugging
  -- "paths stopped hovering in X" should find it here rather than by reading
  -- their own config again.
  local families = require("hover.config").scope_families()
  local function listed(set)
    local out = {}
    for family in pairs(set) do
      out[#out + 1] = family
    end
    table.sort(out)
    return out
  end
  local prose, code = listed(families.prose), listed(families.code)
  if #prose > 0 then
    health.info(
      ("scope: %d capture famil%s taught as prose -- %s"):format(
        #prose,
        #prose == 1 and "y" or "ies",
        table.concat(prose, ", ")
      )
    )
  end
  if #code > 0 then
    health.warn(
      ("scope: %d capture famil%s taught as code -- %s"):format(
        #code,
        #code == 1 and "y" or "ies",
        table.concat(code, ", ")
      ),
      {
        "Bare paths will not hover at any position captured by these.",
        "That is the one direction this setting can disable the feature in.",
        "`:Hover paths code on` turns the position gate off entirely.",
      }
    )
  end
end

--- `:checkhealth hover`.
---@return nil
function M.check()
  health.start("hover.nvim")

  if not check_lib() then
    -- Nothing below can be answered honestly without it, and a cascade of
    -- follow-on errors would bury the one that matters.
    return
  end

  health.start("hover.nvim: configuration")
  check_config()

  health.start("hover.nvim: optional contributors")
  -- Each entry is a `pcall(require, ...)` this plugin actually performs;
  -- the list and the code are meant to be compared against each other.
  soft(
    "markdown.nvim",
    nil,
    "only bare paths start a hover; `file.md#heading` shows the file's head, not that section"
  )
  soft("images.info", "collect", "an image target shows its format and size as text")
  soft("images.anchor", "draw", "no picture is drawn into the float")
  soft("pdfport", "render_page", "a PDF shows its size, not its first page")
  soft("gopath.resolve", "resolve_at_cursor", "truncated paths (`...nvim/init.lua`) do not resolve")

  -- markdown.nvim contributes through the registry rather than by name, so
  -- "is it installed" and "did it register" are different questions -- and
  -- the second is the one that decides whether links hover.
  local registry_ok, registry = pcall(require, "hover.registry")
  if registry_ok and registry.has_sources() then
    health.ok("a link source is registered")
  else
    -- One argument. `vim.health.info` and `.ok` take no advice list -- only
    -- `warn` and `error` do -- and passing one is silently dropped, so the
    -- hint has to live in the message (`LLS-29`).
    health.info(
      "no link source registered -- only bare paths start a hover. "
        .. "markdown.nvim registers one from its setup(); if it is installed, its setup never ran."
    )
  end

  health.start("hover.nvim: external tools")
  if require("hover.config").office_enabled() then
    if vim.fn.executable("soffice") == 1 then
      health.ok("soffice: on PATH")
    else
      health.warn("soffice: not on PATH -- office documents cannot be converted", {
        "Install LibreOffice, or `:Hover office off` to stop asking for it.",
      })
    end
  else
    health.info("office rendering is off -- soffice is not needed")
  end

  if vim.fn.executable("pdftoppm") == 1 then
    health.ok("pdftoppm: on PATH")
  else
    health.info("pdftoppm: not on PATH -- pdfport cannot rasterize PDF pages")
  end
end

return M
