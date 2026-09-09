---@module 'hover.preview.external'
---@brief The `<CR>` fallback for a video hover when no mpv window can be
--- opened at all: the file, handed to whatever already plays it on this
--- machine.
---@description
--- **The third tier, below the mpv window and above the silent inline
--- transport.** `video.playback = "window"` tries a real mpv window first --
--- video and sound, positioned and stoppable, because `media.core.player`
--- owns the process end to end. Without mpv on PATH there is still a better
--- answer than a muted run of block graphics: `media.play()` (the same call
--- `hover.init`'s `gf` handler already makes) opens the file in a configured
--- player, or the system's own registered handler for it -- nothing here to
--- install beyond what already opens a video by hand.
---
--- **Nothing here can stop it.** `media.play()` on Windows hands off through
--- `explorer.exe`, which dispatches to the registered app and exits itself
--- almost immediately -- there is no PID of the real player left to hold, let
--- alone kill, the way `preview.window` holds mpv's. `<CR>` a second time (or
--- closing the hover) only drops the float back to the still; the external
--- player keeps running until its own window is closed by hand, exactly as it
--- would have if opened with `gf` in the first place.
---
--- **Idempotent per path, because nothing here holds anything to close
--- first.** `preview.window.open` always calls its own `close()` before
--- opening again, so a resize re-triggering it just restarts mpv at the same
--- place. This module cannot do that trick -- there is no handle -- so it
--- tracks the last path it handed off instead, and a second call for the
--- same path while the float has not closed in between is a no-op rather
--- than a second copy of the same file opening again.
---
--- **A known classic player, launched directly, when alignment is wanted.**
--- Reported 2026-09-09: the system's own handler (VLC, on the machine this
--- was reported from) opened in *fullscreen*, which `align_win`'s
--- `SetWindowPos` cannot usefully act on either way -- a window covering the
--- whole monitor is indistinguishable from "aligned" and indistinguishable
--- from "ignored the move". `media.play()` hands off through the system's
--- own association, whose remembered state (fullscreen, last session) this
--- module has no way to ask about, let alone override. So when `opts.align`
--- is set and `opts.prefer_classic` has not been turned off, this tries a
--- short list of known, scriptable players by name first -- `vlc
--- --no-fullscreen`, today -- and only falls to `media.play()` when none of
--- them is on PATH. A player found this way still goes through
--- `align_win.try_centre_new_window` exactly as the generic path does;
--- avoiding fullscreen is what makes that step able to do anything at all,
--- not a replacement for it.

local M = {}

--- Classic, scriptable video players this module can launch directly, and
--- the flag each needs to start in a normal window rather than fullscreen.
--- Short on purpose: every entry here is one this project could actually
--- verify starts non-fullscreen with the flag given, not a guess at what
--- "most players probably support".
---@type { bin: string, args: string[] }[]
local KNOWN_PLAYERS = {
  { bin = "vlc", args = { "--no-fullscreen" } },
}

---@internal
--- The first known player found on PATH, launched on `path`. `nil` opts out
--- of nothing here -- an empty `KNOWN_PLAYERS` (or none installed) simply
--- means this tries none and the caller falls to `media.play()`.
---@param path string
---@return boolean ok
local function try_known_player(path)
  for _, player in ipairs(KNOWN_PLAYERS) do
    if vim.fn.executable(player.bin) == 1 then
      local argv = { player.bin }
      for _, a in ipairs(player.args) do
        argv[#argv + 1] = a
      end
      argv[#argv + 1] = path
      local ok_call = pcall(vim.system, argv, {})
      if ok_call then
        return true
      end
    end
  end
  return false
end

--- The path last handed to the system opener since the last `M.reset()`, or
--- nil. Compared by identity of the string, not the file: two different
--- paths to the same file are treated as different requests, which is the
--- conservative reading -- a spurious extra open is a minor annoyance, a
--- refused one reads as the feature not working at all.
---@type string|nil
local launched_for = nil

--- Whether `M.open` has already handed a path off since the last reset --
--- `hover.init` asks this to decide whether `<CR>` has anything to "stop"
--- (drop the hover back to the still) the way it does for the mpv window.
---@return boolean
function M.is_open()
  return launched_for ~= nil
end

--- Hand `path` to whatever plays it without mpv: a known classic player when
--- alignment is wanted and one is found (see the module doc), else a
--- configured `media.player`, else the system's own registered handler
--- ([`media.play`](https://github.com/StefanBartl/media.nvim)). A second call
--- for the same path this float is still open for is a no-op -- see the
--- module doc for why nothing here can close the first one before trying
--- again the way `preview.window` does.
---@param path string
---@param opts? { align?: boolean, prefer_classic?: boolean } `align`:
--- best-effort attempt to centre whatever new window appears afterwards --
--- see `align_win`. `prefer_classic` (default true, and irrelevant unless
--- `align` is also set): try a known classic player by name first, since a
--- fullscreen window defeats alignment before it starts.
---@return boolean ok
function M.open(path, opts)
  if launched_for == path then
    return true
  end

  opts = opts or {}
  local opened = false

  if opts.align and opts.prefer_classic ~= false then
    opened = try_known_player(path)
  end

  if not opened then
    local ok_media, media = pcall(require, "media")
    if ok_media and type(media.play) == "function" then
      -- Two different questions: did the call raise (`ok_call`), and did
      -- `media.play` itself say the hand-off worked (`played`). `pcall`'s
      -- own success flag is not that second answer -- `pcall(f)` reports
      -- `true` for any `f` that returns without erroring, including one
      -- that returns `false, "reason"` on purpose.
      local ok_call, played = pcall(media.play, path)
      opened = ok_call and played == true
    end
  end

  if not opened then
    return false
  end

  launched_for = path

  if opts.align then
    -- Best-effort and asynchronous: see `align_win` for why this can do
    -- nothing at all on this exact machine and why that is not reported.
    -- Runs for a known player too -- avoiding fullscreen only makes the
    -- window reachable, it does not itself move anything.
    pcall(require("hover.preview.align_win").try_centre_new_window)
  end

  return true
end

--- Forget the last hand-off, so the next `M.open` for the same path is a
--- real one rather than the no-op guard above. Registered as the float's
--- `on_close`, and called by the transport key's own "stop" gesture.
---@return nil
function M.reset()
  launched_for = nil
end

return M
