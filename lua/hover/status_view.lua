---@module 'hover.status_view'
---@brief `:Hover status` as a board you can act on, not a message you read.
---@description
--- Every switch, its state, and **the words to type at it**, on one screen --
--- and `<CR>` on a row does the typing. It replaces a `vim.notify` dump and
--- then a one-shot chooser, both of which had the same defect: they reported
--- a state in a vocabulary the command line does not speak.
---
--- **That defect was reported, not theorised.** Someone read `link targets
--- on` / `web links off`, typed `:Hover links on` at it, and found `web
--- links` still off -- because `web` is its own switch, filed under `links`
--- in the command tree (`:Hover links web on`). Nothing was broken; the label
--- and the route were simply different strings, and only one of them was on
--- screen. So every row here carries its route, and the indentation *is* the
--- implication chain -- a row indented under another one cannot mean anything
--- until that one is on.
---
--- **Three glyphs, not two.** `switches.status().enabled` folds in the chain,
--- so a switch that is set while its parent is off reads as a plain `off` --
--- and then turning the parent on appears to switch on something nobody asked
--- for. `◐` is that state: set here, held off above. It is the one thing a
--- flat on/off list structurally cannot say, and it is why `status()` reports
--- `flag` beside `enabled`.
---
--- **Actions, and `?` for the list of them.** The window carries a `winbar`
--- legend of the keys that fit, and `?` opens the rest -- after
--- `reposcope.nvim`'s status overview, the same shape because it is the same
--- problem: a report worth acting on wants its verbs where the eye already
--- is. Both the legend and the panel are generated from one table, so neither
--- can advertise a key that is not bound.
---
--- Every write goes through `hover.switches.set`, `hover.set_mode` or
--- `hover.set_auto`. There is no second toggle path: the implication chain,
--- the cache drop and the announcement live there, and a board that wrote
--- flags directly would skip all three.
---
--- **`pcall` around the UI kit, though lib.nvim is a hard dependency.** It is
--- pinned by commit, so a present-but-older lib.nvim without the kit is a
--- real state rather than a hypothetical -- the same reason `hover.health`
--- checks for partial installs. Without it `open()` returns false and the
--- caller falls back to the message.
---
---@see hover.switches
---@see hover.bindings.usrcmds

local M = {}

local switches = require("hover.switches")

---@internal
--- Deferred back-reference, the same shape `hover.bindings.usrcmds` uses:
--- this module is reached from the command layer, which `hover` itself pulls
--- in during `enable()`.
---@return table
local function hover()
  return require("hover")
end

--- Every highlight group the board defines: the name this module uses for it,
--- the group's real name, and the group it links to. Linked with
--- `default = true`, so a colorscheme -- or the user -- can override any of
--- them without being clobbered on the next redraw, and pointed at semantic
--- groups rather than fixed colours, which have no reading on a light
--- background.
---
--- **One table with the names written out, rather than two keyed off each
--- other.** `docs/BINDINGS.md` tabulates these, and `TESTS/docs_spec.lua`
--- reads them back out of this file as text to hold the table to it -- a
--- computed key (`[HL.header] = "Title"`) is not a name that spec, or a
--- reader grepping for `HoverStatusHeader`, can find. The two lookups below
--- are derived from this, so neither can list a group the other does not.
---@type table<string, string[]>
local HL_SPEC = {
  header = { "HoverStatusHeader", "Title" },
  on = { "HoverStatusOn", "DiagnosticOk" },
  off = { "HoverStatusOff", "Comment" },
  held = { "HoverStatusHeld", "DiagnosticWarn" },
  label = { "HoverStatusLabel", "Normal" },
  route = { "HoverStatusRoute", "NonText" },
  muted = { "HoverStatusMuted", "Comment" },
  key = { "HoverStatusKey", "Special" },
}

---@type table<string, string> Internal name -> group name.
local HL = {}
---@type table<string, string> Group name -> the group it links to.
local HL_LINK = {}
for name, entry in pairs(HL_SPEC) do
  HL[name] = entry[1]
  HL_LINK[entry[1]] = entry[2]
end

