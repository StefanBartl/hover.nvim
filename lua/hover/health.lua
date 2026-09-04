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
--- What one contributor registered, in words -- "2 sources, 1 preview".
---
--- Spelled out rather than tabulated because the question behind it is a
--- yes/no one: someone who wrote one function needs to read `1`, and a reader
--- who wrote none needs the name they did not write to be absent.
---
--- At least one count is non-zero for every entry the registry hands back --
--- it builds them from the registrations themselves, so a name with nothing
--- under it cannot occur -- which is why there is no empty case here.
---@param contributor Hover.Contributor
---@return string
local function registered(contributor)
  local parts = {}
  local function add(n, noun)
    if n > 0 then
      parts[#parts + 1] = ("%d %s%s"):format(n, noun, n == 1 and "" or "s")
    end
  end
  add(contributor.sources, "source")
  add(contributor.previews, "preview")
  add(contributor.positions, "position preview")

  local out = table.concat(parts, ", ")
  if contributor.on_request > 0 then
    -- Worth its own clause: a contribution marked `on_request` is registered,
    -- correct and still silent on the automatic trigger, which is exactly the
    -- state someone would otherwise report as "it does not work".
    out = ("%s (%d asked only on `:Hover show`)"):format(out, contributor.on_request)
  end
  return out
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

  -- What opens without being asked, said out loud.
  --
  -- Reported rather than left to the configuration file, because the default
  -- is narrow and the failure it produces reads as breakage: a reader who
  -- hovers a text file and gets nothing has no way to tell "this type waits
  -- to be asked" from "the plugin is not working". `:Hover why` answers for
  -- one float; this answers for the setting behind all of them.
  do
    local on, off = {}, {}
    for _, name in ipairs(require("hover.config.auto_types")()) do
      table.insert(config.auto_hover_for(name) and on or off, name)
    end
    if #on == 0 then
      health.warn("auto_hover: nothing opens by itself", {
        "`:Hover show` still answers for every type.",
        "`:Hover auto all` turns the automatic trigger back on for all of them.",
      })
    else
      health.ok(("auto_hover: %s open by themselves"):format(table.concat(on, ", ")))
      if #off > 0 then
        -- One string, no advice list: `health.info` takes a message and
        -- nothing else, and a second argument is dropped in silence -- the
        -- same trap documentation.nvim's own health section fell into
        -- (`9f128bb`). The LuaLS scan is what saw it here, after a green
        -- suite.
        health.info(
          ("on request only: %s -- `:Hover auto <type>` toggles one for this session"):format(
            table.concat(off, ", ")
          )
        )
      end
    end
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

  -- The browser, and only once the switch that needs one is on.
  --
  -- **Reported here because `lib.nvim.deps` cannot answer it.** That check
  -- asks whether `chrome` is on PATH, and on Windows it is not: the installer
  -- does not extend PATH, so a machine with Chrome plainly installed reports
  -- it missing -- the same false alarm `soffice` already carries a note about
  -- in `docs/install.json`. This asks the previewer, which searches the usual
  -- install locations, and names the binary it would actually run.
  if config.shot_enabled() then
    -- Read off `preview_opts` rather than walked out of the options table by
    -- hand: that is where the shape is already normalized, and a second walk
    -- here would be one more place for the option path to be spelled wrong.
    local configured = config.preview_opts().shot_command
    local browser =
      require("hover.preview.shot").browser(type(configured) == "string" and configured or nil)
    if browser then
      -- **Reconciled out loud, because the report contradicts itself
      -- otherwise.** The dependency section below asks `PATH` and says
      -- `chrome NOT found`; this line found one anyway, by looking where the
      -- installer puts it. Two lines about the same binary disagreeing is
      -- exactly the state a health report exists to prevent, so the one that
      -- knows more says which is which. A name with no separator in it came
      -- off `PATH` and there is nothing to reconcile.
      if browser:find("[/\\]") then
        health.ok(
          ("page screenshots: %s -- found off PATH, so the `chrome NOT found` line below is expected and not a problem"):format(
            browser
          )
        )
      else
        health.ok(("page screenshots: %s"):format(browser))
      end
    else
      health.warn("page screenshots are on, and no headless browser was found", {
        "Any Chromium-based one answers: chrome, chromium, brave, msedge.",
        "PATH is searched first, then the usual install locations.",
        '`links = { shot = { command = "/path/to/chrome" } }` names one outright.',
        "`:Hover links web shot off` stops asking.",
      })
    end
    if not config.images_enabled() then
      health.warn("page screenshots are on, but pictures are switched off", {
        "A rendered page is a picture; with `images` off there is nothing to draw it with.",
        "`:Hover images on`, or `:Hover links web shot off`.",
      })
    end
  end

  -- The resize wheel is *inert* without 'mouse', not broken, and from the
  -- outside those look identical: a chord that arrives and does nothing, and
  -- one that never arrives at all. Reported here because the difference is
  -- invisible everywhere else -- `:Hover why` answers about a float that did
  -- not open, not about a key that was never delivered.
  local keylist = require("hover.bindings.keymaps").keylist
  local rk = config.get().resize_keys
  local wheel = type(rk) == "table"
    and (#keylist(rk.wheel_larger) > 0 or #keylist(rk.wheel_smaller) > 0)
  if wheel and vim.o.mouse == "" then
    health.warn("resize wheel bound, but 'mouse' is empty -- no wheel event arrives", {
      "`:set mouse=a`, or any mode you use the wheel in.",
      "`+` / `-` and `:Hover resize` are unaffected; only the wheel needs this.",
    })
  end

  -- A zoom key a resize key already holds is bound, and then never fires:
  -- `borrow` takes the resize keys first, a key taken twice is taken once,
  -- and the two conditions overlap completely -- every hover a zoom key is
  -- bound for has a picture in it. `-` is what invites this, being the
  -- obvious partner for a `_`. Reported here because the symptom is a key
  -- doing something *else*, which is the hardest kind to attribute: the
  -- picture grows, so the key plainly works, and only the framing is wrong.
  local zk = config.get().zoom_keys
  if type(rk) == "table" and type(zk) == "table" then
    ---@type table<string, string>
    local held = {}
    for _, name in ipairs({ "larger", "smaller" }) do
      for _, lhs in ipairs(keylist(rk[name])) do
        held[lhs] = "resize_keys." .. name
      end
    end
    ---@type string[]
    local clash = {}
    for _, name in ipairs({ "into", "out", "reset" }) do
      for _, lhs in ipairs(keylist(zk[name])) do
        if held[lhs] then
          clash[#clash + 1] = ("`%s` is zoom_keys.%s and %s"):format(lhs, name, held[lhs])
        end
      end
    end
    if #clash > 0 then
      table.sort(clash)
      clash[#clash + 1] = "Resize is bound first, and a key listed twice is taken once."
      clash[#clash + 1] = "Every hover a zoom key is bound for has a picture, so it is every press."
      health.warn("a zoom key is also a resize key -- it will resize, never zoom", clash)
    end
  end

  -- The route beside the label, for the same reason `:Hover status` grew a
  -- board: `broken-target marker` is a state, `:Hover paths missing` is the
  -- thing to type about it, and only one of them used to be on screen. A
  -- switch that is set while the switch above it is off says so rather than
  -- reading as a plain "off" that turning the parent on appears to undo.
  local any = false
  for _, s in ipairs(require("hover.switches").status()) do
    if s.enabled then
      any = true
    end
    -- Three states, not two. "On, and the trigger still does not ask for it"
    -- is the one that gets reported as a broken feature: the switch is on,
    -- the preview exists, and `auto_hover` -- a different axis, set somewhere
    -- else -- is what keeps the float shut. See `switches.on_report`.
    local state = s.enabled and "on"
      or (s.flag and "off (held by " .. tostring(s.implies) .. ")" or "off")
    if s.enabled and s.auto_type and not config.auto_hover_for(s.auto_type) then
      state = ("on, %s on request"):format(s.auto_type)
    end
    health.info(("%-22s %-24s :Hover %s"):format(s.label, state, table.concat(s.route, " ")))
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

  -- Who registered what, which is a different question from the one above and
  -- the one `contribute` created: since a hover can be written in a user's
  -- own config, "is mine registered?" has an asker, and the link-source line
  -- answers it wrongly in both directions -- "no" for a config that
  -- contributed a position preview, "yes, markdown.nvim" for one whose own
  -- contribution never arrived.
  local contributors = registry_ok and registry.contributors() or {}
  if #contributors == 0 then
    -- `info`, not `warn`: a plugin with no contributors installed is the
    -- supported configuration, not a defect. Bare paths, bare URLs and git
    -- object ids are built in and hover without any of this.
    health.info(
      "registry: empty -- no plugin, and no `contribute` in setup(), has registered anything"
    )
  end
  for _, contributor in ipairs(contributors) do
    health.ok(("registry: %s -- %s"):format(contributor.name, registered(contributor)))
  end

  health.start("hover.nvim: external tools")
  if require("hover.config").office_enabled() then
    if vim.fn.executable("soffice") == 1 then
      health.ok("soffice: on PATH")
    else
      -- The second line is not padding: on Windows the installer does not put
      -- `soffice.exe` on PATH, so this warning fires on a machine where
      -- LibreOffice is plainly installed and "install LibreOffice" is advice
      -- the reader has already followed. Reported 2026-09-02.
      health.warn("soffice: not on PATH -- office documents cannot be converted", {
        "Install LibreOffice, or `:Hover office off` to stop asking for it.",
        "Already installed? On Windows the installer does not extend PATH: add "
          .. "the LibreOffice `program` directory to it and restart the terminal. "
          .. "The one-liner is in docs/installation.md.",
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

  -- The same two tools again, this time out of docs/install.json rather than
  -- by hand -- which is what adds the per-manager install command and the
  -- `:Lib deps install hover.nvim` route. The checks above stay: they carry
  -- the Windows PATH advice for soffice, which no generic report can.
  -- Silent when lib.nvim.deps is absent (an older lib.nvim).
  local ok_deps, deps_health = pcall(require, "lib.nvim.deps.health")
  if ok_deps then
    health.start("hover.nvim: declared tools (lib.nvim.deps)")
    deps_health.report_for("hover.nvim")
  end
end

return M
