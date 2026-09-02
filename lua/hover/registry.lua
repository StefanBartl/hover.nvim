---@module 'hover.registry'
--- Sources and previews a plugin contributes to the hover.
---@description
--- **The problem.** The hover framework knows how to find a path under the
--- cursor, classify it and draw a float around whatever comes back. It must
--- not know *who* can read a `#heading` out of a markdown file, or who can
--- turn a `.png` into pixels. Those are plugin capabilities, and a library
--- that requires plugins to do its job has the dependency backwards: install
--- lib.nvim on its own and half of it would be missing.
---
--- **The shape.** Plugins register into the library rather than the library
--- reaching for plugins. Two kinds of contribution, because the hover asks
--- two separate questions:
---
--- ```lua
--- hover.register("markdown", {
---   -- "what is under the cursor?" -- returns a raw target string, or nil.
---   -- Tried in registration order, before the built-in bare-path source.
---   sources = {
---     function(bufnr, row, col) return link_scan_at(bufnr, row, col) end,
---   },
---   -- "how do I preview a target of this type?" -- keyed by the type
---   -- `classify` produced. Overrides the built-in preview for that type.
---   previews = {
---     anchor = function(target, opts, bufnr) return section_of(target, bufnr) end,
---   },
--- })
--- ```
---
--- **Why sources are ordered and previews are not.** Several sources can
--- match the same cursor position — a markdown link and a bare path both
--- exist on `[a](./b.png)` — so "first match wins" needs an order, and
--- registration order is the only one a library can honestly offer. A preview
--- answers for exactly one type, so a second registration for that type is a
--- replacement, not a competitor, and needs no ordering rule.
---
--- **Why a plugin name is required.** Re-registering under the same name
--- replaces that plugin's contribution instead of stacking a second copy on
--- top: `setup()` running twice (a reload, a `:Lazy reload`) must not make
--- every source fire twice.

local M = {}

-- `Hover.Contribution`, `Hover.SourceFn` and `Hover.PreviewFn` are declared in
-- `hover.@types`. Re-declaring them here duplicated every field: an alias name
-- is global to LuaLS, and reopening a class to restate a field is a
-- `duplicate-doc-field`, not an override (`LLS-23`).

---@type { name: string, fn: function }[]
local sources = {}

---@type table<string, { name: string, fn: function }>
local previews = {}

---@type { name: string, fn: function }[]
local positions = {}

---@internal
--- Read one entry of a `sources` or `positions` list.
---
--- **Two shapes, and the second is why.** A bare function is asked on every
--- trigger, which is right for a contribution that is cheap and quiet. A
--- table entry can say `on_request = true`, and then it is asked only for an
--- explicit request -- `:Hover show`, or a key bound to it.
---
--- That flag exists because "how expensive is your answer" is knowledge only
--- the contributor has, and there was no way to state it. Measured, the
--- population that needs it: a git start costs ~41 ms, a `docker --version`
--- 230 ms, `podman --version` 490 ms -- the same whether they hit or miss.
--- A trigger that fires after every keystroke followed by quiet cannot pay
--- that, and the alternative on offer was `:Hover positions off`, which
--- silences every registered plugin at once rather than the expensive one.
---
--- The flag lives on the *entry* rather than in a fourth contribution kind
--- because it applies to both existing kinds identically. A
--- `sources_on_request` list would have needed a `positions_on_request`
--- beside it, and the pair would then have to stay in step by hand -- this
--- repository has been bitten three times by exactly that shape.
---@param entry any
---@return function|nil fn
---@return boolean on_request
local function normalize(entry)
  if type(entry) == "function" then
    return entry, false
  end
  if type(entry) == "table" and type(entry.fn) == "function" then
    return entry.fn, entry.on_request == true
  end
  return nil, false
end

