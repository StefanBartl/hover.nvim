---@module 'hover.persist'
---@brief Carry a session's *runtime toggles* toward the next one.
---@description
--- A switch the reader actually flipped -- `:Hover links web on`, `:Hover
--- mode manual`, `:Hover auto file` -- outlives the session it was toggled
--- in, rather than ending the moment Neovim does. `persist = false` is the
--- reader saying the opposite -- "this is for right now only" -- for a
--- session-only override (`:Hover links web on` while chasing one broken
--- link) that a config edit would be the wrong tool for.
---
--- **Only what was explicitly toggled, never what the spec merely set**
--- (`LUA-87`). `mode = "manual"` in an installation spec and `:Hover mode
--- manual` typed at the prompt used to look identical by the time either
--- reached `M.snapshot`: both are `config.raw().mode == "manual"`, so the
--- old snapshot wrote every field unconditionally and could not tell "the
--- reader chose this" from "this was the spec's value when Neovim closed".
--- The effect was a spec a reader could no longer edit: change `office =
--- false` in the installation spec, and the *next* `enable()` loaded last
--- session's snapshot -- which had faithfully copied the *old* spec value --
--- straight back over the new one, because nothing recorded that `office`
--- was never actually touched.
---
--- The fix is an explicit set (`M.touch`), written to alongside the value by
--- every runtime toggle path -- `hover.switches.set`, `hover.set_mode`,
--- `hover.set_auto` -- and by nothing else. `config.setup` (the spec, or a
--- host calling `setup()` again) never calls `M.touch`, so a value that only
--- ever came from `opts` never enters the snapshot, however long the session
--- ran. `M.load` re-marks whatever it reads back as touched for the running
--- session too, which is what lets a genuinely toggled value keep surviving
--- session after session rather than only the next one -- see `M.load`.
---
--- **What is carried, and what is not.** Exactly what `hover.switches`
--- already declares a `path` for, plus `mode` and `auto_hover` -- the same
--- three axes `:Hover dashboard` reports, and nothing more: `border`,
--- `max_lines`, the `_keys` tables and every layout or keybinding option
--- stay in the installation spec, where a reader can see them. Of those
--- three axes, only the ones the reader actually touched are ever written --
--- and `auto_hover`, itself one boolean per target type, is tracked at that
--- same per-type grain: `:Hover auto file` persists `file` alone, not every
--- type `DEFAULTS.auto_hover` happens to expand to.
---
--- **Loaded at `enable()`, after the installation spec's own `opts` are
--- merged in.** `M.load` is `config.setup(sanitize(snapshot))` under another
--- name, so it is subject to the same merge `config.setup` always does --
--- the order ends up DEFAULTS -> installation spec -> the last session's
--- *touched* switches, and a runtime toggle really does win over a static
--- default until it is toggled back, which is the entire feature -- and a
--- spec value the reader never touched at all is never shadowed by it.
---
--- **Written once, on `VimLeavePre`, rather than on every `switches.set`.**
--- One writer for the reason `hover.cache`'s drop lives in one place rather
--- than at every call site that could invalidate it: a write on every toggle
--- would save the same fact as many times as a session happens to flip
--- something, for no answer a single write at exit does not already give. A
--- write lost to a crash is not recoverable either way -- `:wqa` is the
--- ordinary way Neovim closes, and this plugin does not attempt to survive
--- the other one.
---
--- Stored through `lib.nvim.cache.disk`, `pcall`-guarded like every other
--- reach into lib.nvim's optional surface (`hover.status_view`'s UI kit,
--- `hover.cache`'s LRU): on by default, so a present-but-older lib.nvim
--- without it must not break `enable()` for everyone who never configured
--- this at all -- it only stops switches from surviving a restart, which
--- `:checkhealth hover` says outright.
---
---@see hover.switches
---@see hover.config

local M = {}

---@type string Namespace `lib.nvim.cache.disk` stores this under -- one JSON
--- file at `stdpath("cache")/lib.nvim/cache/hover/status.json`.
local NAMESPACE = "hover/status"

---@type table<string, true|table<string,true>> Fields the reader has
--- explicitly set this session -- `"mode"`, `"auto_hover"`, or a name from
--- `hover.switches.names()` -- through a runtime toggle path, or inherited
--- from a snapshot `M.load` read back (see `M.touch`). `M.snapshot` writes
--- only what is in here; nothing else ever adds to it.
---
--- `auto_hover` is the one field that is itself multi-key (one boolean per
--- target type), so its entry can be either shape: `true` means "the whole
--- table was touched at once" (`:Hover auto all|none`, or a boolean
--- override), and a sub-table `{ [type] = true }` means only those
--- particular types were touched (`:Hover auto file`) -- so `M.snapshot`
--- can write back exactly those types and leave every other type, however
--- many the installation spec expanded `DEFAULTS.auto_hover` into, alone.
local _touched = {}

