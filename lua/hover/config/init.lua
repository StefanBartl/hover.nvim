---@module 'hover.config'
---@brief The effective configuration, and every question the rest of the plugin asks of it.
---@description
--- One place that owns "what is switched on right now". Everything else asks
--- here rather than reading `M.options` directly, because three of the
--- answers are not fields at all:
---
---  * `vim.g.hover_disable` outranks whatever a host configured. hover.nvim
---    is a dependency of other plugins, so a user who wants no hover has to
---    be able to say so once, from a plugin spec's `init`, and have it win
---    over a host's `setup()`.
---  * Legacy option shapes are accepted and normalized on the way in --
---    `enabled = false`, `bare_paths`, `url = { hover, fetch }` -- so a host
---    that learned this plugin's options while it lived in `lib.nvim.hover`
---    keeps working. Liberal in, canonical out: nothing downstream ever sees
---    the tolerant form.
---  * `web` implies `links`, and `fetch` implies `web`. Fetching with no
---    float to show it in would do the disclosure and none of the good.
---
--- Runtime switches (`:Hover links web on`) mutate the merged table through
--- `M.raw()`, never `DEFAULTS`.

local M = {}

local DEFAULTS = require("hover.config.DEFAULTS")

---@type Hover.Config
local _options = vim.deepcopy(DEFAULTS)

---@internal
--- Fold a legacy option shape into the canonical one, in place.
---
--- Each of these was the documented spelling while this module lived in
--- `lib.nvim.hover`, and markdown.nvim passes its own `hover = { ... }`
--- table straight through. Rejecting them would break a caller that has no
--- way of knowing the plugin moved.
---@param opts table user options, mutated
---@return nil
local function normalize(opts)
  -- `enabled = false` was the master switch before `mode` existed. It only
  -- ever had one meaningful value -- `true` was the default anyway -- so it
  -- maps onto "off" and nothing else.
  if opts.enabled == false and opts.mode == nil then
    opts.mode = "off"
  end
  opts.enabled = nil

  -- `bare_paths` was a flat boolean before the class grew a second switch
  -- (`missing`).
  if opts.bare_paths ~= nil then
    opts.paths = type(opts.paths) == "table" and opts.paths or {}
    if opts.paths.enabled == nil then
      opts.paths.enabled = opts.bare_paths ~= false
    end
    opts.bare_paths = nil
  end

  -- `url = { hover, fetch, timeout_ms }` covered only http(s). It is the web
  -- half of `links`, and the half that was already switchable.
  if type(opts.url) == "table" then
    opts.links = type(opts.links) == "table" and opts.links or {}
    if opts.url.hover ~= nil and opts.links.web == nil then
      opts.links.web = opts.url.hover == true
    end
    if opts.url.fetch ~= nil and opts.links.fetch == nil then
      opts.links.fetch = opts.url.fetch == true
    end
    if opts.url.timeout_ms ~= nil and opts.links.timeout_ms == nil then
      opts.links.timeout_ms = opts.url.timeout_ms
    end
    opts.url = nil
  end
end

---@internal
--- Replace, rather than merge, the option lists whose meaning is "exactly
--- these and no others".
---
--- `vim.tbl_deep_extend` merges lists by index, so `{ down = { "<C-n>" } }`
--- would leave the default's second key sitting at index 2 and bind both --
--- and `dismiss_keys = { "<C-c>" }` would leave `<Esc>` bound. A configured
--- key list is a closed, curated set (`ERR-52`), not an addition.
---
--- **Declared rather than written out**, and for the reason this repository
--- has now met four times: a hand-written list of what needs special
--- handling falls behind the table it is supposed to cover, and nothing
--- fails when it does. `zoom_keys` would have been the fourth `if` here.
---@param opts table the user's options, unmerged
---@return nil
local function replace_key_lists(opts)
  -- Tables of key lists: whatever direction the user named is replaced, and
  -- the ones they did not name keep their default.
  for _, name in ipairs({ "scroll_keys", "zoom_keys", "keymaps" }) do
    if type(opts[name]) == "table" and type(_options[name]) == "table" then
      for key, value in pairs(opts[name]) do
        _options[name][key] = vim.deepcopy(value)
      end
    end
  end

  -- Flat key lists: the whole list is the setting.
  for _, name in ipairs({ "dismiss_keys", "open_keys" }) do
    if opts[name] ~= nil then
      _options[name] = vim.deepcopy(opts[name])
    end
  end
end

--- Merge `opts` over the current options. Idempotent and additive: a host
--- can set only what it cares about, and calling it twice does not reset
--- the rest.
---@param opts? Hover.Config
---@return Hover.Config options the merged table
function M.setup(opts)
  if type(opts) ~= "table" then
    return _options
  end

  -- A copy first: `normalize` rewrites keys, and mutating a table the caller
  -- still holds (markdown.nvim passes its own live config through) would
  -- edit that plugin's configuration as a side effect.
  local incoming = vim.deepcopy(opts)
  normalize(incoming)

  _options = vim.tbl_deep_extend("force", _options, incoming)
  replace_key_lists(incoming)

  -- An unknown mode degrades to the default rather than aborting the whole
  -- setup (`ERR-22`); `:checkhealth hover` reports it.
  if _options.mode ~= "auto" and _options.mode ~= "manual" and _options.mode ~= "off" then
    _options.mode = DEFAULTS.mode
  end

  return _options
end

--- The merged options table itself, for the runtime switches that have to
--- write to it. Everything that only *reads* should use `M.get()`, which
--- folds in the global kill switch.
---@return Hover.Config
function M.raw()
  return _options
