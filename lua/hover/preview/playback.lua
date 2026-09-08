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
--- **Sound leads, the picture follows — but the picture does not wait for it.**
--- A Lua timer is not a clock a listener would forgive drifting from, so the
--- picture does not free-run on one: `media.core.audio`'s mpv is asked where
--- it is four times a second, and every answer moves the picture to wherever
--- mpv actually got to. Between those corrections the frame to draw comes from
--- `uv.hrtime`, which is what makes a paint cost nothing but a paint.
---
--- **That indirection is the whole of a real bug.** Until 2026-09-08 the timer
--- asked mpv once per painted frame and skipped the tick while an answer was
--- outstanding — so the IPC round trip was a hard ceiling on the frame rate.
--- Measured against a stub with a known latency: 0 ms gives 11.3 fps, 80 ms
--- gives 11.0, **150 ms gives 5.7 and 300 ms gives 3.0**. A round trip
--- averages 9.5 ms on this machine but was measured as high as 377, and every
--- two seconds playback runs an ffmpeg and an ImageMagick for the next window,
--- so the spikes are not rare. A reader reported 1-2 frames per second, and
--- the sound starting a second before the picture — which is the same thing,
--- seen at the start.
---
--- Without mpv (not installed, no audio track, `video_sound = false`), the
--- timer counts frames exactly as it always has; sound is additive, never a
--- precondition for motion. It is also what runs before the first correction
--- lands, so the picture moves from the first tick.
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
--- `seeking_to`, `scrubbing` and `scrub_target` are the scrub across window
--- boundaries: the position asked for while its window is still decoding, the
--- "a decode is already in flight" guard, and the newest place asked for. See
--- `scrub_to`.
---@type { timer: uv.uv_timer_t|nil, buf: integer|nil, ns: integer, raw: string, frames: integer, index: integer, cols: integer, rows: integer, fps: number, playing: boolean, duration: number|nil, from: number, status_row: integer, gen: integer, path: string|nil, audio: Media.Audio.Handle|nil, audio_starting: boolean, audio_pending: boolean, audio_catch_up: number|nil, clock_pos: number|nil, clock_at: integer, synced_at: integer, syncing: boolean, request: (fun(from: number, cb: fun(run: Hover.Playback.Run|nil, err: string|nil)): nil)|nil, next_run: Hover.Playback.Run|nil, requesting: boolean, exhausted: boolean, seeking_to: number|nil, scrubbing: boolean, scrub_target: number }|nil
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
--- How long the local clock may run before it is checked against mpv again.
---
--- Four times a second. Drift between `uv.hrtime` and a sound card over a
--- quarter of a second is well under a millisecond -- far below one frame at
--- 12 fps -- while the round trips this saves are the whole point.
local SYNC_INTERVAL_NS = 250 * 1e6

---@internal
--- Where mpv is now, from the local clock.
---
--- **Why there is a local clock at all, when mpv has the authoritative one.**
--- The transport used to ask mpv for `time-pos` once per painted frame and
--- skip the tick while an answer was outstanding, which made the IPC round
--- trip a hard ceiling on the frame rate. Measured 2026-09-08 against a stub
--- with a known latency: 0 ms gives 11.3 fps, 80 ms gives 11.0, **150 ms gives
--- 5.7 and 300 ms gives 3.0**. A real round trip averages 9.5 ms on this
--- machine but was measured as high as 377 ms, and playback runs an ffmpeg and
--- an ImageMagick every two seconds for the next window -- so the spikes are
--- not rare, and a reader reported 1-2 frames per second.
---
--- So the picture runs on `uv.hrtime` and mpv is asked four times a second to
--- correct it. Sound still leads: every correction moves the picture to
--- wherever mpv actually is, so this cannot drift the way two free-running
--- clocks would. What it no longer does is *wait* for the answer.
---@return number|nil  # seconds, or nil before the first sync has landed
local function clock_now()
  if not state or not state.clock_pos then
    return nil
  end
  if not state.playing then
    return state.clock_pos
  end
  return state.clock_pos + (vim.uv.hrtime() - state.clock_at) / 1e9