--- Mark `field` -- or, for the multi-key `auto_hover` field, just `subkey`
--- within it -- as explicitly set for the rest of this session, so
--- `M.snapshot` writes it back. Called only from the three runtime toggle
--- paths (`hover.switches.set`, `hover.set_mode`, `hover.set_auto`) and from
--- `M.load` itself -- never from `config.setup`, whose values came from an
--- installation spec, not from the reader (`LUA-87`).
---
--- Once a field is touched as a whole (`subkey` omitted), a later per-`subkey`
--- touch is a no-op: the whole-field mark already covers every subkey, and
--- narrowing it back to a sub-table here would forget that.
---@param field string
---@param subkey? string only meaningful for `field == "auto_hover"`
---@return nil
function M.touch(field, subkey)
  if subkey == nil then
    _touched[field] = true
    return
  end
  if _touched[field] == true then
    return
  end
  local entry = _touched[field]
  if type(entry) ~= "table" then
    entry = {}
    _touched[field] = entry
  end
  entry[subkey] = true
end

--- Forget every field marked touched. Exists for the test suite, which
--- would otherwise carry one spec's toggles into the next -- `_touched` is
--- module state and outlives `config.reset()`, which only clears the merged
--- options.
---@return nil
function M.reset()
  _touched = {}
end