end

--- The effective configuration: the merged options with
--- `vim.g.hover_disable` folded in.
---@return Hover.Config
function M.get()
  if vim.g.hover_disable then
    -- A copy, so the stored options survive the flag being toggled back off
    -- at runtime rather than being permanently overwritten with "off".
    return vim.tbl_extend("force", _options, { mode = "off" })
  end
  return _options
end

--- The effective mode.
---@return Hover.Mode
function M.mode()
  return M.get().mode
end

--- Whether anything may open a float without being asked.
---@return boolean
function M.is_auto()
  return M.mode() == "auto"
end

--- Whether `show()` would open a float at all -- true in both "auto" and
--- "manual", false only when the hover is switched off.
---@return boolean
function M.is_enabled()
  return M.mode() ~= "off"
end

--- Whether a target found by link syntax may open a float.
---@return boolean
function M.links_enabled()
  local links = M.get().links
  return type(links) == "table" and links.enabled ~= false
end

--- Whether an http(s) target may open a float. Implies `links_enabled`:
--- a web link is a link, and switching links off switches web off with it.
---@return boolean
function M.web_enabled()
  local links = M.get().links
  return M.links_enabled() and type(links) == "table" and links.web == true
end

--- Whether a hovered link is fetched for the server's answer. Implies
--- `web_enabled` for the same reason.
---@return boolean
function M.fetch_enabled()
  local links = M.get().links
  return M.web_enabled() and type(links) == "table" and links.fetch == true
end

--- Whether a path written without link syntax may open a float.
---@return boolean
function M.paths_enabled()
  local paths = M.get().paths
  return type(paths) == "table" and paths.enabled ~= false
end

--- Whether a bare path that resolves to nothing may be reported as broken.
---@return boolean
function M.missing_enabled()
  local paths = M.get().paths
  return M.paths_enabled() and type(paths) == "table" and paths.missing ~= false
end

--- Whether a bare path may also be found in executable code, rather than
--- only in a source file's comments and strings.
---
--- Note the default: unlike every other flag here this one defaults to
--- *false*, so the test is `== true` rather than `~= false`.
---@return boolean
function M.paths_code_enabled()
  local paths = M.get().paths
  return M.paths_enabled() and type(paths) == "table" and paths.code == true
end

--- Capture families the user taught the position gate, as lookup sets.
---
--- Two sets rather than one list, because they are not symmetric: `prose`
--- can only make `hover.scope` more permissive and `code` can only make it
--- stricter, and only the second can silently disable the feature in a
--- language. `hover.health` reports both for that reason.
---
--- Always answers with both keys present, so the caller never has to check --
--- a gate on the hot path should not be doing shape checks on configuration.
---@return { prose: table<string, true>, code: table<string, true> }
function M.scope_families()
  local paths = M.get().paths
  local scope = type(paths) == "table" and paths.scope or nil
  local out = { prose = {}, code = {} }
  if type(scope) ~= "table" then
    return out
  end
  for _, which in ipairs({ "prose", "code" }) do
    local list = scope[which]
    if type(list) == "table" then
      for _, family in ipairs(list) do
        if type(family) == "string" and family ~= "" then
          out[which][family] = true
        end
      end
    end
  end
  return out
end

--- Whether a registered position preview may open a float.
---@return boolean
function M.positions_enabled()
  return M.get().positions ~= false
end

--- Whether office documents are converted for a real page preview, rather
--- than described by a badge.
---@return boolean
function M.office_enabled()
  local office = M.get().office
  return type(office) == "table" and office.convert == true
end

--- Whether pictures are drawn into the float where a provider can.
---@return boolean
function M.images_enabled()
  return M.get().inline_images ~= false
end

--- How long an async preview may take before it may interrupt with a
--- placeholder.
---
--- The literal rather than `DEFAULTS.placeholder_grace_ms` as the fallback:
--- `Hover.Config` marks every field optional -- it is what a *user* may pass
--- -- so reading the default back out of it yields `integer?` and this
--- function would not return what it promises. The DEFAULTS table is fully
--- populated by construction; the type cannot say so.
---@return integer
function M.placeholder_grace_ms()
  local n = M.get().placeholder_grace_ms
  if type(n) == "number" and n >= 0 then
    return n
  end
  return 250
end

--- The options every previewer is threaded, derived from the effective
--- configuration.
---
--- One place rather than two: `show` and `scroll` built this table
--- separately once, and the second silently lacked whatever the first had
--- just gained.
---@return Hover.PreviewOpts
function M.preview_opts()
  local c = M.get()
  local links = type(c.links) == "table" and c.links or {}
  local office = type(c.office) == "table" and c.office or {}
  return {
    max_lines = c.max_lines or DEFAULTS.max_lines,
    max_width = c.max_width or DEFAULTS.max_width,
    inline_images = M.images_enabled(),
    url_fetch = M.fetch_enabled(),
    url_timeout_ms = links.timeout_ms or DEFAULTS.links.timeout_ms,
    office_convert = M.office_enabled(),
    office_timeout_ms = office.timeout_ms or DEFAULTS.office.timeout_ms,
    office_cache_days = office.cache_days or DEFAULTS.office.cache_days,
  }
end

--- Reset to the shipped defaults. Exists for the test suite, which would
--- otherwise carry one spec's `setup()` into the next.
---@return nil
function M.reset()
  _options = vim.deepcopy(DEFAULTS)
end

return M