end

---@internal
--- Move the local clock to `pos` (mpv's position, or a seek target).
---@param pos number|nil
---@return nil
local function clock_set(pos)
  if not state then
    return
  end
  state.clock_pos = pos
  state.clock_at = vim.uv.hrtime()
end

---@internal
--- Ask mpv where it is, if it is time to, and correct the local clock when the
--- answer arrives.
---
--- Never blocks a paint: the tick that calls this draws from the local clock
--- regardless, and a reply that arrives three frames later simply corrects the
--- clock then. `syncing` keeps one request in flight at a time, so a slow
--- answer cannot queue up behind itself.
---@return nil
local function sync_clock()
  if not state or not state.audio or state.syncing then
    return
  end
  local now = vim.uv.hrtime()
  if state.clock_pos and (now - state.synced_at) < SYNC_INTERVAL_NS then
    return
  end
  state.syncing = true
  state.synced_at = now
  local gen = state.gen
  state.audio.time_pos(function(pos)
    if not state or state.gen ~= gen then
      return
    end
    state.syncing = false
    if type(pos) == "number" then
      clock_set(pos)
    end
  end)
end

--- Where the picture is in the file, in seconds.
---
--- `seeking_to` takes precedence while a scrub's window is still decoding: the
--- reader has already asked to be somewhere else, the clock should say so
--- immediately, and the picture catches up when ffmpeg answers. Reporting the
--- old position for those few hundred milliseconds makes a key press look
--- dropped.
---@return number
function M.position()
  if not state then
    return 0
  end
  return state.seeking_to or (state.from + (state.index - 1) / state.fps)
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
  local at = M.position()
  local now = ui_ok and ui.duration(at) or ("%.1fs"):format(at)
  local total = (ui_ok and state.duration) and ui.duration(state.duration) or nil

  -- **The bar measures the film, not the window.** It used to be the index
  -- within the decoded run, which is two seconds long — so it filled up and
  -- reset every two seconds forever, and a reader reported it as "it loads and
  -- starts over" rather than as a position. It is next to a clock that reads
  -- `0:55 / 9:05`; anything but the same fraction is a second, contradictory
  -- answer to the question the clock already answers.
  --
  -- Without a duration there is no film to measure, and the window is the only
  -- thing left to report — which is honest there, since nothing else on the
  -- row claims a total either.
  local width = math.max(8, state.cols - 28)
  local fraction
  if state.duration and state.duration > 0 then
    fraction = math.min(1, math.max(0, at / state.duration))
  elseif state.frames > 1 then
    fraction = (state.index - 1) / (state.frames - 1)
  else
    fraction = 1
  end
  local filled = math.floor(fraction * width + 0.5)
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
  -- A scrub owns the decoder until its window lands, and what it is fetching
  -- is where the picture is going. Prefetching the continuation of where it
  -- came from would race that decode for the same slot.
  if state.seeking_to or state.scrubbing then
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
  -- A scrub's window has not landed yet, so `from` still describes where the
  -- picture *was* and mpv is already somewhere else: deriving a frame from the
  -- two would paint whatever the clamp happened to produce. The control row is
  -- still refreshed, since `position` already reports the place asked for, and
  -- the picture follows the moment the decode arrives.
  if state.seeking_to then
    draw()
    return
  end
  if pos then
    -- **A seek is not instant, and its first replies are stale.** mpv keeps
    -- reporting the position it is leaving for a tick or two after `seek`, and
    -- taking those at face value paints the frames the seek was issued to skip
    -- — a visible stutter backwards at the exact moment the sound joins.
    -- Waiting until the reported position reaches the target costs at most a
    -- couple of frames and removes it. The tolerance is one frame: mpv seeks to
    -- a keyframe, which can land marginally short of what was asked for, and an
    -- exact comparison would wait forever.
    if state.audio_catch_up then
      if pos < state.audio_catch_up - 1 / state.fps then
        return
      end
      state.audio_catch_up = nil
    end

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
    audio_catch_up = nil,
    -- The local clock has nothing to run from until mpv answers once; until
    -- then `advance(nil)` counts frames, exactly as a run without sound does.
    clock_pos = nil,
    clock_at = 0,
    synced_at = 0,
    syncing = false,
    -- Absent when the caller cannot decode more (no duration to count from,
    -- an offset it could not resolve): the transport then behaves exactly as
    -- it did before windows rolled, stopping at the end of the one it has.
    request = spec.request,
    next_run = nil,
    requesting = false,
    exhausted = spec.request == nil,
    -- No scrub in flight: the run starts exactly where the caller decoded it.
    seeking_to = nil,
    scrubbing = false,
    scrub_target = spec.from or 0,
  }
  return draw()