---@internal
--- Write `value` at `path` inside `node`, creating intermediate tables as it
--- goes. The build side of `hover.switches`' own internal `write`, aimed at a
--- fresh table instead of the live options -- so a snapshot can be built
--- without touching `config.raw()` at all.
---@param node table
---@param path string[]
---@param value any
---@return nil
local function set_at(node, path, value)
  for i = 1, #path - 1 do
    local key = path[i]
    if type(node[key]) ~= "table" then
      node[key] = {}
    end
    node = node[key]
  end
  node[path[#path]] = value
end

---@internal
--- The raw flag at `path`, read out of `node` rather than out of the live
--- configuration -- `M.snapshot` walks `config.raw()` once and reuses it for
--- every switch, instead of one `config.get()` per switch.
---@param node table
---@param path string[]
---@return any
local function get_at(node, path)
  for _, key in ipairs(path) do
    if type(node) ~= "table" then
      return nil
    end
    node = node[key]
  end
  return node
end

--- `mode`, `auto_hover` and every switch's own flag that the reader has
--- actually touched this session (`_touched`), shaped like the subset of a
--- `Hover.Config` an installation spec's `opts` would pass for those fields
--- -- so loading it back is `config.setup(sanitize(snapshot))` and nothing
--- else. A field never in `_touched` is simply absent, which is what lets a
--- spec edit for it take effect: there is nothing here to overwrite it with.
---@return Hover.Config
function M.snapshot()
  local raw = require("hover.config").raw()
  local switches = require("hover.switches")

  ---@type Hover.Config
  local out = {}

  if _touched.mode then
    out.mode = raw.mode
  end

  if _touched.auto_hover then
    -- `auto_hover` is `table<string,boolean>|boolean|string[]` -- a `true`/
    -- `false` override is a valid value, not just the table forms, and
    -- `vim.deepcopy` only takes a table. Only the table shapes need copying
    -- to begin with, since a boolean has no shared identity to protect.
    local auto_hover = raw.auto_hover
    if type(_touched.auto_hover) == "table" and type(auto_hover) == "table" then
      -- Only specific types were touched this session (`:Hover auto file`)
      -- -- write back exactly those, not the whole table. `raw.auto_hover`
      -- is always fully expanded to every known type by this point (spec ->
      -- DEFAULTS merge), so copying it whole here would silently persist
      -- every type the installation spec ever set, one level below the
      -- field-level fix `LUA-87` already made.
      local partial = {}
      for name in pairs(_touched.auto_hover) do
        if auto_hover[name] ~= nil then
          partial[name] = auto_hover[name]
        end
      end
      out.auto_hover = partial
    else
      if type(auto_hover) == "table" then
        auto_hover = vim.deepcopy(auto_hover)
      end
      out.auto_hover = auto_hover
    end
  end

  for _, name in ipairs(switches.names()) do
    if _touched[name] then
      local spec = switches.spec(name)
      if spec then
        set_at(out, spec.path, get_at(raw, spec.path) == true)
      end
    end
  end
  return out
end

---@internal
--- `lib.nvim.cache.disk`, or nil where it is not there to reach.
---@return table|nil
local function disk()
  local ok, mod = pcall(require, "lib.nvim.cache.disk")
  if
    ok
    and type(mod) == "table"
    and type(mod.save) == "function"
    and type(mod.load) == "function"
  then
    return mod
  end
  return nil
end

--- Save the current snapshot, when `persist` is on and the disk cache is
--- reachable. Silent either way: a session that never touched a switch
--- writes the same defaults back, which is a fact worth no announcement.
---@param opts? { dir?: string } # `dir` override, for the test suite.
---@return nil
function M.save(opts)
  if require("hover.config").get().persist ~= true then
    return
  end
  local d = disk()
  if not d then
    return
  end
  d.save(NAMESPACE, M.snapshot(), opts)
end

---@internal
--- Re-derive a safe `Hover.Config` shape from an untrusted snapshot.
---
--- The file on disk is a snapshot `M.snapshot()` wrote, but it is read back
--- as untrusted (`SEC-33`): hand-edited, half-written by a crash, or written
--- by an older version of this plugin with a different shape. Only the keys
--- `M.snapshot()` itself ever produces are copied over, and each is checked
--- for the one type it could only ever have been written as -- a `mode` that
--- is not a string, a switch that is not a boolean, or any key this function
--- does not know about is dropped rather than merged in. `mode`'s *value*
--- (as opposed to its type) is re-checked downstream by `config.setup`
--- (`ERR-22`); everything else has no such second gate, which is what made
--- the unfiltered merge reachable in the first place.
---@param saved table
---@return Hover.Config
local function sanitize(saved)
  ---@type Hover.Config
  local out = {}

  if type(saved.mode) == "string" then
    out.mode = saved.mode
  end

  local auto_hover = saved.auto_hover
  if type(auto_hover) == "boolean" then
    out.auto_hover = auto_hover
  elseif type(auto_hover) == "table" then
    local clean = {}
    for name, value in pairs(auto_hover) do
      if type(name) == "string" and type(value) == "boolean" then
        clean[name] = value
      end
    end
    out.auto_hover = clean
  end

  local switches = require("hover.switches")
  for _, name in ipairs(switches.names()) do
    local spec = switches.spec(name)
    local value = spec and get_at(saved, spec.path)
    if spec and type(value) == "boolean" then
      set_at(out, spec.path, value)
    end
  end

  return out
end

--- Load the last session's snapshot over the merged configuration, when
--- `persist` is on. Called once, from `enable()`, after the installation
--- spec's own `opts` -- see the module description for why the order is
--- what makes this the reader's last word rather than the spec's.
---
--- **Re-touches every field it applies.** A field on disk got there because
--- some earlier session's `M.touch` put it there -- this session inherits
--- that explicitness, which is what lets a toggle survive *every* session
--- from then on rather than only the next one: without this, a session in
--- which the reader touches nothing would snapshot an empty `_touched` at
--- exit and silently drop everything a previous session had persisted.
--- `auto_hover`'s table form re-touches per key rather than as a whole,
--- mirroring `M.snapshot`'s write side: only the types the snapshot actually
--- carried (because some earlier session touched exactly those) come back
--- touched, so a type the disk snapshot never had a say in stays open to a
--- spec edit even after a `load()`.
---@param opts? { dir?: string, ttl_seconds?: integer } # `dir` override, for the test suite.
---@return nil
function M.load(opts)
  if require("hover.config").get().persist ~= true then
    return
  end
  local d = disk()
  if not d then
    return
  end
  local saved = d.load(NAMESPACE, opts)
  if type(saved) ~= "table" then
    return
  end

  local sanitized = sanitize(saved)
  require("hover.config").setup(sanitized)

  if sanitized.mode ~= nil then
    M.touch("mode")
  end
  if type(sanitized.auto_hover) == "boolean" then
    M.touch("auto_hover")
  elseif type(sanitized.auto_hover) == "table" then
    for name in pairs(sanitized.auto_hover) do
      M.touch("auto_hover", name)
    end
  end
  local switches = require("hover.switches")
  for _, name in ipairs(switches.names()) do
    local spec = switches.spec(name)
    if spec and get_at(sanitized, spec.path) ~= nil then
      M.touch(name)
    end
  end
end

--- Install the `VimLeavePre` write-back, in the `HoverPersist` augroup.
--- Idempotent -- `autocmd.group(..., true)` clears the group on every call,
--- the same shape `hover.bindings.autocmds` uses -- and installed regardless
--- of whether `persist` is on right now: `save()` reads that flag fresh at
--- exit, so turning it on mid-session (`config.raw().persist = true`) is
--- picked up without a second call here.
---@return nil
function M.setup()
  local autocmd = require("lib.nvim.bindings.autocmd")
  local group = autocmd.group("HoverPersist", true)
  autocmd.create("VimLeavePre", function()
    M.save()
  end, {
    group = group,
    desc = "[hover.nvim] write mode, auto_hover and every switch back to disk",
  })
end

return M