---@internal
--- Install the highlight links. `default = true` means a colorscheme loaded
--- afterwards still wins, so this is safe to run on every open.
---@return nil
local function ensure_highlights()
  for group, target in pairs(HL_LINK) do
    pcall(vim.api.nvim_set_hl, 0, group, { link = target, default = true })
  end
end

--- The first column, and the whole of what it means. `held` is the state a
--- two-glyph list cannot show; see the note at the top.
local GLYPH = { on = "●", off = "○", held = "◐" }

--- Column geometry, in display cells: the label column is wide enough for the
--- longest label at the deepest indent, and the route column begins where the
--- state column ends. The state column fits `manual`, which is the widest
--- thing that goes in it -- the mode row spends it on the mode's name rather
--- than on `on`, which says nothing there that the glyph does not.
local LABEL_W = 30
local STATE_W = 7

---@internal
--- One actionable line of the board.
---@class Hover.Status.Row
---@field kind "switch"|"mode"|"auto" # which setter acts on it
---@field name string # switch name, target type, or the current mode
---@field route string # the command shown on the row, and what `y` yanks

---@internal
--- Render one row: glyph, indented label, state, route.
---
--- Returns byte offsets rather than cell columns, because that is what
--- `nvim_buf_set_extmark` takes and the glyphs above are three bytes each --
--- getting that wrong shifts every highlight on the line.
---@param depth integer indent level; the switch's distance down the chain
---@param state "on"|"off"|"held"
---@param label string
---@param route string
---@param state_text? string what the state column says; defaults to the state
---@return string line, { col: integer, end_col: integer, hl: string }[] spans
local function row_line(depth, state, label, route, state_text)
  local glyph = GLYPH[state]
  local text = ("  "):rep(depth) .. label
  local head = (" %s %-" .. LABEL_W .. "s"):format(glyph, text)
  local mid = ("%-" .. STATE_W .. "s"):format(state_text or (state == "on" and "on" or "off"))
  local line = head .. mid .. route

  local glyph_start = 1
  local glyph_end = glyph_start + #glyph
  local state_start = #head
  local spans = {
    { col = glyph_start, end_col = glyph_end, hl = HL[state] },
    { col = glyph_end, end_col = state_start, hl = state == "on" and HL.label or HL.muted },
    { col = state_start, end_col = state_start + #mid, hl = HL[state] },
    { col = state_start + #mid, end_col = -1, hl = HL.route },
  }
  return line, spans
end

---@internal
--- Build the whole board in one pass: the lines, their highlights, and which
--- row each line belongs to. One pass because the three are the same fact
--- three times, and a second walk is a second place to fall out of step.
---@return string[] lines, table[] hls, table<integer, Hover.Status.Row> rows
local function render()
  local status = hover().status()
  local lines, hls, rows = {}, {}, {}
  local any_held = false

  ---@param text string
  ---@param hl string|nil
  ---@return integer index
  local function push(text, hl)
    lines[#lines + 1] = text
    if hl then
      hls[#hls + 1] = { row = #lines - 1, col = 0, end_col = -1, hl = hl }
    end
    return #lines
  end

  ---@param depth integer
  ---@param state string
  ---@param label string
  ---@param route string
  ---@param row Hover.Status.Row
  ---@param state_text? string
  ---@return nil
  local function push_row(depth, state, label, route, row, state_text)
    local line, spans = row_line(depth, state, label, route, state_text)
    local index = push(line)
    for _, span in ipairs(spans) do
      hls[#hls + 1] = { row = index - 1, col = span.col, end_col = span.end_col, hl = span.hl }
    end
    rows[index] = row
  end

  -- The mode's name goes in the state column, not in the label: "mode" is
  -- what the row is, `manual` is what it is set to, and `● manual on` says
  -- "on" about a mode that deliberately opens nothing by itself.
  push("")
  push("  MODE", HL.header)
  push_row(0, status.mode == "off" and "off" or "on", "mode", ":Hover mode", {
    kind = "mode",
    name = status.mode,
    route = ":Hover mode",
  }, status.mode)

  push("")
  push("  SWITCHES", HL.header)
  for _, sw in ipairs(status.switches) do
    local state = sw.enabled and "on" or (sw.flag and "held" or "off")
    if state == "held" then
      any_held = true
    end
    local route = ":Hover " .. table.concat(sw.route, " ")
    -- The indent is the route's own depth, so the picture and the words to
    -- type are the same fact rather than two that have to be kept in step.
    push_row(#sw.route - 1, state, sw.label, route, {
      kind = "switch",
      name = sw.name,
      route = route,
    })
  end

  if type(status.auto) == "table" and #status.auto > 0 then
    push("")
    push("  OPENS BY ITSELF", HL.header)
    for _, entry in ipairs(status.auto) do
      local route = ":Hover auto " .. entry.name
      push_row(0, entry.enabled and "on" or "off", entry.name, route, {
        kind = "auto",
        name = entry.name,
        route = route,
      })
    end
  end

  -- Only when there is one to explain: a legend for a glyph that is not on
  -- screen is a line of noise on every other opening.
  if any_held then
    push("")
    push(("  %s set here, held off by the row above it"):format(GLYPH.held), HL.muted)
  end

  return lines, hls, rows
end

--- Namespace for the board's highlights, cleared on every redraw.
local NS = vim.api.nvim_create_namespace("hover_status")

---@internal
--- Replace the board's content in place. The cursor stays where it is,
--- because the line count never changes between two redraws of the same
--- board -- toggling a switch changes a glyph and a word, not the shape.
---@param bufnr integer
---@param state table
---@return nil
local function redraw(bufnr, state)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local lines, hls, rows = render()
  state.rows = rows

  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].modified = false

  vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
  for _, hl in ipairs(hls) do
    local end_col = hl.end_col
    if end_col < 0 then
      end_col = #(lines[hl.row + 1] or "")
    end
    pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, hl.row, hl.col, {
      end_col = end_col,
      hl_group = hl.hl,
    })
  end
end

---@internal
--- The row the cursor is on, or nil on a header, a blank line or the legend.
---@param state table
---@return Hover.Status.Row|nil
local function row_at_cursor(state)
  local line = vim.api.nvim_win_get_cursor(0)[1]
  return state.rows[line]
end

---@internal
--- Apply one state to the row under the cursor; `on` omitted flips it.
---
--- Every branch goes through the public setter for its kind, which is what
--- keeps the implication chain, the cache drop and the announcement in one
--- place each rather than in two.
---@param state table
---@param on boolean|nil
---@return nil
local function apply(state, on)
  local row = row_at_cursor(state)
  if not row then
    return
  end

  if row.kind == "switch" then
    switches.set(row.name, on)
  elseif row.kind == "auto" then
    -- `set_auto(type)` only toggles, so an explicit `+`/`-` has to read the
    -- current state first and do nothing when it already matches. Announced
    -- here because that setter reports rather than notifies -- the route it
    -- was written for prints its return value.
    local current = require("hover.config").auto_hover_for(row.name)
    if on == nil or current ~= on then
      local report, err = hover().set_auto(row.name)
      require("hover.notify")[err and "warn" or "info"](err or report)
    end
  elseif row.kind == "mode" then
    -- `+`/`-` on the mode row are the two ends of the axis rather than steps
    -- through it: "on" is the mode the plugin is meant to be used in, and
    -- "off" is the one someone reaches for in a hurry. Bare `<CR>` cycles,
    -- which is the only way to reach `manual` from here.
    local want
    if on == true then
      want = "auto"
    elseif on == false then
      want = "off"
    else
      want = ({ auto = "manual", manual = "off", off = "auto" })[hover().mode()] or "auto"
    end
    local _, err = hover().set_mode(want)
    if err then
      require("hover.notify").warn(err)
    end
  end

  redraw(state.bufnr, state)
end

---@internal
--- Move to the next or previous actionable row, wrapping at both ends.
--- Headers and blanks are lines `j` lands on and nothing acts on, so `<Tab>`
--- skips them; `j` and `k` are left alone, because a board is also read.
---@param state table
---@param delta 1|-1
---@return nil
local function step(state, delta)
  local total = vim.api.nvim_buf_line_count(state.bufnr)
  local line = vim.api.nvim_win_get_cursor(0)[1]
  for _ = 1, total do
    line = line + delta
    if line > total then
      line = 1
    elseif line < 1 then
      line = total
    end
    if state.rows[line] then
      pcall(vim.api.nvim_win_set_cursor, 0, { line, 0 })
      return
    end
  end
end

---@internal
--- Forward declaration: the `?` panel is one of the entries in the table it
--- lists, so the table cannot be built before it exists.
---@type fun(): nil
local show_keys

--- Every key the board binds. `label` is what the `winbar` advertises; an
--- entry without one is bound and listed under `?` but kept out of the
--- legend, which is how that line stays inside one row. Both readers are
--- generated from here, so neither can offer a key that is not bound.
---@type { keys: string[], label: string|nil, desc: string, run: fun(state: table) }[]
local ACTIONS = {
  {
    keys = { "<CR>", "<Space>", "<2-LeftMouse>" },
    label = "<CR> Toggle",
    desc = "Toggle the row under the cursor (the mode row cycles auto/manual/off)",
    run = function(state)
      apply(state, nil)
    end,
  },
  {
    keys = { "+" },
    label = "+ On",
    desc = "Turn the row under the cursor on (on the mode row: auto)",
    run = function(state)
      apply(state, true)
    end,
  },
  {
    keys = { "-" },
    label = "- Off",
    desc = "Turn the row under the cursor off (on the mode row: off)",
    run = function(state)
      apply(state, false)
    end,
  },
  {
    keys = { "<Tab>" },
    desc = "Move to the next actionable row, skipping headers and blanks",
    run = function(state)
      step(state, 1)
    end,
  },
  {
    keys = { "<S-Tab>" },
    desc = "Move to the previous actionable row",
    run = function(state)
      step(state, -1)
    end,
  },
  {
    keys = { "y" },
    label = "y Yank",
    desc = "Yank this row's `:Hover ...` command",
    run = function(state)
      local row = row_at_cursor(state)
      if not row then
        return
      end
      vim.fn.setreg("+", row.route)
      vim.fn.setreg('"', row.route)
      require("hover.notify").info("yanked " .. row.route)
    end,
  },
  {
    keys = { "r" },
    desc = "Re-read the configuration and redraw",
    run = function(state)
      redraw(state.bufnr, state)
    end,
  },
  {
    keys = { "?" },
    label = "? Keys",
    desc = "Show every key this board binds",
    run = function()
      show_keys()
    end,
  },
}

---@internal
--- The `?` panel: the keys, generated from `ACTIONS`, plus the glyph legend
--- and the one sentence about indentation. Those three are what a first-time
--- reader of this board needs and cannot guess from it.
---@return nil
show_keys = function()
  local ok, kit = pcall(require, "lib.nvim.ui.kit")
  if not ok or type(kit) ~= "table" or type(kit.viewer) ~= "function" then
    return
  end

  local entries, widest = {}, 0
  for _, action in ipairs(ACTIONS) do
    local lhs = table.concat(action.keys, ", ")
    entries[#entries + 1] = { lhs = lhs, desc = action.desc }
    widest = math.max(widest, #lhs)
  end
  entries[#entries + 1] = { lhs = "q, <Esc>", desc = "Close the board" }
  widest = math.max(widest, #"q, <Esc>")

  local lines = { "", "  Keys", "" }
  for _, entry in ipairs(entries) do
    lines[#lines + 1] = ("  %-" .. widest .. "s   %s"):format(entry.lhs, entry.desc)
  end

  vim.list_extend(lines, {
    "",
    "  Glyphs",
    "",
    ("  %s  on"):format(GLYPH.on),
    ("  %s  off"):format(GLYPH.off),
    ("  %s  set here, but held off by the row above it"):format(GLYPH.held),
    "",
    "  Indentation is the implication chain: a row cannot do anything",
    "  until the row it sits under is on. Turning one on turns those on",
    "  with it; turning one off leaves them set, so the parent restores",
    "  what you had rather than quietly demoting it.",
    "",
  })

  local width = 40
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end

  kit.viewer({
    lines = lines,
    title = "Hover status keys",
    filetype = "hover-help",
    width = math.min(width + 2, math.floor(vim.o.columns * 0.9)),
    height = math.min(#lines, math.floor(vim.o.lines * 0.8)),
  })
end

--- Width of the separator between two legend entries, in display cells.
local LEGEND_SEP_W = 5

---@internal
--- The `winbar` legend, fitted to the window's width.
---
--- Fitted rather than emitted whole, and that is not a cosmetic choice:
--- Neovim truncates an over-long `winbar` **from the left** and marks the cut
--- with a bare `<`, so the overflow eats the first entries -- the ones most
--- worth showing. Entries are dropped from the right instead, except the last
--- one (`? Keys`), which is pinned because it is how everything dropped here
--- is still reachable. What survives is then centred, so the gap before the
--- first entry matches the gap after the last.
---@param width integer window width in display cells
---@return string
local function legend(width)
  local labels = {}
  for _, action in ipairs(ACTIONS) do
    if action.label then
      labels[#labels + 1] = action.label
    end
  end
  if #labels == 0 then
    return ""
  end

  local pinned = table.remove(labels)
  local used = vim.fn.strdisplaywidth(pinned)
  local budget = math.max(width, 0) - 4 -- a two-cell margin on either side

  local kept = {}
  for _, label in ipairs(labels) do
    local cost = vim.fn.strdisplaywidth(label) + LEGEND_SEP_W
    if used + cost > budget then
      break
    end
    kept[#kept + 1] = label
    used = used + cost
  end
  kept[#kept + 1] = pinned

  local rendered = {}
  for i, label in ipairs(kept) do
    local key, text = label:match("^(%S+)%s+(.*)$")
    rendered[i] = ("%%#%s#%s %%#%s#%s"):format(HL.key, key, HL.muted, text)
  end

  local lead = math.max(2, math.floor((width - used) / 2))
  return (" "):rep(lead) .. table.concat(rendered, ("%%#%s#  |  "):format(HL.muted))
end

--- The `winbar` expression's entry point.
---
--- Public only because `winbar` has to name something callable from
--- Vimscript: it is set to a `%!` expression rather than to a fixed string,
--- so the legend re-fits itself when the window is resized instead of being
--- frozen at the width the board happened to open with.
---@return string
function M.legend()
  local win = vim.g.statusline_winid
  if not (win and vim.api.nvim_win_is_valid(win)) then
    win = vim.api.nvim_get_current_win()
  end
  return legend(vim.api.nvim_win_get_width(win))
end

---@type string The `winbar` value installed on the board's window.
local WINBAR = "%!v:lua.require'hover.status_view'.legend()"

--- Open the board.
---
--- Returns false when lib.nvim's UI kit is not there to draw one, which is
--- the caller's signal to fall back to the plain message -- exactly the
--- behaviour `:Hover status` had before this module existed.
---@return boolean shown
function M.open()
  local ok, kit = pcall(require, "lib.nvim.ui.kit")
  if not ok or type(kit) ~= "table" or type(kit.surface) ~= "table" then
    return false
  end

  ensure_highlights()

  local lines = render()
  local width = 0
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end

  local opened, surf = pcall(kit.surface.open, {
    lines = lines,
    title = "hover",
    filetype = "hover-status",
    nice_quit = true,
    enter = true,
    focusable = true,
    width = math.min(width + 4, math.floor(vim.o.columns * 0.9)),
    -- +1 for the winbar legend, which otherwise eats a row of content out of
    -- a height sized exactly to the board.
    height = #lines + 1,
    wo = { wrap = false, cursorline = true, winbar = WINBAR },
  })
  if not opened or type(surf) ~= "table" then
    return false
  end

  local state = { bufnr = surf.bufnr, rows = {} }
  redraw(surf.bufnr, state)

  local map = require("lib.nvim.bindings.keymap")
  local opts = { buffer = surf.bufnr, nowait = true }
  for _, action in ipairs(ACTIONS) do
    for _, lhs in ipairs(action.keys) do
      map("n", lhs, function()
        action.run(state)
      end, opts, action.desc)
    end
  end

  -- Opened on the first actionable row rather than on the leading blank: the
  -- board exists to be acted on, and a cursor parked on a header makes the
  -- first `<CR>` a no-op that reads as a broken key.
  step(state, 1)
  return true
end

return M
