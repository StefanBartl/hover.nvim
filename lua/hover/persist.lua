---@module 'hover.persist'
---@brief Carry a session's `:Hover status` toward the next one.
---@description
--- Every switch, `mode` and `auto_hover` are written back over the
--- installation spec's own `opts` on the next `enable()`, by default:
--- `:Hover links web on` outlives the session it was toggled in, rather than
--- ending the moment Neovim does. `persist = false` is the reader saying the
--- opposite -- "this is for right now only" -- for a session-only override
--- (`:Hover links web on` while chasing one broken link) that a config edit
--- would be the wrong tool for.
---
--- **What is carried, and what is not.** Exactly what `hover.switches`
--- already declares a `path` for, plus `mode` and `auto_hover` -- the same
--- three axes `:Hover status` reports, and nothing more: `border`,
--- `max_lines`, the `_keys` tables and every layout or keybinding option
--- stay in the installation spec, where a reader can see them.
---
--- **Loaded at `enable()`, after the installation spec's own `opts` are
--- merged in.** `M.load` is `config.setup(snapshot)` under another name, so
--- it is subject to the same merge `config.setup` always does -- the order
--- ends up DEFAULTS -> installation spec -> the last session's switches, and
--- a runtime toggle really does win over a static default until it is
--- toggled back, which is the entire feature.
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

--- The current `mode`, `auto_hover` and every switch's own flag, shaped
--- exactly like the `Hover.Config` an installation spec's `opts` would pass
--- -- so loading it back is `config.setup(snapshot)` and nothing else.
---@return Hover.Config
function M.snapshot()
  local raw = require("hover.config").raw()
  local switches = require("hover.switches")

  ---@type Hover.Config
  local out = { mode = raw.mode, auto_hover = vim.deepcopy(raw.auto_hover) }
  for _, name in ipairs(switches.names()) do
    local spec = switches.spec(name)
    if spec then
      set_at(out, spec.path, get_at(raw, spec.path) == true)
    end
  end
  return out
end

---@internal
--- `lib.nvim.cache.disk`, or nil where it is not there to reach.
---@return table|nil
local function disk()
  local ok, mod = pcall(require, "lib.nvim.cache.disk")
  if ok and type(mod) == "table" and type(mod.save) == "function" and type(mod.load) == "function" then
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

--- Load the last session's snapshot over the merged configuration, when
--- `persist` is on. Called once, from `enable()`, after the installation
--- spec's own `opts` -- see the module description for why the order is
--- what makes this the reader's last word rather than the spec's.
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
  if type(saved) == "table" then
    require("hover.config").setup(saved)
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
