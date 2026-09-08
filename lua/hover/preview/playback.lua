---@module 'hover.preview.playback'
---@brief The transport for a video hover: one run of stills, a timer, and a
---control row.
---@description
--- **Nothing plays until it is asked to.** A hover appears because a cursor
--- rested somewhere for `updatetime`, which is not a request for sound and
--- motion — it is a glance. So the first thing a video hover shows is a
--- still, exactly as before; `transport_keys.toggle` is what turns it into a
--- moving picture, and the run is not even decoded before that key is pressed.
---
--- **What moves is text.** Every cell is a `█` with its own highlight
--- (`images.blocks`), so this collides with no terminal graphics protocol and
--- survives every Neovim redraw — unlike the still, which is an OSC 1337
--- payload the editor happily paints over. That is not a preference: the only
--- protocol with real animation frames is Kitty's, and on Windows in WezTerm
--- nothing sent from inside Neovim renders through it at all.
---
--- **The timer paints, it does not re-render.** `hover.render` closes and
--- reopens the float, which at 12 fps would be a strobe light. So the float is
--- opened once with a canvas of the right size, and from then on each frame is
--- `nvim_buf_set_extmark` calls into the buffer that is already there — the
--- same division `preview.media.draw_into` makes for a still, one step
--- further.
---
--- Measured end to end, 640x360 source at 80x36 cells: 168 ms to decode 24
--- stills (3 ms cached), 153 ms to sample them into cells, 4.6 ms to paint one
--- — about 325 ms from the key to the first frame, and 5% of a 12 fps budget
--- per frame after that.

local M = {}

--- The one active playback. Single-instance for the same reason the hover
--- float is: there is one float, and this draws into it.
---@type { timer: uv.uv_timer_t|nil, buf: integer|nil, ns: integer, raw: string, frames: integer, index: integer, cols: integer, rows: integer, fps: number, playing: boolean, duration: number|nil, from: number, status_row: integer }|nil
local state = nil

local NS = vim.api.nvim_create_namespace("hover.playback")

--- Whether a run is loaded and drawable right now.
---@return boolean
function M.is_active()
  return state ~= nil and state.buf ~= nil and vim.api.nvim_buf_is_valid(state.buf)
end

--- Whether the loaded run is currently advancing.
---@return boolean
function M.is_playing()
  return M.is_active() and state ~= nil and state.playing
end

---@internal
--- Stop the timer without touching the drawing. Split out because pausing and
--- tearing down differ only in what happens afterwards, and a timer that is
--- stopped twice must not error.
local function stop_timer()
  if state and state.timer then
    pcall(function()
      state.timer:stop()
      state.timer:close()
    end)
    state.timer = nil
  end
end

--- Tear the playback down: stop the timer, forget the run.
---
--- Registered as the float's `on_close`, so it runs however the hover goes
--- away — a cursor move, `q`, a re-render. A timer that outlives its window
--- paints into a buffer nobody can see, at 12 fps, forever.
---@return nil
function M.stop()
  stop_timer()
  state = nil
end

---@internal
--- The control row, rebuilt from the current position.
---
--- Text, like everything else here: it costs nothing to redraw and it cannot
--- be painted over. The time is the *source* offset, so it says where in the
--- film this is rather than where in the run.
---@return string
local function status_line()
  if not state then
    return ""
  end
  local ui_ok, ui = pcall(require, "media.ui")
  local at = state.from + (state.index - 1) / state.fps
  local now = ui_ok and ui.duration(at) or ("%.1fs"):format(at)
  local total = (ui_ok and state.duration) and ui.duration(state.duration) or nil

  local width = math.max(8, state.cols - 28)
  local filled = state.frames > 1 and math.floor((state.index - 1) / (state.frames - 1) * width)
    or width
  local bar = ("▮"):rep(filled) .. ("▯"):rep(width - filled)

  return ("%s %s%s  %s"):format(
    state.playing and "▶" or "▮▮",
    now,
    total and (" / " .. total) or "",
    bar
  )
end

---@internal
--- Paint the current frame and refresh the control row.
---@return boolean ok
local function draw()
  if not state or not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    M.stop()
    return false
  end
  local ok_blocks, blocks = pcall(require, "images.blocks")
  if not ok_blocks then
    M.stop()
    return false
  end

  local painted = blocks.paint(state.buf, NS, state.raw, state.index, state.cols, state.rows)
  if not painted then
    M.stop()
    return false
  end

  -- The buffer is the float's and is not modifiable by default; the status
  -- row is the only line this ever rewrites.
  pcall(function()
    vim.bo[state.buf].modifiable = true
    vim.api.nvim_buf_set_lines(
      state.buf,
      state.status_row,
      state.status_row + 1,
      false,
      { status_line() }
    )
    vim.bo[state.buf].modifiable = false
  end)
  return true
end

--- Load a decoded run into the float and show its first frame, paused.
---
--- `raw` is what `images.blocks.sample` produced for `frames` stills; the
--- caller owns the decode so this stays synchronous and cheap.
---@param spec { buf: integer, raw: string, frames: integer, cols: integer, rows: integer, fps: number, from: number, duration: number|nil, status_row: integer }
---@return boolean ok
function M.load(spec)
  M.stop()
  state = {
    timer = nil,
    buf = spec.buf,
    ns = NS,
    raw = spec.raw,
    frames = spec.frames,
    index = 1,
    cols = spec.cols,
    rows = spec.rows,
    fps = spec.fps,
    playing = false,
    duration = spec.duration,
    from = spec.from or 0,
    status_row = spec.status_row,
  }
  return draw()
end

--- Advance by `delta` frames and repaint, without starting the timer.
---
--- Clamped rather than wrapped: a run is a window into a file, and jumping
--- from its end back to its start would read as the video looping when it is
--- not.
---@param delta integer
---@return nil
function M.step(delta)
  if not M.is_active() or not state then
    return
  end
  local next_index = math.min(state.frames, math.max(1, state.index + delta))
  if next_index == state.index then
    return
  end
  state.index = next_index
  draw()
end

--- Start playing from the current frame.
---@return nil
function M.play()
  if not M.is_active() or not state or state.playing then
    return
  end
  -- At the end, play restarts the run rather than doing nothing: the key was
  -- pressed to see something move.
  if state.index >= state.frames then
    state.index = 1
  end
  state.playing = true
  local timer = vim.uv.new_timer()
  state.timer = timer
  timer:start(
    0,
    math.max(1, math.floor(1000 / state.fps)),
    vim.schedule_wrap(function()
      if not state or not state.playing then
        return
      end
      if state.index >= state.frames then
        -- The run is over. Stop rather than loop, and leave the last frame
        -- and the control row on screen saying so.
        M.pause()
        return
      end
      state.index = state.index + 1
      draw()
    end)
  )
end

--- Stop advancing, leaving the current frame on screen.
---@return nil
function M.pause()
  if not state then
    return
  end
  stop_timer()
  state.playing = false
  draw()
end

--- Play if paused, pause if playing.
---@return nil
function M.toggle()
  if M.is_playing() then
    M.pause()
  else
    M.play()
  end
end

return M