--- Register a plugin's hover contributions.
---@param name string plugin name; re-registering replaces its previous entry
---@param contribution Hover.Contribution
---@return nil
function M.register(name, contribution)
  if type(name) ~= "string" or name == "" then
    return
  end
  contribution = contribution or {}

  -- Drop this plugin's previous sources before adding the new ones, so a
  -- second setup() replaces rather than duplicates.
  local kept = {}
  for _, entry in ipairs(sources) do
    if entry.name ~= name then
      kept[#kept + 1] = entry
    end
  end
  sources = kept

  local kept_positions = {}
  for _, entry in ipairs(positions) do
    if entry.name ~= name then
      kept_positions[#kept_positions + 1] = entry
    end
  end
  positions = kept_positions

  for _, entry in ipairs(contribution.sources or {}) do
    local fn, on_request = normalize(entry)
    if fn then
      sources[#sources + 1] = { name = name, fn = fn, on_request = on_request }
    end
  end

  for target_type, fn in pairs(contribution.previews or {}) do
    if type(fn) == "function" then
      previews[target_type] = { name = name, fn = fn }
    end
  end

  for _, entry in ipairs(contribution.positions or {}) do
    local fn, on_request = normalize(entry)
    if fn then
      positions[#positions + 1] = { name = name, fn = fn, on_request = on_request }
    end
  end
end

--- Ask every registered source, in registration order, for the target under
--- the cursor. The first one that answers wins.
---@param bufnr integer
---@param row integer 1-based
---@param col integer 0-based
---@return string|nil target
---@return table|nil extra fields the source wants carried on the record
function M.source_at(bufnr, row, col, opts)
  local force = type(opts) == "table" and opts.force == true
  for _, entry in ipairs(sources) do
    -- An `on_request` source is skipped on the automatic trigger: its author
    -- said its answer is expensive, and only they could know.
    if force or not entry.on_request then
      -- `pcall`: a broken contribution from one plugin must not take the
      -- hover down for every other.
      local ok, target, extra = pcall(entry.fn, bufnr, row, col)
      if ok and type(target) == "string" and target ~= "" then
        return target, extra
      end
    end
  end
  return nil
end

--- The registered preview for `target_type`, if a plugin claimed it.
---@param target_type string
---@return function|nil
function M.preview_for(target_type)
  local entry = previews[target_type]
  return entry and entry.fn or nil
end

--- Ask every registered *position* preview, in registration order, for
--- something to say about this cursor position. The first one that answers
--- wins.
---
--- Asked only after every source has declined, because a target is the more
--- specific reading of the same place: on `./docs/x.md` inside a deprecated
--- call, the file is what the reader pointed at.
---
--- Unlike a source this returns finished content rather than a string to
--- classify -- there is nothing to classify, which is the entire point of the
--- kind. See `Hover.PositionFn`.
---@param bufnr integer
---@param row integer 1-based
---@param col integer 0-based
---@return Hover.Content|nil content
---@return string|nil name the plugin that answered, for the dismissal identity
function M.position_at(bufnr, row, col, opts)
  local force = type(opts) == "table" and opts.force == true
  for _, entry in ipairs(positions) do
    if force or not entry.on_request then
      -- `pcall` for the same reason as `source_at`: one broken contribution
      -- must not take the hover down for every other.
      local ok, content = pcall(entry.fn, bufnr, row, col)
      if
        ok
        and type(content) == "table"
        and type(content.lines) == "table"
        and #content.lines > 0
      then
        return content, entry.name
      end
    end
  end
  return nil
end

--- Whether any source is registered. `markdown.hover`'s link scanning is the
--- usual one; without it the hover still works from bare paths alone.
---@return boolean
function M.has_sources()
  for _, entry in ipairs(sources) do
    if not entry.on_request then
      return true
    end
  end
  return false
end

--- Whether any position preview is registered. Separate from `has_sources`
--- because the two answer different questions: the trigger needs to know
--- whether *anything* could answer, and a buffer with only a position
--- preview registered is still a buffer worth waking for.
---@return boolean
function M.has_positions()
  for _, entry in ipairs(positions) do
    if not entry.on_request then
      return true
    end
  end
  return false
end

--- Drop every registration. Tests only.
---@return nil
function M.reset()
  sources, previews, positions = {}, {}, {}
end

return M
