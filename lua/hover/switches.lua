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
---@field auto_type? string # The `auto_hover` name that *also* has to be on before the automatic trigger opens anything for this switch. A second axis, not an implication: see `M.set`.
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
    auto_type = "url",
    label = "web links",
    on_msg = "web links hover (offline: host, path, query -- nothing leaves the machine)",
    off_msg = "web links do not hover",
    desc = "whether http(s) links hover (off by default: documentation is made of links)",
  },
  fetch = {
    path = { "links", "fetch" },
    implies = "web",
    auto_type = "url",
    label = "link fetching",
    on_msg = "web links hover, fetching status code and page title",
    off_msg = "web links are parsed offline only",
    desc = "fetch a hovered link for its status code and page title (implies `links web on`)",
  },
  shot = {
    path = { "links", "shot", "enabled" },
    -- `web`, and never `fetch`. A fetch is one `curl` GET with a 2 MB cap; a
    -- render *executes* the page. Implying it from `fetch` would mean a
    -- reader who asked for a status code got a browser, which is the one
    -- thing this must not be able to do.
    implies = "web",
    auto_type = "url",
    label = "page screenshots",
    on_msg = "a hovered link is rendered by a headless browser -- its JavaScript runs, and every subresource it names is fetched",
    off_msg = "links are previewed as text; no browser is started",
    desc = "render a hovered link in a headless browser and draw the page into the float",
  },
  eager = {
    path = { "links", "shot", "eager" },
    implies = "shot",
    auto_type = "url",
    label = "screenshots unasked",
    on_msg = "the trigger may start a browser by itself -- measured 0.7 s to start, and 4-20 s for a page",
    off_msg = "a page is rendered only for `:Hover show`",
    desc = "let the automatic trigger render a page, not only an explicit request",
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
    auto_type = "missing",
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
    auto_type = "position",
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
    auto_type = "office",
    label = "office rendering",
    on_msg = "office documents render via PDF (the first use starts LibreOffice)",
    off_msg = "office documents show a badge only",
    desc = "render office documents through a PDF instead of showing a badge",
  },
}

--- The order `status` and `:checkhealth` list them in: the hierarchy, read
--- top down, rather than whatever `pairs` happens to produce.
---@type string[]
local ORDER = {
  "links",
  "web",
  "fetch",
  "shot",
  "eager",
  "paths",
  "missing",
  "code",
  "positions",
  "images",
  "office",
}

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

--- The command tree path for one switch: its implication chain, read
--- outside in. `fetch` implies `web` implies `links`, so it is
--- `{ "links", "web", "fetch" }` -- the tokens of `:Hover links web fetch`.
---
--- **Here rather than in the command module, because it has two readers.**
--- It was a local in `hover.bindings.usrcmds`, which was fine while the
--- command tree was the only thing that needed it. `:Hover status` needs the
--- same answer -- a row saying `broken-target marker` is unusable unless it
--- also says which words to type -- and a second derivation of the same
--- chain is exactly the drift this table exists to prevent. So it lives with
--- the table it reads.
---
--- The `seen` guard is for a chain that points at itself. Nothing in
--- `SWITCHES` does today; a cycle here would hang command registration at
--- startup, which is a bad way to find out.
---@param name string
---@return string[]
function M.route(name)
  local path = { name }
  local seen = { [name] = true }
  local cursor = SWITCHES[name]

  while cursor and cursor.implies and not seen[cursor.implies] do
    table.insert(path, 1, cursor.implies)
    seen[cursor.implies] = true
    cursor = SWITCHES[cursor.implies]
  end

  return path
end

---@internal
--- The raw flag at a switch's `path` in the merged configuration.
---
--- Raw on purpose, and never the answer on its own: `web` being `true` in the
--- options while `links` is off does not mean web links hover. `effective`
--- below is what folds in the chain.
---@param path string[]
---@return any
local function flag_at(path)
  local node = require("hover.config").get()
  for _, key in ipairs(path) do
    if type(node) ~= "table" then
      return nil
    end
    node = node[key]
  end
  return node
end

