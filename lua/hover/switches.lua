---@module 'hover.switches'
---@brief Every runtime on/off switch, declared once.
---@description
--- One table drives the public API (`hover.set`/`hover.enabled`), the
--- `:Hover <feature> <state>` routes, their `<Tab>` completion, the
--- `:Hover status` report and the `:checkhealth hover` section. A ninth
--- switch is one entry here and nothing else -- and dispatch, completion and
--- documentation cannot drift apart, because there is only one of them
--- (`UI-20`, `UI-21`).
---
--- That claim was not quite true until the eighth switch was added and
--- proved it: `usrcmds.route_path` was a hand-written mapping of which
--- switches nest under which, so `code` landed as a bare top-level route
--- rather than under `paths`, and nothing failed. It reads
--- `implies` now, so the command tree is derived from this table like
--- everything else -- see the note there.
---
--- **Implication runs upward only.** Turning `fetch` on turns `web` on, and
--- `web` turns `links` on: fetching with no float to show it in would do the
--- disclosure and none of the good. The downward direction is *not* written
--- here, because `hover.config` already answers it on the read side --
--- `config.web_enabled()` is `links_enabled() and links.web`, so switching
--- `links` off silences web links without editing their flag. Turning
--- `links` back on then restores whatever `web` was, rather than quietly
--- demoting it.
---
--- **Every change drops the preview cache.** It is keyed by what a target
--- is, not by how it was rendered, so a stale entry would answer with the
--- old preview and make the switch look broken -- see `hover.cache`.
---
---@see hover.config
---@see hover.bindings.usrcmds

local M = {}

--- One switchable feature: where its flag lives, what turning it on
--- implies, and what to say about it.
---@class Hover.Switch
---@field path string[] # Key path into the merged options table.
---@field implies? string # Switch that must also be on for this one to mean anything.
---@field label string # Short noun phrase, used by `status` and `:checkhealth`.
---@field on_msg string # Announced when it is switched on.
---@field off_msg string # Announced when it is switched off.
---@field desc string # Route description; also the `<Tab>` help text.

---@type table<string, Hover.Switch>
local SWITCHES = {
  links = {
    path = { "links", "enabled" },
    label = "link targets",
    on_msg = "link targets hover",
    off_msg = "link targets do not hover",
    desc = "whether a target written with link syntax hovers at all",
  },
  web = {
    path = { "links", "web" },
    implies = "links",
    label = "web links",
    on_msg = "web links hover (offline: host, path, query -- nothing leaves the machine)",
    off_msg = "web links do not hover",
    desc = "whether http(s) links hover (off by default: documentation is made of links)",
  },
  fetch = {
    path = { "links", "fetch" },
    implies = "web",
    label = "link fetching",
    on_msg = "web links hover, fetching status code and page title",
    off_msg = "web links are parsed offline only",
    desc = "fetch a hovered link for its status code and page title (implies `links web on`)",
  },
  paths = {
    path = { "paths", "enabled" },
    label = "bare paths",
    on_msg = "paths written without link syntax hover",
    off_msg = "only link syntax starts a hover",
    desc = "whether a path written in prose or a comment hovers",
  },
  missing = {
    path = { "paths", "missing" },
    implies = "paths",
    label = "broken-target marker",
    on_msg = "text that is unambiguously a path is marked when it resolves to nothing",
    off_msg = "a path that resolves to nothing stays silent",
    desc = "whether a bare path that resolves to nothing is reported as broken",
  },
  code = {
    path = { "paths", "code" },
    implies = "paths",
    label = "paths in code",
    on_msg = "paths hover anywhere in a source file, expressions included",
    off_msg = "in a parsed buffer, paths hover in comments and strings only",
    desc = "whether a bare path hovers inside executable code, not just comments and strings",
  },
  positions = {
    path = { "positions" },
    label = "position previews",
    on_msg = "registered plugins may answer for a position with no target",
    off_msg = "only targets hover",
    desc = "whether a plugin may say something about a cursor position that points at nothing",
  },
  images = {
    path = { "inline_images" },
    label = "inline images",
    on_msg = "pictures and PDF pages are drawn into the float",
    off_msg = "pictures are described, not drawn",
    desc = "whether pictures and rasterized PDF pages are drawn into the float",
  },
  office = {
    path = { "office", "convert" },
    label = "office rendering",
    on_msg = "office documents render via PDF (the first use starts LibreOffice)",
    off_msg = "office documents show a badge only",
    desc = "render office documents through a PDF instead of showing a badge",
  },
}

