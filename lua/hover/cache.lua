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

--- Throw away every built preview.
---@return nil
function M.reset()
  _store = nil
end

return M
