---@module 'hover.float'
---@brief The hover window itself: a small, cursor-relative, unfocused float.
---@description
--- Deliberately *not* `lib.nvim.image_preview`'s float: that one is a
--- centred 80% window the user enters and closes with `q`. A hover must be
--- small, appear next to the cursor, never steal focus, and disappear on the
--- next cursor move — otherwise it fights the editing it is supposed to
--- annotate.
---
--- Exactly one hover window exists at a time; opening a second closes the
--- first.

local M = {}

local api = vim.api
local autocmd = require("lib.nvim.bindings.autocmd")
-- `safe_api.is_valid_*` rather than `handle and nvim_*_is_valid(handle)`:
-- it answers false for nil, for a non-number and for a negative handle, so
-- the nil guard stops being a separate condition that a later edit can drop
-- (`LUA-01`, `LUA-11`).
local safe_api = require("lib.nvim.safe_api")

---@type integer|nil
---@type string Prefixed onto a pinned float's title.
local MARKER = "📌 "

local _win = nil
---@type integer|nil
local _buf = nil
---@type integer|nil
local _augroup = nil
---@type (fun())|nil Teardown for whatever was drawn into the window.
local _on_close = nil

--- Highlight groups a preview may ask for on its first line, and what each
--- links to when the user and the colorscheme have said nothing. Defined on
--- demand (see `open`) rather than at load time, so a colorscheme that comes
--- later still wins.
---
--- Three, not one: "this target does not exist" and "the server answered 500"
--- are errors, "this file has no text in it" is a statement of fact about a
--- perfectly healthy file, and colouring the third one red would report a
--- problem that is not there.
---@type table<string, string>
local HL_DEFAULTS = {
  HoverMissing = "DiagnosticError",
  HoverError = "DiagnosticError",
  HoverInfo = "DiagnosticHint",
}

--- Border styles this plugin adds to the ones `nvim_open_win` already knows.
---
--- **Only what Neovim does not have.** `none`, `single`, `double`, `rounded`,
--- `solid` and `shadow` are its own names and are passed straight through --
--- adding a table for them here would be a copy of something the API already
--- answers, and copies are what this repository keeps finding stale.
---
--- What is left is the two shapes a reader has to spell out as eight
--- characters otherwise, and neither is decoration:
---
---   * **`heavy`** is the one that gets asked for. "Make the line thicker" has
---     no name in Neovim, and the eight characters are easy to get wrong in a
---     way that shows only in the corners.
---   * **`ascii`** is a fallback rather than a taste. Box-drawing characters
---     are missing from more fonts and more terminals than their popularity
---     suggests, and a frame drawn as `?` is worse than one drawn as `+`.
---     This is the same machine that turned out not to send Alt chords.
---
--- `dashed` and `block` round the set out at no cost.
---
--- Eight entries, clockwise from the top-left, which is the order
--- `nvim_open_win` documents: topleft, top, topright, right, botright, bottom,
--- botleft, left.
---@type table<string, string[]>
local BORDERS = {
  heavy = { "┏", "━", "┓", "┃", "┛", "━", "┗", "┃" },
  ascii = { "+", "-", "+", "|", "+", "-", "+", "|" },
  dashed = { "┌", "┄", "┐", "┆", "┘", "┄", "└", "┆" },
  block = { "▛", "▀", "▜", "▐", "▟", "▄", "▙", "▌" },
}

---@type string[] Border names `nvim_open_win` understands on its own.
local NATIVE_BORDERS = { "none", "single", "double", "rounded", "solid", "shadow" }

