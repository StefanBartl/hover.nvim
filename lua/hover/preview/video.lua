---@module 'hover.preview.video'
---@brief Videos: a badge by default, a still from the file when one can be
---made — and the paging keys turn that still into a scrub.
---@description
--- **Why a video cannot be previewed the way anything else here is.** There is
--- no text in it, so the byte test in `preview.binary` is right that it is
--- binary — and stops there, at "◆ MP4 video · 42 MB", which is every question
--- about a video except the one anybody asks. There is also no arrangement of
--- terminal escapes that plays it: the only image protocol that reaches the
--- terminal from inside Neovim carries a whole picture per write and has no
--- notion of a frame, and Neovim repaints over anything drawn between its own
--- redraws. Whatever this shows has to be a still.
---
--- **So it is the office route, one group over.** An office document becomes a
--- picture by way of a PDF page; a video becomes one by way of a frame.
--- [media.nvim](https://github.com/StefanBartl/media.nvim) produces it —
--- `media.frame` seeks with ffmpeg, scales, and caches the PNG on disk keyed by
--- the source file's mtime — and from there this is an image hover: the same
--- canvas geometry, the same draw, the same keys.
---
--- **The paging keys are the scrub, and that is not a metaphor.** `preview.
--- media.pdf` reports `scroll = { page = n }` and the reader's next/previous
--- keys move it; this reports the same thing, and page *n* is the still at
--- `at + (n-1) * step` into the file. Nothing new was needed on either side —
--- what a PDF calls a page, a video calls a moment. Every offset visited is a
--- cache entry, so stepping back through a file already walked is instant.
---
--- **What it costs when it is not there.** No media.nvim, no ffmpeg, no image
--- provider, `inline_images = false` — each of those degrades to the badge with
--- a note saying which one it was, and none of them is an error. The badge is
--- also what an audio file gets: `media.probe` will describe an mp3 happily,
--- but there is no frame to show and a hover is not the place to read a tag
--- dump.
---
--- **The metadata line is worth its row.** Under the badge, and under the
--- picture in the border, goes `1920x1080 · 4:32 · h264 · 100 MB` — from
--- `media.ui.summary`, so this plugin and `:Media probe` describe the same file
--- with the same words. It is the one thing a still cannot say about itself.

local M = {}

---@type number Seconds a step moves when the file reports no duration.
--- The percentage form is preferred (see `step_at`) because it makes ten
--- presses walk any file end to end regardless of length. A file without a
--- duration cannot have a percentage taken of it, and then a fixed step is the
--- only thing left — five seconds, because it is far enough to reach a
--- different shot and near enough that a keyframe is likely.
local FALLBACK_STEP_SECONDS = 5

---@internal
--- The offset for page `page`, given what is known about the file.
---
--- Pure, and public, because it is the whole of the paging arithmetic and the
--- part that is invisible in a rendered still: an off-by-one here shows page 2
--- at page 1's offset and nothing looks wrong.
---
--- Percentages compose the way a reader expects — `at = "10%"`, `step = "10%"`
--- means ten presses cover the film — and are what makes one setting work for a
--- ten-second clip and a two-hour feature. Seconds are honoured when either
--- setting is a number, and mixing them is allowed: `at = 0`, `step = "5%"` is
--- a perfectly reasonable pair.
---@param page integer 1-based
---@param at number|string
---@param step number|string
---@param duration number|nil
---@return number|string offset  # seconds, or a percentage string for media.nvim to resolve
function M.offset_for(page, at, step, duration)
  local index = math.max(0, math.floor(page) - 1)
  if index == 0 then
    return at
  end

  ---@param value number|string
  ---@return number|nil
  local function seconds(value)
    if type(value) == "number" then
      return value
    end
    local percent = type(value) == "string" and value:match("^%s*([%d%.]+)%s*%%%s*$") or nil
    local fraction = percent and tonumber(percent) or nil
    if fraction and duration then
      return duration * fraction / 100
    end
    return nil
  end

  local base = seconds(at) or 0
  local stride = seconds(step) or FALLBACK_STEP_SECONDS
  return base + index * stride
end

--- `value` as a number of seconds, or nil when it cannot be one.
---
--- The three shapes `video.at` and `video.step` accept, reduced to the one the
--- transport can do arithmetic with: a number passes through, a percentage is
--- taken of the duration, and an ffmpeg timestamp (`"00:01:23"`) is left for
--- ffmpeg — resolvable there, not here, so this answers nil and the caller
--- treats the window as un-rollable rather than guessing.
---@param value number|string|nil
---@param duration number|nil
---@return number|nil
function M.to_seconds(value, duration)
  if type(value) == "number" then
    return value
  end
  if type(value) ~= "string" then
    return nil
  end
  local percent = value:match("^%s*([%d%.]+)%s*%%%s*$")
  local fraction = percent and tonumber(percent) or nil
  if fraction and duration then
    return duration * fraction / 100
  end
  return nil
end

---@internal
--- Whether there is anything past `offset` worth stepping to.
---
--- `more` drives the reader's "next" key. Saying yes forever means the key
--- eventually renders nothing and reports a failure; saying no too early takes
--- away the end of the file. Without a duration the honest answer is yes — the
--- step that finds nothing will say so, which is better than refusing to try.
---@param offset number|string
---@param duration number|nil
---@return boolean
local function more_after(offset, duration)
  if not duration or duration <= 0 then
    return true
  end
  if type(offset) ~= "number" then
    return true
  end
  return offset < duration
end

---@internal
---@param target Hover.Target
---@param note string|nil
---@return Hover.Content
local function badge(target, note)
  return require("hover.preview.binary").badge(target, { note = note })
end

---@internal
--- The badge, with the metadata line appended when a probe is already in hand.
---
--- Only when it is *already* in hand: this runs on the synchronous path, and
--- starting an ffprobe to decorate a fallback would put a process behind every
--- hover over a file this plugin has just said it cannot show.
---@param target Hover.Target
---@param note string|nil
---@return Hover.Content
local function badge_with_summary(target, note)
  local content = badge(target, note)
  local ok, media = pcall(require, "media")
  if not ok then
    return content
  end
  local probe = media.probed(target.path)
  if not probe then
    return content
  end
  local summary = require("media.ui").summary(probe)
  if summary ~= "" then
    -- Above the note, which is an explanation of why there is no picture and
    -- belongs last.
    table.insert(content.lines, #content.lines, summary)
  end
  return content
end

---@internal
--- Cell size for the playback canvas: the float's box, narrowed to the
--- video's aspect ratio so the picture is not stretched across it.
---
--- One row is reserved for the control line. Without that the canvas fills the
--- float exactly and the control row pushes the last picture row out of view
--- -- which reads as the video being cropped, not as a missing row.
---
--- Public for the same reason `offset_for` is: it is one half of a pair that
--- has to agree, and the failure when it does not is silent. `float.open`
--- clamps the window to the same box this reads; a canvas wider than that
--- wraps every row onto two and nothing raises an error. The spec asserts the
--- two against each other, which it can only do by calling this one.
---@param probe table|nil
---@param opts Hover.PreviewOpts
---@return integer cols, integer rows
function M.playback_cells(probe, opts)
  -- **The budget, minus the border, and no scaling of its own.**
  -- `video.play_scale` is applied where the box itself is decided
  -- (`hover.box`), so the float and this canvas are the same number seen
  -- twice rather than two derivations of it. Scaling here as well produced a
  -- canvas wider than the float that showed it: every row wrapped and the
  -- control row fell off the bottom. Reported 2026-09-08.
  --
  -- One row goes to the control line; without it the canvas fills the float
  -- exactly and the control row pushes the last picture row out of view --
  -- which reads as the video being cropped, not as a missing row.
  local max_cols = math.max(16, (opts.max_width or 80) - 2)
  local max_rows = math.max(6, (opts.max_lines or 24) - 2)

  local ok_scale, scale = pcall(require, "images.scale")
  if ok_scale and probe and probe.width and probe.height then
    local cols, rows =
      scale.fit_cells(max_cols, max_rows, { width = probe.width, height = probe.height })
    return cols, rows
  end
  return max_cols, max_rows
end

---@internal
--- Build the playing view: a run of stills sampled into cells, the canvas
--- lines they are painted onto, and the control row under them.
---
--- Returns nil (with a reason) rather than a badge, so the caller can decide
--- whether a failure here means "show the still instead" -- which it always
--- does: everything this needs beyond the still is optional.
---@param target Hover.Target
---@param opts Hover.PreviewOpts
---@param probe table|nil
---@param on_result fun(content: Hover.Content): nil
---@return boolean started
local function start_playback(target, opts, probe, on_result)
  local ok_media, media = pcall(require, "media")
  local ok_blocks, blocks = pcall(require, "images.blocks")
  if
    not ok_media
    or type(media.frames) ~= "function"
    or not ok_blocks
    or not blocks.available()
  then
    return false
  end

  local cols, rows = M.playback_cells(probe, opts)
  local fps = opts.video_fps or 12
  local count = opts.video_run or 24
  local duration = probe and probe.duration or nil

  -- **Where the run starts, in seconds — and it is not where the still came
  -- from.** `video_at` is a thumbnail offset, ten percent in by default so the
  -- picture is not a fade-in or a distributor's slate. Playing borrowed that
  -- number, so a nine-minute video began at 0:54 and a two-minute one at 0:14,
  -- with no way back to the opening. Reported 2026-09-08, and the two settings
  -- are separate from here on: `video_play_at` is the beginning of the file
  -- unless configured otherwise.
  --
  -- A *scrubbed* still is the exception, and not an inconsistency: page 2
  -- onward is a position the reader chose with the paging keys, so play starts
  -- from what is on screen rather than from the top.
  --
  -- `nil` means the offset could not be resolved (a percentage of a file that
  -- reports no duration), and the transport then plays the one window it has.
  local page = math.max(1, math.floor(opts.page or 1))
  local play_at = opts.video_play_at
  if play_at == nil then
    play_at = 0
  end
  if page > 1 then
    play_at = M.offset_for(page, opts.video_at or "10%", opts.video_step or "10%", duration)
  end
  local from_seconds = M.to_seconds(play_at, duration)

  -- Sized from the canvas when nothing is configured: a still is sampled down
  -- to `cols` pixels across, and decoding much more than twice that is decode
  -- time and cache bytes spent on detail the downsample averages away — while
  -- decoding *less* than the canvas is the pixelation the larger canvas exists
  -- to remove. media.nvim's own default is the floor, so a small float does
  -- not end up with a smaller source than it had before.
  local run_width = opts.video_run_width or math.max(320, cols * 2)

  --- Decode one window and sample it into cells.
  ---
  --- The whole of what a window costs, in one place, because the transport
  --- asks for the next one through exactly this function while the current one
  --- plays. `nil` without an error is the end of the file: ffmpeg returns the
  --- frames that exist, and past the last one there are none.
  ---@param at number|string
  ---@param cb fun(run: Hover.Playback.Run|nil, err: string|nil): nil
  ---@return nil
  local function decode(at, cb)
    media.frames(target.path, {
      from = at,
      fps = fps,
      count = count,
      width = run_width,
    }, function(pngs, err)
      if not pngs or #pngs == 0 then
        cb(nil, err)
        return
      end
      -- One ImageMagick pass for the whole run: per-file is 8.5x slower
      -- (measured in images.blocks), which is the difference between playback
      -- and a slideshow that arrives late.
      blocks.sample_async(pngs, cols, rows, function(raw, serr)
        if not raw then
          cb(nil, serr)
          return
        end
        cb({ raw = raw, frames = #pngs }, nil)
      end)
    end)
  end

  decode(from_seconds or play_at, function(run, err)
    if not run then
      on_result(badge_with_summary(target, err and ("(" .. err .. ")") or nil))
      return
    end
    local lines = blocks.canvas_lines(cols, rows)
    -- Placeholder: `playback.load` writes the real control row as soon as
    -- the float exists, and it needs a line to write into.
    lines[#lines + 1] = ""
    on_result({
      lines = lines,
      transport = true,
      playback = {
        raw = run.raw,
        frames = run.frames,
        cols = cols,
        rows = rows,
        fps = fps,
        from = from_seconds or 0,
        duration = duration,
        status_row = #lines - 1,
        -- `playback.play` starts audio from here, when there is a track to
        -- start and the reader has not turned it off — see `M.play` for why
        -- an mpv the file has no sound for is simply never worth starting.
        path = (opts.video_sound ~= false and probe and probe.has_audio) and target.path or nil,
        -- Only when the first offset is a real number of seconds: without one
        -- there is nothing to add a window length to, and a request from the
        -- wrong place would show the wrong part of the film.
        request = from_seconds and decode or nil,
      },
    })
  end)

  return true
end

--- Preview a video: a still from it, or a badge explaining why not.
---
--- Same contract as `preview.media.pdf` and `preview.office.preview` — return
--- what to show now, call `on_result` when the render lands — so
--- `hover.build_async` handles the staleness and the grace period for all
--- three identically.
---@param target Hover.Target
---@param opts Hover.PreviewOpts
---@param on_result fun(content: Hover.Content): nil
---@return Hover.Content
function M.preview(target, opts, on_result)
  if opts.inline_images == false then
    return badge_with_summary(target, nil)
  end

  local ok_media, media = pcall(require, "media")
  if not ok_media or type(media.frame) ~= "function" then
    return badge(target, "(media.nvim not installed — no frame preview)")
  end
  if not media.available() then
    return badge(target, "(ffmpeg not on PATH — no frame preview)")
  end

  local provider = require("lib.nvim.image_preview").detect()
  if not provider then
    return badge_with_summary(target, "(no image provider installed)")
  end

  local probe = media.probed(target.path)

  -- Playing is asked for, never assumed: a hover appears because a cursor
  -- rested somewhere, which is a glance and not a request for motion. The
  -- transport key sets `opts.play`, and only then is a run decoded at all.
  if opts.play then
    if start_playback(target, opts, probe, on_result) then
      return vim.tbl_extend(
        "force",
        badge_with_summary(target, "decoding frames…"),
        { pending = true }
      )
    end
    -- Nothing to play with (no media.nvim, no ImageMagick): fall through to
    -- the still, which is the honest answer and already on screen.
  end

  local page = math.max(1, math.floor(opts.page or 1))
  local offset = M.offset_for(
    page,
    opts.video_at or "10%",
    opts.video_step or "10%",
    probe and probe.duration or nil
  )

  ---@param png string
  ---@return Hover.Content
  local function content_for(png)
    local content = require("hover.preview.media").canvas_for(png, opts)
    content.scroll =
      { page = page, step = 1, more = more_after(offset, probe and probe.duration or nil) }
    -- Only a marker: it binds the transport key, and pressing it is what
    -- decodes anything.
    content.transport = true
    -- The first still stays untitled, as every image preview does: a filename
    -- over a picture the reader is already looking at is noise. From the second
    -- on, the timestamp is the one thing the picture cannot say about itself.
    if page > 1 then
      content.title = require("media.ui").duration(type(offset) == "number" and offset or nil)
    end
    return content
  end

  media.frame(target.path, {
    at = offset,
    width = opts.video_width,
  }, function(png, err)
    if not png then
      on_result(badge_with_summary(target, err and ("(" .. err .. ")") or nil))
      return
    end
    on_result(content_for(png))
  end)

  -- Marked pending: `media.frame` calls back on the next tick even for a cache
  -- hit, so this placeholder is normally replaced before the grace period lets
  -- it on screen. What the reader sees on a hit is the still and nothing else.
  return vim.tbl_extend(
    "force",
    badge_with_summary(target, "extracting frame…"),
    { pending = true }
  )
end

return M
