---@diagnostic disable: need-check-nil
-- The test body is the guard; see the note in TESTS/bare_path_spec.lua
-- (`LLS-42`).

-- TESTS/video_spec.lua -- a video path under the cursor, shown as a still.
--
-- **The extraction itself is not here** -- it needs ffmpeg, a video file and a
-- terminal that can draw, and media.nvim's own suite already holds the argv
-- that produces the still. What a run can check is the four decisions on this
-- side of the seam, and each one is a real failure when it is wrong:
--
--   1. **Which extensions are claimed.** A claim routes a file away from the
--      badge that would otherwise be correct, so a wrong one costs the reader
--      an answer and gives back an error. `.ts` is the case that matters:
--      it is an MPEG transport stream *and* it is TypeScript, and in an editor
--      the second reading wins by orders of magnitude.
--   2. **That `classify` produces the type at all**, since a target type that
--      nothing produces is a dispatch branch nothing reaches.
--   3. **The paging arithmetic.** An off-by-one here shows the second still at
--      the first one's offset and nothing about the picture looks wrong.
--      Percentages have to compose against a duration, seconds have to be
--      taken as seconds, and a file that reports no duration still has to
--      step -- the three cases that produce three different formulas.
--   4. **That a missing media.nvim is a badge and not an error.** It is the
--      normal state of every machine that has not installed it, and hover.nvim
--      does not require it.

local formats = require("hover.formats")
local classify = require("hover.classify")
local video = require("hover.preview.video")

describe("which extensions are a video", function()
  it("claims the containers people actually put video in", function()
    for _, ext in ipairs({ "mp4", "mkv", "mov", "avi", "webm", "m4v", "wmv", "flv", "m2ts" }) do
      assert.is_true(formats.is_video(ext), ext .. " should be a video")
    end
  end)

  it("is case-insensitive, because a filename is", function()
    assert.is_true(formats.is_video("MP4"))
    assert.is_true(formats.is_video("MkV"))
  end)

  it("does not claim .ts or .mts, which are TypeScript far more often", function()
    -- The failure this prevents is not subtle once it happens: every
    -- TypeScript file in a project hovers as a video, and the first thing
    -- that touches it is ffmpeg.
    assert.is_false(formats.is_video("ts"))
    assert.is_false(formats.is_video("mts"))
  end)

  it("does not claim audio, which has no frame to lift out", function()
    for _, ext in ipairs({ "mp3", "wav", "flac", "ogg", "opus", "m4a" }) do
      assert.is_false(formats.is_video(ext), ext .. " should not be a video")
    end
  end)

  it("keeps a label for every video it claims, since the badge is the fallback", function()
    for _, ext in ipairs({ "mp4", "mkv", "webm", "m2ts", "3gp" }) do
      assert.is_truthy(formats.label(ext), ext .. " has no label")
    end
  end)

  it("does not confuse a video with an office document", function()
    assert.is_false(formats.is_office("mp4"))
    assert.is_false(formats.is_video("docx"))
  end)
end)

describe("classify", function()
  it("gives a real video file the video type", function()
    local path = vim.fn.tempname() .. ".mp4"
    local fd = assert(io.open(path, "wb"))
    fd:write("not really a video, and it does not have to be")
    fd:close()

    local target = classify.classify(path)
    assert.equals("video", target.type)
    assert.equals("mp4", target.ext)

    os.remove(path)
  end)

  it("declares the type in its list, so auto_hover and health can name it", function()
    assert.is_true(vim.tbl_contains(classify.TYPES, "video"))
  end)
end)

