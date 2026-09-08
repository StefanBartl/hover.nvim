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

  local page = math.max(1, math.floor(opts.page or 1))
  local probe = media.probed(target.path)
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