--- **Derived, after being a hand-written table that a switch fell out of.**
--- This used to map each name to a `config.*_enabled` reader by hand, and a
--- switch added without a matching entry read as permanently `off`: `name`
--- was simply not in the table, and `read ~= nil` answered false. `code`
--- hid it -- its default is off, so the wrong answer was the right one --
--- and `positions` exposed it, reported off while being on. `:Hover status`
--- and the `:checkhealth` section both read from here, so both lied.
---
--- Third consumer of `SWITCHES` to fall behind it this way (`ac50599` was
--- the command tree). The lesson is the same and it is worth writing down
--- once more: "one table feeds everything" holds only for the consumers that
--- actually read the table.
---
--- Every switch declares its own `path` and its own `implies`, which is all
--- an answer needs -- the flag itself, and the chain above it. The merged
--- configuration always carries a concrete boolean at every switch path,
--- because `DEFAULTS` provides one and the merge only overwrites, so `== true`
--- is exact rather than a default-direction guess.
---@param name string
---@return boolean
local function effective(name)
  local spec = SWITCHES[name]
  if not spec then
    return false
  end
  if flag_at(spec.path) ~= true then
    return false
  end
  if spec.implies then
    return effective(spec.implies)
  end
  return true
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

  local config = require("hover.config")

  -- Snapshotted before the write, and compared after: what decides whether
  -- the cache is stale is whether this switch changes anything a *preview*
  -- reads. See below.
  local before = vim.inspect(config.preview_opts())

  write(spec.path, on)
  -- Upward only: switching a level on switches on everything it needs to
  -- mean anything. Switching off touches nothing else, so turning the parent
  -- back on restores the child's configured state instead of demoting it.
  if on and spec.implies then
    M.set(spec.implies, true, { silent = true })
  end

  -- **Derived, not written down.** A hand-maintained "switch X invalidates
  -- class Y" table would be a second table that can fall behind this one,
  -- silently -- the exact shape of the `route_path` and `effective` bugs.
  --
  -- The question a table would have answered is answerable from the
  -- configuration itself: a cached preview can only be stale if the inputs a
  -- preview is given have changed, and those inputs *are*
  -- `config.preview_opts()`. So compare it across the write.
  --
  -- That splits the switches along a real line rather than a listed one.
  -- `images`, `office` and `fetch` appear in `preview_opts` -- they change how
  -- a target is rendered, and every cached rendering is suspect. `links`,
  -- `paths`, `missing`, `code` and `positions` do not: they decide what
  -- *counts as a target*, and a preview built for a target that is still the
  -- same target is still correct. Toggling `paths code` used to throw away
  -- rasterized PDF pages it could not possibly affect.
  --
  -- Conservative in the safe direction on purpose: any difference at all
  -- drops everything. Going finer -- dropping only the target types a given
  -- option feeds -- would need to know which preview reads which option,
  -- which is the table this avoids.
  if vim.inspect(config.preview_opts()) ~= before then
    require("hover.cache").reset()
  end

  if not opts.silent then
    -- Announced, because "off" is otherwise invisible: nothing on screen
    -- tells a switched-off preview apart from a line that simply has no
    -- target on it, and a switch whose state cannot be seen gets reported as
    -- a broken feature a week later.
    require("hover.notify").info(on and M.on_report(name) or spec.off_msg)
  end

  return on
end

--- What switching `name` on actually gets you, second axis included.
---
--- **The message this replaces was true and useless.** `:Hover links web on`
--- announced "web links hover" and then nothing hovered, because
--- `auto_hover.url` is `false` -- a *second* gate that arrived with the
--- `auto_hover` axis on 2026-09-03 and that no switch knew about. Both
--- statements were correct: web links do hover, and the trigger does not open
--- them. From the reader's chair that is a broken feature, and the only way
--- to find out was to read `DEFAULTS`.
---
--- **Not folded into `implies`, and that is the whole point of the field.**
--- Implication runs upward through switches that answer the same question --
--- "may this hover at all" -- and turning a parent on is free of surprises.
--- `auto_hover` answers a different one, "may this open *without being
--- asked*", and a switch silently flipping it would undo a standing
--- preference the reader set on purpose. So it is said rather than done:
--- `:Hover show` already answers in full, and one command turns the trigger
--- on for good.
---
--- Public because two callers want the same sentence -- the announcement
--- here, and `:checkhealth hover`, which lists the switches without setting
--- any of them.
---@param name string
---@return string
function M.on_report(name)
  local spec = SWITCHES[name]
  if not spec then
    return ("unknown switch %q"):format(tostring(name))
  end
  if not spec.auto_type or require("hover.config").auto_hover_for(spec.auto_type) then
    return spec.on_msg
  end
  return spec.on_msg
    .. ("\n  ...but %s targets still do not open by themselves: `:Hover auto %s`, or `:Hover show`."):format(
      spec.auto_type,
      spec.auto_type
    )
end

--- Every switch's current state, in display order, for `:Hover status` and
--- `:checkhealth hover`.
---
--- `enabled` folds in the implication chain and is the answer to "does this
--- do anything right now". `flag` is the switch's own value before that fold,
--- and the two differ in exactly one interesting case: a switch that is set
--- while the switch above it is off. That reads as plain `off` everywhere,
--- and then turning the parent on appears to turn on something nobody asked
--- for -- so a report that can tell the two apart says so (`hover.status_view`
--- draws it as a third glyph).
---
--- `route` is the words to type at it. A row labelled `broken-target marker`
--- is a fact the reader cannot act on; `:Hover paths missing` is.
---
--- `auto_type` is the third state this report can be in, and the one that
--- reads as a defect: a switch that is on while the type it produces is not
--- in `auto_hover`, so the preview exists and the trigger never asks for it.
--- Carried here rather than re-derived by each reader -- the reason every
--- other field is.
---@return { name: string, label: string, enabled: boolean, flag: boolean, implies: string|nil, auto_type: string|nil, route: string[] }[]
function M.status()
  local out = {}
  for _, name in ipairs(ORDER) do
    local spec = SWITCHES[name]
    out[#out + 1] = {
      name = name,
      label = spec.label,
      enabled = effective(name),
      flag = flag_at(spec.path) == true,
      implies = spec.implies,
      auto_type = spec.auto_type,
      route = M.route(name),
    }
  end
  return out
end

return M