end

---@internal
--- Move to `target` seconds when it lies outside the decoded window: seek mpv
--- there and fetch a window that starts there.
---
--- **Coalesced, because a held key outruns ffmpeg.** A window costs about
--- 0.6 s to decode and sample, and a reader leaning on the step key produces
--- one request every few milliseconds. Issuing them all would start an ffmpeg
--- per press and paint the answers in whatever order they landed. So one
--- decode is in flight at a time, `scrub_target` is always the newest place
--- asked for, and when a decode lands on a stale target the next one is issued
--- immediately — the reader waits for one window, never for a queue of them.
---@param target number
---@return nil
local function scrub_to(target)
  if not state then
    return
  end
  if state.audio then
    pcall(state.audio.seek, target)
    -- mpv is on its way there; the local clock must not keep reporting the
    -- place it was seeked away from, or the next tick paints backwards.
    clock_set(target)
  end
  -- The prefetched window is the continuation of where the picture *was*, and
  -- after a seek it continues nothing. `exhausted` goes with it: the end of
  -- the file is no longer a settled fact once the position moves.
  state.next_run = nil
  state.requesting = false
  state.exhausted = false

  if not state.request then
    -- Nothing can be decoded (no resolvable offset), so the window on screen
    -- is all there is. mpv has still been seeked, which is the honest half of
    -- the answer, and the clock is left telling the truth about the picture.
    return
  end

  state.seeking_to = target
  state.scrub_target = target
  draw()
  if state.scrubbing then
    return
  end
  state.scrubbing = true

  local function issue()
    if not state then
      return
    end
    local want = state.scrub_target
    local gen = state.gen
    state.request(want, function(run)
      if not state or state.gen ~= gen then
        return
      end
      if run then
        state.from = want
        state.raw = run.raw
        state.frames = run.frames
        state.index = 1
      end
      if state.scrub_target ~= want then
        issue()
        return
      end
      state.scrubbing = false
      state.seeking_to = nil
      draw()
    end)
  end
  issue()
end