describe("the offset a paging key lands on", function()
  it("is the configured start for the first still", function()
    -- Page 1 is `at` verbatim, including its shape: a percentage is passed
    -- through to media.nvim rather than resolved here, so a file whose
    -- duration is not known yet still gets the right frame.
    assert.equals("10%", video.offset_for(1, "10%", "10%", nil))
    assert.equals(0, video.offset_for(1, 0, 5, 600))
  end)

  it("composes percentages against the duration", function()
    -- 10% of 600s is 60s, so page 1 is at 60 and every page after adds
    -- another 60: page 2 is a fifth of the way in, page 4 is two fifths.
    assert.equals(120, video.offset_for(2, "10%", "10%", 600))
    assert.equals(240, video.offset_for(4, "10%", "10%", 600))
  end)

  it("makes ten presses walk any file end to end", function()
    -- The reason the defaults are percentages rather than seconds: the same
    -- setting has to be right for a ten-second clip and a two-hour feature.
    for _, duration in ipairs({ 10, 600, 7200 }) do
      assert.equals(duration, video.offset_for(10, "10%", "10%", duration))
    end
  end)

  it("takes seconds as seconds, and lets the two forms mix", function()
    assert.equals(15, video.offset_for(4, 0, 5, 600))
    assert.equals(120, video.offset_for(3, 0, "10%", 600))
  end)

  it("falls back to a fixed step when the file reports no duration", function()
    -- A raw stream and a file whose header was never rewritten after a hard
    -- cut both report none, and refusing to step would be the wrong answer to
    -- a file that is otherwise perfectly playable.
    assert.equals(5, video.offset_for(2, 0, "10%", nil))
    assert.equals(20, video.offset_for(5, 0, "10%", nil))
  end)

  it("treats a page below one as the first page", function()
    assert.equals("10%", video.offset_for(0, "10%", "10%", 600))
    assert.equals("10%", video.offset_for(-3, "10%", "10%", 600))
  end)
end)

describe("resolving an offset to seconds", function()
  -- The bug this was written for: `video.at` is a percentage by default, and
  -- `start_playback` recorded a flat 0 whenever it was not already a number.
  -- That put the control row's clock at zero on every video, and once windows
  -- started rolling it asked for the second one from two seconds into the
  -- file rather than two seconds past where the first one ended -- so the
  -- picture jumped backwards at every seam.
  it("passes a number through", function()
    assert.equals(42, video.to_seconds(42, 600))
    assert.equals(0, video.to_seconds(0, nil))
  end)

  it("takes a percentage of the duration", function()
    assert.equals(60, video.to_seconds("10%", 600))
    assert.equals(300, video.to_seconds("50%", 600))
  end)

  it("cannot take a percentage of a duration it does not have", function()
    -- Not an error and not a guess: the caller withholds `request`, and the
    -- transport plays the one window it decoded instead of rolling to a place
    -- it computed wrongly.
    assert.is_nil(video.to_seconds("10%", nil))
  end)

  it("leaves an ffmpeg timestamp to ffmpeg", function()
    -- Resolvable there, not here. Same answer as above, same consequence.
    assert.is_nil(video.to_seconds("00:01:23", 600))
    assert.is_nil(video.to_seconds("00:01:23.5", nil))
  end)

  it("answers nil for anything that is not an offset at all", function()
    assert.is_nil(video.to_seconds(nil, 600))
    assert.is_nil(video.to_seconds(true, 600))
    assert.is_nil(video.to_seconds("later", 600))
  end)
end)

describe("without media.nvim installed", function()
  it("answers with a badge that says so, rather than failing", function()
    -- The normal state of a machine that has not installed the optional
    -- dependency. `package.loaded` is forced to a non-table so the `pcall`
    -- inside the previewer takes the missing branch even on a machine where
    -- media.nvim *is* on the runtimepath.
    local saved = package.loaded["media"]
    package.loaded["media"] = false

    local content = video.preview({
      type = "video",
      raw = "clip.mp4",
      path = "/tmp/clip.mp4",
      ext = "mp4",
      size = 1024,
    }, { inline_images = true }, function() end)

    package.loaded["media"] = saved

    assert.is_table(content)
    assert.is_truthy(content.lines)
    local text = table.concat(content.lines, "\n")
    assert.is_truthy(text:find("MP4 video", 1, true), "the badge still names the format")
    assert.is_truthy(text:find("media.nvim", 1, true), "and says what is missing")
    assert.is_nil(content.pending, "a badge is a final answer, not a placeholder")
  end)

  it("shows the badge without a frame when inline images are off", function()
    local content = video.preview({
      type = "video",
      raw = "clip.mp4",
      path = "/tmp/clip.mp4",
      ext = "mp4",
      size = 1024,
    }, { inline_images = false }, function() end)

    assert.is_truthy(table.concat(content.lines, "\n"):find("MP4 video", 1, true))
    assert.is_nil(content.pending)
  end)
end)
