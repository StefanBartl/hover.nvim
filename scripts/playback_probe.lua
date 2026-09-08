-- scripts/playback_probe.lua -- where the frames go, measured in a real terminal.
--
-- **Run this from inside your own Neovim, not headless.** That is the whole
-- point: every headless measurement of this transport has looked fine while a
-- reader watched 1-2 frames per second, because headless nothing redraws.
--
--   :luafile /path/to/hover.nvim/scripts/playback_probe.lua
--
-- It opens a float, paints a run into it as playback does, and prints where
-- the time went. Nothing is decoded and no mpv is started -- the payload is
-- synthetic -- so what it isolates is exactly the half a headless run cannot
-- see: painting into a *visible* window and letting the terminal draw it.
--
-- What to read out of the table:
--
--   * **paint** is `images.blocks.paint`: sampling cells into extmarks, plus
--     rewriting the line for a geometry finer than a half block. Headless this
--     measures ~8 ms at 113x32. If it is still ~8 ms here, drawing is not the
--     problem.
--   * **redraw** is `vim.cmd("redraw")` with the float on screen -- Neovim
--     resolving the highlights and sending the grid to the terminal, and the
--     terminal drawing it. **This is the number nothing so far has measured.**
--     If it is tens of milliseconds, the terminal is the ceiling and the
--     answer is fewer cells or fewer distinct colour pairs, not faster Lua.
--   * **total** is what one frame really costs. 83 ms is the 12 fps budget.
--   * **groups** is how many highlight groups the run created *while painting*.
--     It should be 0 after `prepare`: every one of them invalidates the whole
--     screen.
--
-- Sizes are the ones a video hover actually builds on a 200x38 editor (113x32),
-- with two smaller ones to see how the cost scales. If the cost is linear in
-- cells, the terminal is drawing; if it is flat, it is not.

local ok_blocks, blocks = pcall(require, "images.blocks")
if not ok_blocks then
  vim.notify("playback_probe: images.nvim is not on the runtimepath", vim.log.levels.ERROR)
  return
end

---@param n integer
---@return string
local function payload(n)
  local parts = {}
  math.randomseed(20260908)
  for _ = 1, n do
    -- Real footage, not flat colour: a flat frame collapses to one extmark per
    -- row and measures nothing. Neighbouring cells correlate, the way a
    -- photograph does, so this is not the noise worst case either.
    local r, g, b = math.random(0, 255), math.random(0, 255), math.random(0, 255)
    for _ = 1, 24 do
      parts[#parts + 1] = string.char(
        math.min(255, math.max(0, r + math.random(-12, 12))),
        math.min(255, math.max(0, g + math.random(-12, 12))),
        math.min(255, math.max(0, b + math.random(-12, 12)))
      )
    end
  end
  return table.concat(parts)
end

---@param cells string
---@param cols integer
---@param rows integer
---@param frames integer
---@return table
local function measure(cells, cols, rows, frames)
  local saved = ((require("images.config").get().display or {}).ascii_fallback or {}).cells
  require("images.config").setup({ display = { ascii_fallback = { cells = cells } } })
  local geo = blocks.geometry()

  local pixels = blocks.frame_bytes(cols, rows, geo) / 3 * frames
  local raw = payload(math.ceil(pixels / 24))
  raw = raw:sub(1, blocks.frame_bytes(cols, rows, geo) * frames)

  local buf = vim.api.nvim_create_buf(false, true)
  local lines = blocks.canvas_lines(cols, rows)
  lines[#lines + 1] = ""
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  local win = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    row = 1,
    col = 1,
    width = math.min(cols, vim.o.columns - 4),
    height = math.min(rows + 1, vim.o.lines - 4),
    style = "minimal",
    border = "rounded",
    focusable = false,
  })
  local ns = vim.api.nvim_create_namespace("hover.playback.probe." .. cells)

  blocks.prepare(raw, cols, rows)
  local groups0 = blocks.groups_created()

  local paint_ns, redraw_ns = 0, 0
  for f = 1, frames do
    local t0 = vim.uv.hrtime()
    blocks.paint(buf, ns, raw, f, cols, rows)
    local t1 = vim.uv.hrtime()
    vim.cmd("redraw")
    local t2 = vim.uv.hrtime()
    paint_ns = paint_ns + (t1 - t0)
    redraw_ns = redraw_ns + (t2 - t1)
  end

  local made = blocks.groups_created() - groups0
  pcall(vim.api.nvim_win_close, win, true)
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
  require("images.config").setup({ display = { ascii_fallback = { cells = saved } } })

  local paint = paint_ns / frames / 1e6
  local redraw = redraw_ns / frames / 1e6
  return {
    cells = cells,
    grid = cols .. "x" .. rows,
    n = cols * rows,
    paint = paint,
    redraw = redraw,
    total = paint + redraw,
    fps = 1000 / (paint + redraw),
    groups = made,
  }
end

local rows_out = {
  ("editor: %dx%d   budget at 12 fps: 83.3 ms per frame"):format(vim.o.columns, vim.o.lines),
  "",
  ("%-9s %-8s %7s %9s %9s %8s %7s"):format(
    "cells",
    "grid",
    "n",
    "paint ms",
    "redraw ms",
    "total",
    "fps"
  ),
  ("%-9s %-8s %7s %9s %9s %8s %7s"):format(
    "-----",
    "----",
    "-",
    "--------",
    "---------",
    "-----",
    "---"
  ),
}

for _, case in ipairs({
  { "half", 113, 32 },
  { "quadrant", 113, 32 },
  { "sextant", 113, 32 },
  { "sextant", 78, 19 },
  { "sextant", 40, 10 },
}) do
  local ok, r = pcall(measure, case[1], case[2], case[3], 24)
  if ok then
    rows_out[#rows_out + 1] = ("%-9s %-8s %7d %9.2f %9.2f %8.2f %7.1f%s"):format(
      r.cells,
      r.grid,
      r.n,
      r.paint,
      r.redraw,
      r.total,
      r.fps,
      r.groups > 0 and ("   (+%d groups while painting!)"):format(r.groups) or ""
    )
  else
    rows_out[#rows_out + 1] = ("%-9s %-8s  FAILED: %s"):format(
      case[1],
      case[2] .. "x" .. case[3],
      tostring(r)
    )
  end
end

rows_out[#rows_out + 1] = ""
rows_out[#rows_out + 1] =
  "Read it as: if `redraw` dominates and grows with `n`, the terminal is the"
rows_out[#rows_out + 1] = "ceiling -- fewer cells or fewer colour pairs, not faster Lua. If `paint`"
rows_out[#rows_out + 1] =
  "dominates, the drawing is. If neither reaches 83 ms and playback is still"
rows_out[#rows_out + 1] =
  "slow, the timer is not firing at 12 fps and the cause is elsewhere entirely."

local out = table.concat(rows_out, "\n")
print(out)

-- Also into a scratch buffer, because `print` in a busy session scrolls away.
vim.schedule(function()
  vim.cmd("new")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(out, "\n"))
  vim.bo.buftype = "nofile"
  vim.bo.bufhidden = "wipe"
end)