--- Every border name that can be configured, sorted.
---
--- Public because three callers need the same list and none of them should
--- keep its own: the route's completion, the validator below, and the health
--- section. A seventh style is one entry in `BORDERS` and nothing else.
---@return string[]
function M.border_names()
  local out = {}
  for _, name in ipairs(NATIVE_BORDERS) do
    out[#out + 1] = name
  end
  for name in pairs(BORDERS) do
    out[#out + 1] = name
  end
  table.sort(out)
  return out
end

--- Resolve a configured border into what `nvim_open_win` takes.
---
--- A name this module adds becomes its character list; anything else is
--- passed through untouched -- Neovim's own names, and the eight-character
--- list a user writes by hand, which stays supported precisely because a
--- preset table can never cover every taste.
---@param border string|string[]|nil
---@return string|string[]
function M.resolve_border(border)
  if type(border) == "string" and BORDERS[border] then
    return vim.deepcopy(BORDERS[border])
  end
  if border == nil then
    return "rounded"
  end
  return border
end

--- Is a hover window currently open?
---@return boolean
function M.is_open()
  return safe_api.is_valid_window(_win)
end

--- Mark the open float as pinned, or unmark it.
---
--- Visible in the border rather than only in state: a float that stops
--- following the cursor and does not say so reads as a bug -- the same
--- argument that makes every switch announce itself. The marker is a prefix
--- on the existing title, and stripped before it is added again so toggling
--- twice does not stack two of them.
---@param pinned boolean
---@return nil
function M.set_pinned(pinned)
  if not safe_api.is_valid_window(_win) then
    return
  end
  local ok, cfg = pcall(api.nvim_win_get_config, _win)
  if not ok or type(cfg) ~= "table" then
    return
  end

  -- The title comes back as the chunk list `nvim_open_win` stores, not as the
  -- string it was given.
  local text = ""
  if type(cfg.title) == "table" then
    -- Collected and joined rather than concatenated in the loop (`PERF-03`),
    -- which also keeps the result a string for certain -- a chunk whose first
    -- element is missing would otherwise poison it.
    local parts = {}
    for _, chunk in ipairs(cfg.title) do
      parts[#parts + 1] = type(chunk) == "table" and tostring(chunk[1] or "") or tostring(chunk)
    end
    text = table.concat(parts)
  elseif type(cfg.title) == "string" then
    -- `tostring` rather than the field itself: the window-config type has
    -- `title` as a union, and a guard on a *field* does not narrow it -- so
    -- the assignment reads as possibly nil at the next use.
    text = tostring(cfg.title)
  end

  -- Parenthesised: `gsub` returns the string *and* a count, and passing both
  -- on would make `title` a two-value expression in the concatenation below.
  text = (text:gsub("^" .. vim.pesc(MARKER), ""))
  local title = pinned and (MARKER .. text) or text
  if title == "" then
    return
  end
  pcall(api.nvim_win_set_config, _win, { title = title, title_pos = "left" })
end

--- Change the border of the float that is already open.
---
--- Exists so `:Hover border heavy` shows the answer rather than promising it
--- for the next hover: trying styles is the whole reason to have names for
--- them, and a setting that only takes effect later cannot be tried at all.
---
--- The ring stays one cell wide whatever the characters are, so nothing about
--- the geometry moves -- which is why this is a config change on the live
--- window rather than a re-open, and why a drawn picture inside it is
--- undisturbed.
---@param border string|string[]
---@return boolean changed false when no float is open
function M.set_border(border)
  if not safe_api.is_valid_window(_win) then
    return false
  end
  return (pcall(api.nvim_win_set_config, _win, { border = M.resolve_border(border) }))
end

--- Register teardown to run when this hover closes — used by previewers that
--- draw into the window after it is already open (a rasterized PDF page
--- arriving from an async render, say) and must clear that drawing again.
---@param on_close fun()
---@return nil
function M.set_on_close(on_close)
  _on_close = on_close
end

--- Close the hover window, if any. Safe to call repeatedly.
---@param on_close fun()|nil Extra teardown, in addition to any registered via `set_on_close`.
---@return nil
function M.close(on_close)
  if _on_close then
    pcall(_on_close)
    _on_close = nil
  end
  if on_close then
    pcall(on_close)
  end

  if _augroup then
    pcall(api.nvim_del_augroup_by_id, _augroup)
    _augroup = nil
  end
  if safe_api.is_valid_window(_win) then
    pcall(api.nvim_win_close, _win, true)
  end
  if safe_api.is_valid_buffer(_buf) then
    pcall(api.nvim_buf_delete, _buf, { force = true })
  end
  _win, _buf = nil, nil
end

---@internal
--- Width/height from the content, clamped to the caller's maxima and to what
--- actually fits on screen. Width is measured in display columns rather than
--- bytes, so a CJK or emoji preview is not cut off half a cell short.
---@param lines string[]
---@param opts Hover.FloatOpts
---@return integer width
---@return integer height
local function measure(lines, opts)
  local width_of = require("lib.lua.strings.width").display_width

  local width = 1
  for _, line in ipairs(lines) do
    local w = width_of(line)
    if w > width then
      width = w
    end
  end

  width = math.min(width, opts.max_width or 80, math.max(20, vim.o.columns - 4))
  local height = math.min(#lines, opts.max_height or 20, math.max(3, vim.o.lines - 4))
  return width, math.max(height, 1)
end

--- The size a float would have for this content: the size *after* the clamp
--- against the screen, which is the only one worth comparing.
---
--- Public because `hover.resize` has to ask it before presenting. A step that
--- the screen refuses has to be stepped back off, and "refused" is not
--- visible in the content -- twenty-five lines asked for and twenty shown is
--- a clamp, and a resize that did not notice would let a held key run the
--- level away somewhere it has to be pressed back from.
---@param lines string[]|nil
---@param opts table `canvas`, `max_width`, `max_height`
---@return integer width
---@return integer height
function M.size_for(lines, opts)
  opts = opts or {}
  local canvas = opts.canvas
  if canvas then
    return math.max(1, math.min(canvas.cols, math.max(20, vim.o.columns - 4))),
      math.max(1, math.min(canvas.rows, math.max(3, vim.o.lines - 4)))
  end
  return measure(lines or {}, opts)
end

--- The open float's own width and height, or nil when none is open.
---@return integer|nil width
---@return integer|nil height
function M.size()
  local win = M.win()
  if not win then
    return nil
  end
  local ok, cfg = pcall(api.nvim_win_get_config, win)
  if not ok then
    return nil
  end
  return cfg.width, cfg.height
end

--- Open (or replace) the hover window showing `lines`.
---@param lines string[]
---@param opts Hover.FloatOpts
---@return integer|nil win
---@return integer|nil buf
function M.open(lines, opts)
  opts = opts or {}
  M.close()

  -- Canvas mode: the float exists only to give a drawn image a frame and a
  -- set of coordinates, so it gets blank lines at the caller's exact size and
  -- neither text nor a title. A filename in the border and a "PNG · 10 KB"
  -- line describe a picture the reader is already looking at.
  local canvas = opts.canvas
  if canvas then
    lines = {}
    for i = 1, math.max(1, canvas.rows) do
      lines[i] = ""
    end
  end

  if not lines or #lines == 0 then
    return nil, nil
  end

  -- `nvim_buf_set_lines` rejects any element containing a newline
  -- ("'replacement string' item contains newlines") and throws, which in an
  -- async previewer's callback surfaces as a bare stack trace with no hover.
  -- Previewers assemble their lines from file contents, error strings and
  -- external tool output, so an embedded "\n" is a question of when, not if
  -- -- flattening here is one guard instead of one per previewer. Tabs are
  -- left alone; only the split is required.
  local flat = {}
  for _, line in ipairs(lines) do
    local text = type(line) == "string" and line or tostring(line)
    if text:find("\n", 1, true) then
      for _, part in ipairs(vim.split(text, "\n", { plain = true })) do
        flat[#flat + 1] = (part:gsub("\r$", ""))
      end
    else
      flat[#flat + 1] = text
    end
  end
  lines = flat

  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  -- Highlight the first line before the buffer is locked. Used wherever the
  -- first line is a verdict rather than content: the "missing" preview's ✗
  -- marker, an HTTP error status, a "this file has no text in it" badge. A
  -- filetype cannot express "this one line means something", and in each of
  -- those previews that line is the whole point.
  --
  -- `default = true` on the link, set here rather than at setup(): a
  -- colorscheme loaded after us must be able to override it, and a user who
  -- defined the group themselves must not have it overwritten.
  if opts.highlight and opts.highlight ~= "" then
    local link = HL_DEFAULTS[opts.highlight]
    if link then
      pcall(api.nvim_set_hl, 0, opts.highlight, { link = link, default = true })
    end
    pcall(api.nvim_buf_set_extmark, buf, api.nvim_create_namespace("hover"), 0, 0, {
      end_row = 1,
      hl_group = opts.highlight,
      hl_eol = true,
    })
  end

  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  if not canvas and opts.filetype and opts.filetype ~= "" then
    -- `pcall`: a filetype whose ftplugin errors must not take the hover down.
    pcall(function()
      vim.bo[buf].filetype = opts.filetype
    end)
  end

  local width, height = M.size_for(lines, opts)

  -- Positioned against the editor grid, not the cursor — even though "one
  -- line below the cursor" is exactly what is wanted here.
  --
  -- **Why.** With `relative = "cursor"`, `nvim_win_get_position` reports a
  -- column that is too large by the width of whatever sits left of the
  -- editor window (a file tree, a sidebar). Measured: a tree 26 columns wide
  -- makes a float whose frame is drawn at column ~59 report column 83.
  -- Neovim draws it correctly; only the reported number is wrong.
  --
  -- That matters because this float's geometry is not decoration: it *is*
  -- the box handed to the terminal for the image (`images.anchor` reads it
  -- back with `nvim_win_get_position`). Every consumer then computes a
  -- correct offset from a wrong origin, and the picture lands beside its own
  -- frame by the tree's width — which is precisely the bug this replaces.
  --
  -- `screenpos()` gives the cursor's true position on the editor grid, and
  -- an `editor`-relative float reports back exactly the coordinates it was
  -- given. The float lands in the same place as before; only the number it
  -- reports afterwards becomes trustworthy.
  local anchor_row, anchor_col
  if opts.center then
    -- **The one place a hover is deliberately not next to the cursor.** Every
    -- argument for cursor-relative positioning is about a small float
    -- annotating the line under it; a float that fills the screen annotates
    -- nothing, and anchoring it at the cursor would only decide which edge it
    -- is cut off at. See `hover.zen`.
    --
    -- `row`/`col` are the origin of the *text* area and the ring is drawn
    -- around it, so the centred origin is one cell in from the centred frame
    -- -- and never less than 1, which is where the ring itself would land off
    -- the screen. Same arithmetic in both axes, and both against the editor
    -- grid this float is already relative to.
    anchor_row = math.max(1, math.floor((vim.o.lines - height) / 2))
    anchor_col = math.max(1, math.floor((vim.o.columns - width) / 2))
  else
    local cur_win = api.nvim_get_current_win()
    local cursor = api.nvim_win_get_cursor(cur_win)
    -- screenpos() is 1-based and returns {row=0, col=0} when the position is
    -- not currently visible (folded, scrolled away).
    local sp = vim.fn.screenpos(cur_win, cursor[1], cursor[2] + 1)
    if type(sp) == "table" and (sp.row or 0) > 0 and (sp.col or 0) > 0 then
      anchor_row, anchor_col = sp.row, sp.col - 1
    else
      -- Fall back to the window's own origin rather than to cursor-relative
      -- positioning: a slightly misplaced float still reports honestly, and
      -- an honest origin is what the image needs.
      local wp = api.nvim_win_get_position(cur_win)
      anchor_row, anchor_col = wp[1] + 1, wp[2]
    end
  end

  local ok, win = pcall(api.nvim_open_win, buf, false, {
    relative = "editor",
    row = anchor_row,
    col = anchor_col,
    width = width,
    height = height,
    style = "minimal",
    border = M.resolve_border(opts.border),
    focusable = opts.focusable == true,
    noautocmd = true,
    title = not canvas and opts.title or nil,
    title_pos = not canvas and opts.title and "left" or nil,
  })
  if not ok then
    pcall(api.nvim_buf_delete, buf, { force = true })
    return nil, nil
  end

  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].conceallevel = 2
  vim.wo[win].winhighlight = "Normal:NormalFloat,FloatBorder:FloatBorder"

  _win, _buf = win, buf

  -- Dismiss on the next thing the user does. `CursorMoved` alone is not
  -- enough: leaving insert mode or switching windows must also clear it, or
  -- a stale hover outlives the context it described.
  _augroup = autocmd.group("HoverDismiss", true)
  autocmd.create(
    { "CursorMoved", "CursorMovedI", "InsertEnter", "BufLeave", "WinScrolled" },
    function()
      M.close(opts.on_close)
    end,
    {
      group = _augroup,
      once = true,
      desc = "hover: dismiss on the next cursor move or mode change",
    }
  )

  return win, buf
end

--- The window handle of the open hover, or nil.
---@return integer|nil
function M.win()
  return M.is_open() and _win or nil
end

--- Whether a screen cell is inside the open float, its border counted in.
---
--- **`getmousepos()` cannot answer this, and that is the whole reason the
--- function exists.** This float is `focusable = false`, and a non-focusable
--- float is invisible to that call: measured 2026-09-02, with the pointer
--- squarely inside one, `getmousepos().winid` reported the window
--- *underneath* it (1000 for a float that was 1001). Only `screenrow` and
--- `screencol` come back usable, so the hit test is done here, against the
--- geometry the float reports about itself -- the same `nvim_win_get_position`
--- images.nvim reads back to place a picture.
---
--- **The border ring counts as inside**, and that is not generosity. The
--- float is anchored one row below the cursor, which puts its top ring on
--- the cursor's own row -- so under `trigger = { "mouse" }`, where the
--- pointer *is* the cursor, the pointer sits exactly on that ring. Excluding
--- it would mean the wheel never fired in the one workflow that puts a
--- pointer there to begin with.
---@param screenrow integer 1-based, as `getmousepos()` reports it
---@param screencol integer 1-based
---@return boolean
function M.contains(screenrow, screencol)
  local win = M.win()
  if not win or type(screenrow) ~= "number" or type(screencol) ~= "number" then
    return false
  end

  -- `pcall`: the window can be gone between the check above and here, and a
  -- wheel event is not worth an error message.
  local ok, pos = pcall(api.nvim_win_get_position, win)
  if not ok then
    return false
  end

  local cfg = api.nvim_win_get_config(win)
  local ring = (cfg.border and cfg.border ~= "none") and 1 or 0

  -- `pos` is the 0-based origin of the *text* area; the ring is drawn around
  -- it. +1 converts to the 1-based screen coordinates `getmousepos()` uses.
  local top = pos[1] + 1 - ring
  local left = pos[2] + 1 - ring
  local bottom = pos[1] + api.nvim_win_get_height(win) + ring
  local right = pos[2] + api.nvim_win_get_width(win) + ring

  return screenrow >= top and screenrow <= bottom and screencol >= left and screencol <= right
end

return M
