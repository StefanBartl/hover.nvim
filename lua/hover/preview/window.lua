---@module 'hover.preview.window'
---@brief The `<CR>` on a video hover, when playback means a real mpv window
--- rather than a run of stills painted into the float.
---@description
--- **Why this exists next to `preview.playback`.** That module turns a decode
--- into moving block graphics inside the float — every frame is
--- `nvim_buf_set_extmark` calls, and the picture is the editor's redraw twelve
--- times a second. On a fast terminal it is smooth; on Windows in WezTerm it
--- was measured at about one repaint a second however the paint was written
--- (buffer lines, then extmarks, then overlay virtual text — three rewrites,
--- one slideshow), because the ceiling is the redraw, not the Lua.
---
--- So `video.playback = "window"` (the default) sends `<CR>` here instead:
--- `media.play_window` opens mpv with a window and the video on, and this holds
--- the handle that stops it again. mpv decodes, scales and syncs the sound
--- itself, with no editor redraw in the loop — the float meanwhile shows a
--- short "playing" panel rather than a picture, because there is no picture in
--- it to show.
---
--- **Single-instance, like the float.** There is one hover and one window it
--- speaks for; opening a second closes the first. `M.close` is registered as
--- the float's `on_close`, so the window goes away however the hover does — a
--- cursor move, `q`, `:qa` — and `media.core.player` has its own `VimLeavePre`
--- backstop under that for the exit that runs no `on_close` at all.

local M = {}

--- The one live window, or nil. `Media.Player.Handle` — `stop()` is idempotent
--- and ends the process tree, `stopped()` says whether it already ran.
---@type Media.Player.Handle|nil
local handle = nil

--- Whether a window this module opened is still playing.
---@return boolean
function M.is_active()
  return handle ~= nil and not handle.stopped()
end

--- Open `spec.path` in an mpv window from `spec.at`, replacing any window
--- already open. Returns false plus a reason when mpv cannot be started — the
--- caller then falls back to the still, exactly as it does for a failed decode.
---@param spec { path: string, at: number|string|nil }
---@return boolean ok
---@return string|nil err
function M.open(spec)
  M.close()

  local ok_media, media = pcall(require, "media")
  if not ok_media or type(media.play_window) ~= "function" then
    return false, "media.nvim has no windowed player — update it"
  end

  -- Which monitor the terminal is on right now, so mpv's `--geometry`
  -- centres there instead of on screen 0 -- one quick, synchronous query
  -- (see `preview.monitor`'s own doc for why this is safe to assume and
  -- why it is Windows-only for the index itself, not just the bounds).
  -- Both `require` and the call itself are guarded: an older hover.nvim
  -- checkout without this module, or any other unexpected shape, must not
  -- turn "mpv would have played happily" into a crash.
  local ok_mon, monitor = pcall(require, "hover.preview.monitor")
  local detected
  if ok_mon and type(monitor) == "table" and type(monitor.detect) == "function" then
    local ok_detect, result = pcall(monitor.detect)
    detected = ok_detect and result or nil
  end

  local h, err = media.play_window(spec.path, {
    at = spec.at,
    screen = detected and detected.screen or nil,
  })
  if not h then
    return false, err or "mpv could not be started"
  end
  handle = h
  return true, nil
end

--- Stop the window, if there is one. Safe to call repeatedly, and from a
--- teardown path — it never raises.
---@return nil
function M.close()
  if handle then
    pcall(handle.stop)
    handle = nil
  end
end

return M
