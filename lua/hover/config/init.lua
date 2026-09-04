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

  -- `zoom_keys` has had two meanings, and this is the seam between them.
  --
  -- It was the name of what is now `resize_keys`, back when the feature only
  -- applied to pictures and "make the box bigger" and "zoom" happened to
  -- coincide. `8ec5b40` renamed it and folded the old spelling. Then a *real*
  -- zoom arrived, and the name it wants is the one the old spelling occupies.
  --
  -- **So the name is taken back, and the old shape is reported rather than
  -- reinterpreted.** Silently folding it would have been the cheaper line and
  -- exactly the wrong one: this repository has just spent a day on a name
  -- that quietly meant something else than the reader thought (`bd72836`), and
  -- a config written against the old spelling would otherwise have started
  -- binding a 258 ms crop to the key it chose for a free resize step.
  --
  -- Told apart by shape, not by date: the old set has `larger`/`smaller`, the
  -- new one `into`/`out`/`reset`. Nothing else in this table can be confused
  -- for either.
  if type(opts.zoom_keys) == "table" then
    local old = opts.zoom_keys.larger ~= nil
      or opts.zoom_keys.smaller ~= nil
      or opts.zoom_keys.wheel_larger ~= nil
      or opts.zoom_keys.wheel_smaller ~= nil
    if old then
      require("hover.notify").warn(
        "hover.nvim: `zoom_keys` now configures the picture zoom, not resizing. "
          .. "Rename your `larger`/`smaller` entries to `resize_keys` -- they are being ignored."
      )
      opts.zoom_keys = nil
    end
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

  -- A border name nobody has, reported and dropped rather than passed on.
  --
  -- **The failure it prevents is a total one, and silent.** `nvim_open_win`
  -- refuses an unknown border string, `float.open` calls it inside a `pcall`
  -- and answers "no window" -- so a single typo in `setup()` produces a plugin
  -- that never opens a float again and never says why. Measured 2026-09-03:
  -- `border = "heavey"` survives the merge, and `nvim_open_win` returns false.
  --
  -- Reported and dropped, not corrected: the same stance the legacy
  -- `zoom_keys` shape gets. Guessing which style was meant would be a second
  -- kind of wrong, and keeping the default means the plugin still works while
  -- the message says what to fix.
  --
  -- Only *strings* are checked. An eight-character list is the escape hatch
  -- and cannot be validated against a name list; `nvim_open_win` judges that
  -- one, and a wrong list still draws a frame rather than none.
  if type(opts.border) == "string" then
    local names = require("hover.float").border_names()
    if not vim.tbl_contains(names, opts.border) then
      require("hover.notify").warn(
        ("unknown border %q -- keeping %q. Available: %s"):format(
          opts.border,
          DEFAULTS.border,
          table.concat(names, ", ")
        )
      )
      opts.border = nil
    end
  end

  -- `auto_hover` in its two short forms, folded into the full table
  -- `DEFAULTS` declares.
  --
  -- A **list** is a closed set -- "these types and no others" -- so it has to
  -- become an entry for every type, `false` included; merged as a list it
  -- would leave the default's second element sitting at index 2 and turn on a
  -- type nobody named, which is the same trap `replace_key_lists` exists for.
  -- **`true`/`false`** are the "all" and "none" ends of the same axis and
  -- read better than either extreme written out.
  --
  -- A table shape is left exactly as given: that is the additive form, where
  -- `{ file = true }` means "and file too", and it is the shape a runtime
  -- toggle writes back.
  if opts.auto_hover ~= nil then
    local given = opts.auto_hover
    if type(given) == "boolean" then
      local all = {}
      for _, name in ipairs(require("hover.config.auto_types")()) do
        all[name] = given
      end
      opts.auto_hover = all
    elseif type(given) == "table" and #given > 0 then
      local wanted = {}
      for _, name in ipairs(given) do
        if type(name) == "string" then
          wanted[name] = true
        end
      end
      local full = {}
      for _, name in ipairs(require("hover.config.auto_types")()) do
        full[name] = wanted[name] == true
      end
      opts.auto_hover = full
    end
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
--- **Which tables those are is read off `DEFAULTS`, not listed here**, and the
--- list this replaced is why. It named `scroll_keys`, `resize_keys`,
--- `pan_keys` and `keymaps`, and the doc comment above it claimed to be
--- "declared rather than written out" while being a literal -- so adding
--- `zoom_keys` would have been the fifth time in this repository that a
--- hand-kept copy of something `DEFAULTS` already knows fell behind it, and
--- nothing would have failed: a configured `zoom_keys.into` would simply have
--- merged alongside the default instead of replacing it, and bound both.
---
--- The rule is mechanical: every `DEFAULTS` entry whose name ends in `_keys`,
--- plus `keymaps`, which is the one key table that does not. A new key set is
--- picked up by existing, which is the only kind of list that cannot drift.
---@param opts table the user's options, unmerged
---@return nil
local function replace_key_lists(opts)
  ---@type string[]
  local key_tables = { "keymaps" }
  for name, value in pairs(DEFAULTS) do
    if type(value) == "table" and name:match("_keys$") then
      key_tables[#key_tables + 1] = name
    end
  end
  table.sort(key_tables)

  -- Tables of key lists: whatever direction the user named is replaced, and
  -- the ones they did not name keep their default.
  for _, name in ipairs(key_tables) do
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

--- Whether the automatic trigger opens a float for a target of this type.
---
--- Answered only for the trigger: `:Hover show` passes `force` and never
--- reaches this. The difference between it and `paths_enabled` and friends is
--- the difference between "not without being asked" and "not at all" — see
--- `DEFAULTS.auto_hover`.
---
--- Unknown names answer `true`. A type this table has never heard of is a
--- newer target class than the configuration was written against, and the
--- fail-open direction is the one that shows a reader something rather than
--- silently withholding it — the same choice `hover.scope` makes for capture
--- families it does not recognise.
---@param target_type string # A `Hover.Target.type`, or `"position"`.
---@return boolean
function M.auto_hover_for(target_type)
  local auto = M.get().auto_hover
  if type(auto) == "boolean" then
    return auto
  end
  if type(auto) ~= "table" then
    return true
  end
  local value = auto[target_type]
  if value == nil then
    return true
  end
  return value == true
end

--- The `auto_hover` table as it stands, every known name present.
---
--- For the places that report rather than decide: `:Hover auto`, the health
--- section, and the spec that holds the keys against `classify.TYPES`.
---@return table<string, boolean>
function M.auto_hover()
  local out = {}
  for _, name in ipairs(require("hover.config.auto_types")()) do
    out[name] = M.auto_hover_for(name)
  end
  return out
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

--- Whether a hovered link is rendered by a headless browser.
---
--- Implies `web_enabled` and deliberately **not** `fetch_enabled`: a fetch is
--- one `curl` GET, a render *executes* the page. They are different categories
--- rather than two volumes of one, so neither may imply the other. See
--- `hover.preview.shot`.
---@return boolean
function M.shot_enabled()
  local links = M.get().links
  if not M.web_enabled() or type(links) ~= "table" then
    return false
  end
  local shot = links.shot
  return type(shot) == "table" and shot.enabled == true
end

--- Whether the *automatic trigger* may start a browser, rather than only an
--- explicit request.
---
--- The second half of the switch above, and separate because the two
--- questions have different answers: rendering a link on request is a
--- decision, rendering every link the cursor passes is a browser start per
--- link. `auto_hover.url` cannot express it -- the text preview and the
--- screenshot are the same target type.
---@return boolean
function M.shot_eager()
  local links = M.get().links
  if not M.shot_enabled() or type(links) ~= "table" then
    return false
  end
  local shot = links.shot
  return type(shot) == "table" and shot.eager == true
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

--- Whether going full screen also pins the float.
---
--- Defaults to *true*, so the test is `~= false` rather than `== true`: the
--- float is `focusable = false` and its dismissal hangs on `CursorMoved`, so
--- an unpinned full-screen hover closes on the first key that is not
--- borrowed. See `hover.zen`.
---@return boolean
function M.zen_pins()
  local zen = M.get().zen
  return type(zen) ~= "table" or zen.pin ~= false
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
  local shot = type(links.shot) == "table" and links.shot or {}
  return {
    max_lines = c.max_lines or DEFAULTS.max_lines,
    max_width = c.max_width or DEFAULTS.max_width,
    inline_images = M.images_enabled(),
    url_fetch = M.fetch_enabled(),
    url_timeout_ms = links.timeout_ms or DEFAULTS.links.timeout_ms,
    shot_enabled = M.shot_enabled(),
    shot_eager = M.shot_eager(),
    shot_timeout_ms = shot.timeout_ms or DEFAULTS.links.shot.timeout_ms,
    shot_width = shot.width or DEFAULTS.links.shot.width,
    shot_height = shot.height or DEFAULTS.links.shot.height,
    shot_cache_days = shot.cache_days or DEFAULTS.links.shot.cache_days,
    shot_delay_ms = shot.delay_ms or DEFAULTS.links.shot.delay_ms,
    -- No default to fall back on, and that is the setting: unset means "find
    -- one", which `hover.preview.shot` answers by searching.
    shot_command = shot.command,
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
