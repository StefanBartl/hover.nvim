---@module 'hover.preview.playback'
---@brief The transport for a video hover: one run of stills, a timer, a
---control row — and, when there is a track and mpv is on PATH, sound.
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
--- **Sound leads, the picture follows — it is not the other way round.** A
--- Lua timer is not a clock a listener would forgive drifting from, so the
--- picture does not run on one. When `media.core.audio` hands back a
--- playing mpv, the timer stops counting frames and instead asks mpv *where
--- it is* once per tick and paints whichever frame belongs to that position.
--- Drawn late, the next tick simply asks again and jumps to wherever mpv has
--- gotten to — it never accumulates a lag the way two independently
--- free-running clocks would. Without mpv (not installed, no audio track,
--- `video_sound = false`), the timer falls back to counting frames exactly as
--- it always has; sound is additive, never a precondition for motion.
---
--- **A run is a window, and the window rolls.** One decode covers two seconds
--- (24 stills at 12 fps), which is what makes the first frame arrive quickly —
--- and on its own it made playback stop dead after two seconds while the sound
--- carried on without it, which is what a reader reported as "no video, just a
--- couple of seconds". So the transport asks for the next window while the
--- current one is still playing: `spec.request` decodes from where this run
--- ends, and the result is swapped in when the picture (or mpv's clock)
--- reaches that point. The seam is invisible because `from` moves with it, so
--- the control row keeps reading in source time rather than restarting.
---
--- The lead is one second of frames. Decoding a window was measured at
--- 442 ms plus 168 ms to sample it — comfortably inside that, and the reason
--- the request is not issued at the very last frame, where it would arrive
--- late every time.
---
--- Measured end to end, 640x360 source at 80x36 cells: 168 ms to decode 24
--- stills (3 ms cached), 153 ms to sample them into cells, 4.6 ms to paint one
--- — about 325 ms from the key to the first frame, and 5% of a 12 fps budget
--- per frame after that.

local M = {}

--- The one active playback. Single-instance for the same reason the hover
--- float is: there is one float, and this draws into it.
---
--- `gen` guards every callback that crosses an async boundary (mpv's IPC
--- socket coming up, a `time-pos` reply): each carries the generation it was
--- issued under, and a reply that arrives after `stop()` or a fresh `load()`
--- is simply dropped rather than writing into a run nobody asked for any more.
---@type { timer: uv.uv_timer_t|nil, buf: integer|nil, ns: integer, raw: string, frames: integer, index: integer, cols: integer, rows: integer, fps: number, playing: boolean, duration: number|nil, from: number, status_row: integer, gen: integer, path: string|nil, audio: Media.Audio.Handle|nil, audio_starting: boolean, audio_pending: boolean, request: (fun(from: number, cb: fun(run: Hover.Playback.Run|nil, err: string|nil)): nil)|nil, next_run: Hover.Playback.Run|nil, requesting: boolean, exhausted: boolean }|nil
local state = nil

--- Bumped by every `load()`, never by anything else — the one source of
--- generation numbers, kept outside `state` because `stop()` sets `state` to
--- `nil` and a dropped-callback check needs somewhere to compare against even
--- then.
local next_gen = 0

local NS = vim.api.nvim_create_namespace("hover.playback")

--- Whether `hook_cleanup` has already installed its autocmd, this session.
local _cleanup_hooked = false

---@internal
--- Register the one exit sweep, once, the first time audio is actually
--- started — mirroring `preview.media._hook_cleanup`. An mpv is a real OS
--- process outside Neovim's own lifetime: `M.stop()` kills it on every path
--- that closes the hover deliberately (the float's `on_close`, a fresh
--- `load()`), but quitting Neovim itself does not run those — a float torn
--- down as part of shutdown does not fire `WinClosed`/`on_close` the way a
--- reader dismissing it does. Without this, an mpv started right before
--- `:qa` outlives the editor and keeps playing on its own, exactly the
--- failure this module's header already names for the picture-side timer.
---@return nil
local function hook_cleanup()
  if _cleanup_hooked then
    return
  end
  _cleanup_hooked = true
  require("lib.nvim.bindings.autocmd").create("VimLeavePre", function()
    if state and state.audio then
      M.stop()
    end
  end, {
    group = "HoverPlayback",
    desc = "hover: stop any mpv still attached to a played video hover at exit",
  })
end

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

--- Tear the playback down: stop the timer, stop mpv if it was started, forget
--- the run.
---
--- Registered as the float's `on_close`, so it runs however the hover goes
--- away — a cursor move, `q`, a re-render. A timer that outlives its window
--- paints into a buffer nobody can see, at 12 fps, forever; an mpv that
--- outlives it is the same mistake with a speaker instead of a screen.
---@return nil
function M.stop()
  stop_timer()
  if state and state.audio then
    pcall(state.audio.stop)
  end
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

  return ("%s%s %s%s  %s"):format(
    state.playing and "▶" or "▮▮",
    state.audio and "♪" or "",
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

---@internal
--- One tick's worth of progress: from mpv's `time-pos` when there is a
--- playing mpv, a plain frame count otherwise.
---
--- The audio-driven branch never accumulates lag the way incrementing a
--- counter on a fallible timer would — a late tick just asks mpv again and
--- paints whatever frame belongs to the answer, which is either the next one
--- or, after a stall, the one after that. Reaching the end of the *run* (not
--- the file) swaps in the next window when one has been prefetched, and pauses
--- only when there is none -- the end of the file, or a decode that has not
--- landed yet.
---@internal
--- Where the current window ends, in source seconds — and therefore where the
--- next one begins.
---@return number
local function window_end()
  return state and (state.from + state.frames / state.fps) or 0
end

---@internal
--- Ask for the next window, if it is time and there is anyone to ask.
---
--- Issued a second of frames before the end rather than at it: a decode plus
--- its sampling was measured at about 0.6 s, so a request made at the last
--- frame arrives late every single time and the picture stutters at every
--- seam. Asked at most once per window — `requesting` is "already asked",
--- `next_run` is "already have it", and `exhausted` is the end of the file,
--- after which asking again would start an ffmpeg per tick for nothing.
---@return nil
local function prefetch()
  if not state or not state.request then
    return
  end
  if state.next_run or state.requesting or state.exhausted then
    return
  end
  if state.index < state.frames - math.max(4, math.floor(state.fps)) then
    return
  end

  state.requesting = true
  local gen = state.gen
  state.request(window_end(), function(run)
    -- The run this was asked for may be gone, or a later one loaded in its
    -- place; either way the answer belongs to nothing.
    if not state or state.gen ~= gen then
      return
    end
    state.requesting = false
    state.next_run = run
    -- No run means the file ended, which is not a failure and not worth
    -- reporting — the transport simply stops when the picture runs out.
    state.exhausted = run == nil
  end)
end

---@internal
--- Move the prefetched window into place, keeping source time continuous.
---
--- `from` advances by exactly the length of the window being left behind, so
--- the control row reads on rather than restarting, and mpv's position keeps
--- mapping onto the right frame across the seam.
---@return boolean swapped
local function swap_run()
  if not state or not state.next_run then
    return false
  end
  local run = state.next_run
  state.next_run = nil
  state.from = window_end()
  state.raw = run.raw
  state.frames = run.frames
  state.index = 1
  return true
end

---@param pos number|nil  # mpv's `time-pos`, or nil for the no-audio fallback
---@return nil
local function advance(pos)
  if not state then
    return
  end
  if pos then
    local idx = math.floor((pos - state.from) * state.fps) + 1
    if idx >= state.frames then
      -- The sound has run past the decoded window. With the next one in hand
      -- the picture follows it across; without one there is nothing left to
      -- show, and playing sound over a frozen frame is worse than stopping.
      if not swap_run() then
        state.index = state.frames
        M.pause()
        return
      end
      idx = math.floor((pos - state.from) * state.fps) + 1
    end
    state.index = math.max(1, math.min(state.frames, idx))
    prefetch()
    draw()
    return
  end
  if state.index >= state.frames then
    if not swap_run() then
      M.pause()
      return
    end
    prefetch()
    draw()
    return
  end
  state.index = state.index + 1
  prefetch()
  draw()
end

--- Load a decoded run into the float and show its first frame, paused.
---
--- `raw` is what `images.blocks.sample` produced for `frames` stills; the
--- caller owns the decode so this stays synchronous and cheap. `spec.path`,
--- when present, is where `M.play` starts mpv from — `preview.video` sets it
--- only when there is a track to start and sound has not been turned off, so
--- this never has to make that decision itself.
---@param spec { buf: integer, raw: string, frames: integer, cols: integer, rows: integer, fps: number, from: number, duration: number|nil, status_row: integer, path: string|nil, request: (fun(from: number, cb: fun(run: Hover.Playback.Run|nil, err: string|nil)): nil)|nil }
---@return boolean ok
function M.load(spec)
  M.stop()
  next_gen = next_gen + 1
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
    gen = next_gen,
    path = spec.path,
    audio = nil,
    audio_starting = false,
    audio_pending = false,
    -- Absent when the caller cannot decode more (no duration to count from,
    -- an offset it could not resolve): the transport then behaves exactly as
    -- it did before windows rolled, stopping at the end of the one it has.
    request = spec.request,
    next_run = nil,
    requesting = false,
    exhausted = spec.request == nil,
  }
  return draw()
end

--- Advance by `delta` frames and repaint, without starting the timer.
---
--- Clamped rather than wrapped: a run is a window into a file, and jumping
--- from its end back to its start would read as the video looping when it is
--- not. When mpv is loaded it is seeked to match — always paused by the time
--- this runs (`hover.play_step` pauses first), so this only keeps mpv's own
--- position honest for whenever play resumes; it does not itself start or
--- stop anything.
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
  if state.audio then
    pcall(state.audio.seek, state.from + (state.index - 1) / state.fps)
  end
  draw()
end

--- Start playing from the current frame.
---
--- Starting mpv is asked for at most once per loaded run: `state.audio` is
--- the "already have it" check and `state.audio_starting` the "asked for it,
--- still waiting" one, so pressing play twice while mpv's socket is still
--- coming up cannot start a second process. A run with no `state.path` (no
--- track, sound turned off, `preview.video` never set one) never asks at
--- all — the fallback path below is unchanged from before sound existed.
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

  if state.audio then
    pcall(state.audio.resume)
  elseif state.path and not state.audio_starting then
    state.audio_starting = true
    local gen = state.gen
    local at = state.from + (state.index - 1) / state.fps
    local ok_audio, audio = pcall(require, "media.core.audio")
    if not ok_audio or not audio.available() then
      state.audio_starting = false
    else
      hook_cleanup()
      audio.start(state.path, { at = at }, function(handle)
        -- The run this was asked for may already be gone, or a later one
        -- loaded in its place — either way `gen` no longer matches, and an
        -- mpv nobody will stop or draw against is stopped right here instead.
        if not state or state.gen ~= gen then
          if handle then
            pcall(handle.stop)
          end
          return
        end
        state.audio_starting = false
        if handle then
          state.audio = handle
          if not state.playing then
            pcall(handle.pause)
          end
        end
        -- No else: `handle == nil` means no mpv, or its socket never came
        -- up — the fallback below is already running, muted exactly as it
        -- would have been before this feature existed.
      end)
    end
  end

  -- Before the first tick: a window is two seconds and the lead is one, so a
  -- reader who presses play and watches has already spent half the window by
  -- the time `advance` would ask.
  prefetch()

  local timer = vim.uv.new_timer()
  state.timer = timer
  timer:start(
    0,
    math.max(1, math.floor(1000 / state.fps)),
    vim.schedule_wrap(function()
      if not state or not state.playing then
        return
      end
      if not state.audio then
        advance(nil)
        return
      end
      if state.audio_pending then
        -- The previous tick's `time-pos` request has not answered yet;
        -- skipping this tick rather than queuing a second keeps replies
        -- matched to the request that asked for them one at a time.
        return
      end
      state.audio_pending = true
      local gen = state.gen
      state.audio.time_pos(function(pos)
        if not state or state.gen ~= gen then
          return
        end
        state.audio_pending = false
        if not state.playing then
          return
        end
        advance(pos)
      end)
    end)
  )
end

--- Stop advancing, leaving the current frame on screen. Pauses mpv in place
--- rather than stopping it — resuming is then instant, with no socket to
--- reconnect.
---@return nil
function M.pause()
  if not state then
    return
  end
  stop_timer()
  state.playing = false
  if state.audio then
    pcall(state.audio.pause)
  end
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