--- Step by `delta` frames and repaint, without starting the timer.
---
--- **A step is a position in the file, not an index into the window.** It used
--- to be the latter, clamped to `[1, frames]` — and since a window is two
--- seconds, that made the transport keys unable to leave them: stepping back
--- stopped dead at the start of the current window, and pressing play then
--- resumed from there. Right after play began, that window started at the
--- opening offset, so it read exactly as "it jumps back to 0:54 and plays on
--- from there". Reported 2026-09-08.
---
--- So the target is computed in seconds and, when it falls outside the window
--- on screen, `scrub_to` fetches the window that contains it. Inside one —
--- which is the common case, a press or two — nothing is decoded at all and
--- the step is the repaint it always was.
---
--- Clamped to the file rather than wrapped: running off the end back to the
--- beginning would read as the video looping when it is not.
---
--- mpv is seeked to match. It is always paused by the time this runs
--- (`hover.play_step` pauses first), so this only keeps mpv's own position
--- honest for whenever play resumes; it does not itself start or stop
--- anything.
---@param delta integer
---@return nil
function M.step(delta)
  if not M.is_active() or not state then
    return
  end

  local target = M.position() + delta / state.fps
  if target < 0 then
    target = 0
  end
  if state.duration and state.duration > 0 then
    -- One frame short of the end: a window starting exactly at the duration
    -- decodes nothing, and the reader would have stepped into a dead stop.
    target = math.min(target, math.max(0, state.duration - 1 / state.fps))
  end

  local first = state.from
  local last = state.from + (state.frames - 1) / state.fps
  -- Without a decoder the window is the whole of what exists, so its edges are
  -- the file's: clamped exactly as this behaved before a step could leave one.
  if not state.request then
    target = math.max(first, math.min(last, target))
  end
  if not state.seeking_to and target >= first and target <= last then
    local index = math.floor((target - first) * state.fps + 0.5) + 1
    index = math.max(1, math.min(state.frames, index))
    if index == state.index then
      return
    end
    state.index = index
    if state.audio then
      pcall(state.audio.seek, first + (index - 1) / state.fps)
      clock_set(first + (index - 1) / state.fps)
    end
    draw()
    return
  end

  scrub_to(target)
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
  -- At the end, play restarts the window rather than doing nothing: the key
  -- was pressed to see something move. mpv is seeked back with it — resetting
  -- the index alone would have the picture start over while the sound carried
  -- on from where it stopped, and the next `time-pos` would undo the reset
  -- anyway.
  if not state.seeking_to and state.index >= state.frames then
    state.index = 1
    if state.audio then
      pcall(state.audio.seek, state.from)
      clock_set(state.from)
    end
  end
  state.playing = true
  -- The clock was frozen at the pause; restarting its reference point is what
  -- keeps the time spent paused out of it.
  if state.clock_pos then
    clock_set(state.clock_pos)
  end

  if state.audio then
    pcall(state.audio.resume)
  elseif state.path and not state.audio_starting then
    state.audio_starting = true
    local gen = state.gen
    -- `position`, not the window arithmetic: a scrub whose window is still
    -- decoding has already moved where playing should begin, and mpv started
    -- at the old place would have to be seeked immediately afterwards.
    local at = M.position()
    local ok_audio, audio = pcall(require, "media.core.audio")
    if not ok_audio or not audio.available() then
      state.audio_starting = false
    else
      hook_cleanup()
      -- Paused, because the picture does not wait for it: see the callback.
      audio.start(state.path, { at = at, paused = true }, function(handle)
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
          if state.playing then
            -- **The picture kept moving while mpv was starting, so mpv joins
            -- it rather than the other way round.** mpv takes about a second
            -- to answer its socket; the transport paints from frame one
            -- immediately, so by now the picture is a second further on than
            -- the offset mpv was told to start at. Letting mpv's clock take
            -- over unadjusted dragged the picture back to where play was
            -- pressed — reported as "the sound comes in and the video starts
            -- from the beginning again".
            --
            -- Seeking it forward instead means nothing on screen moves
            -- backwards, and because it was started paused, no sound has been
            -- heard from the wrong place either.
            --
            -- Only when the picture actually moved: mpv's socket answering
            -- fast enough that `now` still equals the offset it was started
            -- at means there is nothing to catch up on, and seeking anyway is
            -- a real IPC round trip spent on a no-op.
            local now = state.from + (state.index - 1) / state.fps
            if now > at then
              state.audio_catch_up = now
              pcall(handle.seek, now)
            end
            pcall(handle.resume)
          else
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
      -- A resync may be due; it never blocks this tick, and the frame is
      -- drawn from the local clock either way.
      sync_clock()
      advance(clock_now())
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
  -- Freeze the local clock where it *is*, not at the last sync: `clock_now`
  -- stops advancing the moment `playing` goes false, and without this the
  -- frozen value would be up to a quarter of a second stale.
  local frozen = clock_now()
  state.playing = false
  if frozen then
    clock_set(frozen)
  end
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