--- The order `status` and `:checkhealth` list them in: the hierarchy, read
--- top down, rather than whatever `pairs` happens to produce.
---@type string[]
local ORDER =
  { "links", "web", "fetch", "paths", "missing", "code", "positions", "images", "office" }

--- Every switch name, in display order.
---@return string[]
function M.names()
  return vim.deepcopy(ORDER)
end

--- The declaration for one switch, or nil if there is no such switch.
---@param name string
---@return Hover.Switch|nil
function M.spec(name)
  return SWITCHES[name]
end

---@internal
--- Read a switch's flag out of the *effective* configuration -- the one that
--- folds in `vim.g.hover_disable` and the implication chain. Deliberately
--- not a raw table lookup: `web` being `true` in the options while `links`
--- is off does not mean web links hover.
---@param name string
---@return boolean
local function effective(name)
  local config = require("hover.config")
  local readers = {
    links = config.links_enabled,
    web = config.web_enabled,
    fetch = config.fetch_enabled,
    paths = config.paths_enabled,
    missing = config.missing_enabled,
    images = config.images_enabled,
    office = config.office_enabled,
  }
  local read = readers[name]
  return read ~= nil and read() == true
end

--- Whether `name` is in effect right now, implications included.
---@param name string
---@return boolean
function M.enabled(name)
  return effective(name)
end

---@internal
--- Write `value` at a switch's key path in the merged options table,
--- creating the intermediate tables a partially configured options table may
--- be missing.
---@param path string[]
---@param value boolean
---@return nil
local function write(path, value)
  local node = require("hover.config").raw()
  for i = 1, #path - 1 do
    local key = path[i]
    if type(node[key]) ~= "table" then
      node[key] = {}
    end
    node = node[key]
  end
  node[path[#path]] = value
end

--- Turn a switch on, off, or over.
---
--- Returns `nil` plus a message for an unknown name rather than `false`:
--- "there is no such switch" and "the switch is now off" are different
--- answers and must not collapse onto one value (`ERR-10`).
---@param name string
---@param on? boolean explicit state; omitted flips the current one
---@param opts? { silent?: boolean } suppress the announcement (used by `status`)
---@return boolean|nil on, string|nil err
function M.set(name, on, opts)
  local spec = SWITCHES[name]
  if not spec then
    return nil, ("unknown switch %q"):format(tostring(name))
  end
  opts = opts or {}

  if on == nil then
    on = not effective(name)
  end

  write(spec.path, on)
  -- Upward only: switching a level on switches on everything it needs to
  -- mean anything. Switching off touches nothing else, so turning the parent
  -- back on restores the child's configured state instead of demoting it.
  if on and spec.implies then
    M.set(spec.implies, true, { silent = true })
  end

  require("hover.cache").reset()

  if not opts.silent then
    -- Announced, because "off" is otherwise invisible: nothing on screen
    -- tells a switched-off preview apart from a line that simply has no
    -- target on it, and a switch whose state cannot be seen gets reported as
    -- a broken feature a week later.
    require("hover.notify").info(on and spec.on_msg or spec.off_msg)
  end

  return on
end

--- Every switch's current state, in display order, for `:Hover status` and
--- `:checkhealth hover`.
---@return { name: string, label: string, enabled: boolean, implies: string|nil }[]
function M.status()
  local out = {}
  for _, name in ipairs(ORDER) do
    local spec = SWITCHES[name]
    out[#out + 1] = {
      name = name,
      label = spec.label,
      enabled = effective(name),
      implies = spec.implies,
    }
  end
  return out
end

return M
