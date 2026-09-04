---@module 'hover.cache'
---@brief The LRU of built previews, and the one rule about dropping it.
---@description
--- Its own module for one reason: **every switch that changes what a preview
--- would say has to drop it**, and the switches must be able to do that
--- without reaching into the orchestrator (which requires them back).
---
--- The cache is keyed by what the target *is*, not by how it was previewed.
--- So a URL cached as "host and path" would still answer that way after
--- `:Hover links web fetch on`, and a fetched 500 would keep being shown
--- after the server recovered. Dropping it costs one rebuild per target and
--- removes a whole class of "the setting did nothing" reports.
---
---@see hover.switches

local M = {}

---@type table|nil
local _store = nil

---@internal
--- `lib.lua.memo.lru` when it is there, a plain table when it is not.
---
--- The fallback is unbounded, which is acceptable here and nowhere else: a
--- hover cache holds short string lists keyed by target, and a session that
--- hovers enough distinct targets to notice has bigger problems. Bounding it
--- badly (a hand-rolled eviction) would be worse than not bounding it.
---@return table
local function store()
  if _store then
    return _store
  end
  local ok, lru = pcall(require, "lib.lua.memo.lru")
  if ok and lru and lru.new then
    _store = lru.new(64)
  else
    local plain = {}
    _store = {
      get = function(_, key)
        return plain[key]
      end,
      put = function(_, key, value)
        plain[key] = value
      end,
    }
  end
  return _store
end

--- Identity of a target for caching. Includes mtime, so an edited file is
--- re-read rather than served stale.
---@param target Hover.Target
---@return string
function M.key(target)
  local mtime = ""
  if target.path then
    local uv = vim.uv or vim.loop
    local stat = uv.fs_stat(target.path)
    if stat and stat.mtime then
      mtime = tostring(stat.mtime.sec)
    end
  end
  return table.concat(
    { target.type, target.raw, target.path or "", target.anchor or "", mtime },
    "|"
  )
end

--- The cached content for `key`, or nil.
---@param key string
---@return Hover.Content|nil
function M.get(key)
  return store():get(key)
end

--- Cache `content` under `key`.
---@param key string
---@param content Hover.Content
---@return nil
function M.put(key, content)
  store():put(key, content)
end

---@type (fun())[] Stores that have to be dropped whenever this one is.
local _droppers = {}

--- Register a store of your own that must be dropped with this one.
---
--- **Why a registry rather than a call from `reset`.** A previewer that keeps
--- something across hovers -- `preview/url.lua` keeps the last response, so a
--- float re-rendered at another size costs no second request to that host --
--- has a store this module knows nothing about. Writing the drop into `reset`
--- would make that a list of previewers kept by hand in the module they do not
--- belong to, which is the shape this repository has now been bitten by five
--- times. Registering inverts it: a previewer that has such a store says so,
--- and one that has none needs no entry anywhere.
---
--- Called on first use rather than at load, so requiring a previewer to look
--- at it -- which the specs and the doc checks do -- registers nothing.
---
--- Not un-registerable, and it does not need to be: the callback closes over a
--- module-local table in a module `require` keeps for the session, so there is
--- nothing whose lifetime is shorter than this one's.
---@param drop fun()
---@return nil
function M.on_reset(drop)
  if type(drop) == "function" then
    _droppers[#_droppers + 1] = drop
  end
end

--- Throw away every built preview, and everything registered alongside.
---@return nil
function M.reset()
  _store = nil
  for _, drop in ipairs(_droppers) do
    -- `pcall`: a previewer whose drop errors must not stop a switch from
    -- taking effect, and the switch is what the reader is looking at.
    pcall(drop)
  end
end

return M
