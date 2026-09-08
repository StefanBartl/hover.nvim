-- scripts/playback_live_probe.lua -- a real playback, counted in a real terminal.
--
-- The companion to `playback_probe.lua`. That one isolates the cost of one
-- painted frame; this one runs the actual transport against an actual file and
-- counts what reaches the screen, which is the only number that settles an
-- argument about frame rate.
--
--   :lua vim.g.hover_probe_video = "C:/path/to/clip.mp4"
--   :luafile /path/to/hover.nvim/scripts/playback_live_probe.lua
--
-- Needs media.nvim (ffmpeg) and images.nvim (ImageMagick); mpv is optional and
-- the run says whether it was there.
--
-- What it prints, once per second while it runs:
--
--   * **painted** -- frames that reached `blocks.paint`. Target is `video.fps`,
--     12 by default. This is the number a reader compares against what they
--     see.
--   * **ticks** -- times the transport's timer fired. **If this is already low,
--     nothing downstream matters**: the timer is scheduled through
--     `vim.schedule_wrap`, so a blocked main loop starves it, and the cause is
--     something else holding the loop -- the sampling callback carrying a
--     megabyte and a half, an ffmpeg or ImageMagick finishing, a plugin's
--     autocmd. That is the one hypothesis no headless measurement has ruled
--     out.
--   * **skipped** -- ticks that fired but painted nothing.
--   * **pos** -- mpv's position. If it advances one second per second while
--     `painted` is low, sound and picture have come apart again.
--
-- A window is decoded every two seconds, so the seams show as dips. Look at the
-- steady seconds, not the first.

local ok_media, media = pcall(require, "media")
local ok_blocks, blocks = pcall(require, "images.blocks")
local ok_pb, playback = pcall(require, "hover.preview.playback")
if not (ok_media and ok_blocks and ok_pb) then
  vim.notify("live probe: needs media.nvim, images.nvim and hover.nvim", vim.log.levels.ERROR)
  return
end

local path = vim.g.hover_probe_video
if type(path) ~= "string" or path == "" then
  vim.notify(
    'live probe: set vim.g.hover_probe_video = "/path/to/clip.mp4" first',
    vim.log.levels.ERROR
  )
  return
end

local config = require("hover.config")
local opts = config.preview_opts()
local FPS = opts.video_fps or 12
local COUNT = opts.video_run or 24
local SECONDS = 10

-- The canvas a real hover would build at this editor size.
local scale = tonumber(opts.video_play_scale) or 1
local W = math.min(math.floor((opts.max_width or 80) * scale), math.max(20, vim.o.columns - 4))
local H = math.min(math.floor((opts.max_lines or 20) * scale), math.max(3, vim.o.lines - 4))
local probe = media.probed(path)
local cols, rows =
  require("hover.preview.video").playback_cells(probe, { max_width = W, max_lines = H })

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

local painted = 0
local real_paint = blocks.paint
blocks.paint = function(...)
  painted = painted + 1
  return real_paint(...)
end

local out = {
  ("live probe: %s"):format(path),
  ("editor %dx%d   box %dx%d   canvas %dx%d cells   geometry %s (%dx%d sub-pixels)"):format(
    vim.o.columns,
    vim.o.lines,
    W,
    H,
    cols,
    rows,
    blocks.geometry().name,
    blocks.geometry().cols,
    blocks.geometry().rows
  ),
  ("target %d fps   window %d frames   sound %s"):format(
    FPS,
    COUNT,
    (probe and probe.has_audio and require("media.core.audio").available()) and "yes" or "no"
  ),
  "",
}

---@param at number|string
---@param cb fun(run: table|nil, err: string|nil)
local function decode(at, cb)
  media.frames(path, {
    from = at,
    fps = FPS,
    count = COUNT,
    width = math.max(320, cols * blocks.geometry().cols * 2),
  }, function(pngs, err)
    if not pngs or #pngs == 0 then
      cb(nil, err)
      return
    end
    blocks.sample_async(pngs, cols, rows, function(raw, serr)
      if not raw then
        cb(nil, serr)
        return
      end
      if type(blocks.prepare) == "function" then
        pcall(blocks.prepare, raw, cols, rows)
      end
      cb({ raw = raw, frames = #pngs }, nil)
    end)
  end)
end

local function finish()
  blocks.paint = real_paint
  pcall(playback.stop)
  pcall(vim.api.nvim_win_close, win, true)
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
  out[#out + 1] = ""
  out[#out + 1] = "If `ticks` is near the target but `painted` is far below it, the paint is"
  out[#out + 1] = "being skipped. If `ticks` itself is low, the main loop is starved and the"
  out[#out + 1] = "cause is outside this module. If both are near the target and the picture"
  out[#out + 1] = "still looks slow, the terminal is not keeping up -- run playback_probe.lua."
  vim.cmd("new")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, out)
  vim.bo.buftype = "nofile"
  vim.bo.bufhidden = "wipe"
end

local t0 = vim.uv.hrtime()
decode(0, function(run, err)
  if not run then
    out[#out + 1] = "decode failed: " .. tostring(err)
    finish()
    return
  end
  out[#out + 1] = ("first window ready after %.0f ms"):format((vim.uv.hrtime() - t0) / 1e6)
  out[#out + 1] = ""
  out[#out + 1] = ("%-8s %9s %8s %9s %9s"):format("second", "painted", "ticks", "skipped", "pos")

  playback.load({
    buf = buf,
    raw = run.raw,
    frames = run.frames,
    cols = cols,
    rows = rows,
    fps = FPS,
    from = 0,
    duration = probe and probe.duration or nil,
    status_row = rows,
    path = (probe and probe.has_audio) and path or nil,
    request = decode,
  })

  -- A second timer at the same rate, doing nothing: what the transport's own
  -- timer *would* manage if painting were free. The gap between the two is
  -- how much the paint costs the loop.
  local ticks = 0
  local ticker = vim.uv.new_timer()
  ticker:start(
    0,
    math.max(1, math.floor(1000 / FPS)),
    vim.schedule_wrap(function()
      ticks = ticks + 1
    end)
  )

  painted = 0
  playback.play()

  local second, last_p, last_t = 0, 0, 0
  local report = vim.uv.new_timer()
  report:start(
    1000,
    1000,
    vim.schedule_wrap(function()
      second = second + 1
      local p, t = painted - last_p, ticks - last_t
      out[#out + 1] = ("%-8d %9d %8d %9d %9.2f"):format(
        second,
        p,
        t,
        math.max(0, t - p),
        playback.position()
      )
      last_p, last_t = painted, ticks
      if second >= SECONDS then
        report:stop()
        report:close()
        ticker:stop()
        ticker:close()
        finish()
      end
    end)
  )
end)
