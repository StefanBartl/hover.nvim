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

describe("where a played run starts", function()
  local DEFAULTS = require("hover.config.DEFAULTS")

  -- **The still's offset and the play offset are two settings, and treating
  -- them as one was the defect.** `at = "10%"` is right for a thumbnail --
  -- the first frame of a real video is a fade-in or a slate -- and wrong for
  -- playing, where it means a nine-minute file starts at 0:54 with no way
  -- back to the opening. Reported 2026-09-08 against two real files, and both
  -- numbers below are those files.
  it("is the beginning of the file, not the still's ten percent", function()
    assert.are.equal(0, DEFAULTS.video.play_at)
    assert.are.equal("10%", DEFAULTS.video.at, "the still keeps its thumbnail offset")
  end)

  it("resolves the reported symptom, so the fix is against the right number", function()
    -- RickBeato_720p.mp4 is 544.75s; Leben_wir_in_einer_Simulation.mp4 is 140.97s.
    assert.is_true(math.abs(video.to_seconds("10%", 544.75) - 54.475) < 1e-6)
    assert.is_true(math.abs(video.to_seconds("10%", 140.97) - 14.097) < 1e-6)
    assert.are.equal(0, video.to_seconds(DEFAULTS.video.play_at, 544.75))
  end)

  it("follows a scrubbed still, which is a position the reader chose", function()
    -- Page 1 is "wherever the still is"; from page 2 the reader has walked
    -- the file with the paging keys and play belongs where they stopped.
    assert.are.equal(0, video.offset_for(1, 0, "10%", 544.75))
    assert.is_true(math.abs(video.offset_for(3, 0, "10%", 544.75) - 108.95) < 1e-6)
  end)

  it("configures a larger canvas for playing than for the still", function()
    -- A cell is two pixel rows, so the still's 20-line budget is a 38-pixel
    -- picture -- which is what "very pixelated" meant. Sampling and painting
    -- were measured flat in the cell count (2026-09-08), so this costs
    -- essentially nothing.
    assert.is_true(DEFAULTS.video.play_scale > 1)
    assert.is_true(
      math.floor((DEFAULTS.max_lines - 2) * DEFAULTS.video.play_scale) > DEFAULTS.max_lines - 2
    )
  end)
end)

describe("the shared playback offset", function()
  -- **One function, two callers.** The inline transport and the window player
  -- both start playing at the same place, and a hand-kept copy of the
  -- arithmetic in each is how page 2's window ends up starting somewhere page 2
  -- is not -- a shape this repository has been bitten by more than once.
  it("is video_play_at on page one, resolved and raw", function()
    local raw, secs = video.playback_offset({ video_play_at = 0, page = 1 }, 600)
    assert.are.equal(0, raw)
    assert.are.equal(0, secs)

    -- A percentage of a file with no duration cannot be resolved: the raw form
    -- is still handed on (mpv resolves it), the seconds form is nil.
    local praw, psecs = video.playback_offset({ video_play_at = "50%", page = 1 }, nil)
    assert.are.equal("50%", praw)
    assert.is_nil(psecs)
  end)

  it("is the scrubbed position from page two on", function()
    -- Same numbers as `offset_for`, because it is `offset_for` underneath:
    -- page 3 with a 10% "at" and a 10% step is 30% into a 544.75s file --
    -- one `at` plus two strides, same as the still at that page.
    local raw, secs = video.playback_offset({
      video_play_at = 0,
      video_at = "10%",
      video_step = "10%",
      page = 3,
    }, 544.75)
    assert.is_true(math.abs(raw - 163.425) < 1e-6)
    assert.is_true(math.abs(secs - 163.425) < 1e-6)
  end)

  it("treats a nil video_play_at as the beginning", function()
    local raw = video.playback_offset({ page = 1 }, 600)
    assert.are.equal(0, raw)
  end)
end)

describe("playing in a window rather than the float", function()
  local DEFAULTS = require("hover.config.DEFAULTS")

  it("is the default, because the inline paint is a slideshow where it matters", function()
    -- Reported 2026-09-08: no measurable improvement from any of three
    -- rewrites of the inline paint, because the ceiling is the editor's redraw
    -- of a float-sized region, not the Lua. `<CR>` opens a real mpv window.
    assert.are.equal("window", DEFAULTS.video.playback)
    -- And mpv is used whenever it is there, by default -- `use_mpv = false`
    -- is a deliberate opt-out ("I have it, do not touch it"), not the norm.
    assert.are.equal(true, DEFAULTS.video.use_mpv)
  end)

  it("skips mpv when video_use_mpv is false, even though mpv is available", function()
    -- "I have mpv installed but do not want it used" is a real, separate
    -- request from playback = "inline": that setting also gives up the
    -- system player's real video and sound, which use_mpv = false must not.
    local saved_media = package.loaded["media"]
    local saved_ip = package.loaded["lib.nvim.image_preview"]
    package.loaded["lib.nvim.image_preview"] = {
      detect = function()
        return "stub"
      end,
    }
    local played = {}
    package.loaded["media"] = {
      frame = function() end,
      frames = function() end,
      available = function()
        return true
      end,
      probed = function()
        return { duration = 600 }
      end,
      -- mpv genuinely is available -- the point of this test is that
      -- `use_mpv = false` still skips it, not that mpv is missing.
      player_available = function()
        return true
      end,
      play = function(path)
        played[#played + 1] = path
        return true
      end,
    }

    local content = video.preview({
      type = "video",
      raw = "clip.mp4",
      path = "/tmp/clip.mp4",
      ext = "mp4",
      size = 1024,
    }, {
      inline_images = true,
      play = true,
      video_playback = "window",
      video_use_mpv = false,
      page = 1,
    }, function() end)

    package.loaded["media"] = saved_media
    package.loaded["lib.nvim.image_preview"] = saved_ip
    require("hover.preview.external").reset()

    assert.is_nil(content.play_window, "use_mpv = false must skip the mpv tier")
    assert.same({ "/tmp/clip.mp4" }, played, "and fall to the system-player tier, not silence")
    assert.are.equal("/tmp/clip.mp4", content.play_external)
  end)

  it("hands hover.init a play_window marker instead of decoding a run", function()
    local saved_media = package.loaded["media"]
    local saved_ip = package.loaded["lib.nvim.image_preview"]
    package.loaded["lib.nvim.image_preview"] = {
      detect = function()
        return "stub"
      end,
    }
    package.loaded["media"] = {
      frame = function() end,
      available = function()
        return true
      end,
      probed = function()
        return { duration = 600, width = 1920, height = 1080 }
      end,
      player_available = function()
        return true
      end,
    }

    local decoded = false
    package.loaded["images.blocks"] = setmetatable({
      available = function()
        decoded = true
        return true
      end,
    }, {
      __index = function()
        return function() end
      end,
    })

    local content = video.preview({
      type = "video",
      raw = "clip.mp4",
      path = "/tmp/clip.mp4",
      ext = "mp4",
      size = 1024,
    }, { inline_images = true, play = true, video_playback = "window", page = 1 }, function() end)

    package.loaded["media"] = saved_media
    package.loaded["lib.nvim.image_preview"] = saved_ip
    package.loaded["images.blocks"] = nil

    assert.is_table(content)
    assert.is_table(content.play_window)
    assert.are.equal("/tmp/clip.mp4", content.play_window.path)
    assert.are.equal(0, content.play_window.at)
    assert.is_true(content.transport, "the key stays bound, to stop the window")
    assert.is_nil(content.pending, "the window opens now; there is nothing to wait for")
    assert.is_false(decoded, "no run is decoded for a window playback")
  end)

  it("falls through to the inline route when video_playback is inline", function()
    local saved_media = package.loaded["media"]
    local saved_ip = package.loaded["lib.nvim.image_preview"]
    package.loaded["lib.nvim.image_preview"] = {
      detect = function()
        return "stub"
      end,
    }
    package.loaded["media"] = {
      frame = function() end,
      frames = function() end,
      available = function()
        return true
      end,
      probed = function()
        return { duration = 600 }
      end,
      player_available = function()
        return true
      end,
    }

    local content = video.preview({
      type = "video",
      raw = "clip.mp4",
      path = "/tmp/clip.mp4",
      ext = "mp4",
      size = 1024,
    }, { inline_images = true, play = true, video_playback = "inline", page = 1 }, function() end)

    package.loaded["media"] = saved_media
    package.loaded["lib.nvim.image_preview"] = saved_ip

    assert.is_nil(content.play_window, "inline mode never opens a window")
  end)

  it("falls through when mpv cannot be found", function()
    local saved_media = package.loaded["media"]
    local saved_ip = package.loaded["lib.nvim.image_preview"]
    package.loaded["lib.nvim.image_preview"] = {
      detect = function()
        return "stub"
      end,
    }
    package.loaded["media"] = {
      frame = function() end,
      frames = function() end,
      available = function()
        return true
      end,
      probed = function()
        return { duration = 600 }
      end,
      player_available = function()
        return false
      end,
    }

    local content = video.preview({
      type = "video",
      raw = "clip.mp4",
      path = "/tmp/clip.mp4",
      ext = "mp4",
      size = 1024,
    }, { inline_images = true, play = true, video_playback = "window", page = 1 }, function() end)

    package.loaded["media"] = saved_media
    package.loaded["lib.nvim.image_preview"] = saved_ip

    assert.is_nil(content.play_window, "no mpv, no window -- the still is the honest answer")
  end)
end)

describe("playing without mpv, handed to the system's own player", function()
  local external = require("hover.preview.external")

  local function stub_media(extra)
    return vim.tbl_extend("force", {
      frame = function() end,
      frames = function() end,
      available = function()
        return true
      end,
      probed = function()
        return { duration = 600 }
      end,
      player_available = function()
        return false
      end,
    }, extra or {})
  end

  it("hands hover.init a play_external marker instead of decoding a run", function()
    external.reset()
    local saved_media = package.loaded["media"]
    local saved_ip = package.loaded["lib.nvim.image_preview"]
    package.loaded["lib.nvim.image_preview"] = {
      detect = function()
        return "stub"
      end,
    }
    local played = {}
    package.loaded["media"] = stub_media({
      play = function(path)
        played[#played + 1] = path
        return true
      end,
    })

    local content = video.preview({
      type = "video",
      raw = "clip.mp4",
      path = "/tmp/clip.mp4",
      ext = "mp4",
      size = 1024,
    }, { inline_images = true, play = true, video_playback = "window", page = 1 }, function() end)

    package.loaded["media"] = saved_media
    package.loaded["lib.nvim.image_preview"] = saved_ip
    external.reset()

    assert.same({ "/tmp/clip.mp4" }, played, "media.play must actually have been called")
    assert.are.equal("/tmp/clip.mp4", content.play_external)
    assert.is_nil(content.play_window, "no mpv -- this is the system player, not a window")
    assert.is_true(content.transport, "the key stays bound, to dismiss the badge")
    assert.is_nil(content.pending, "the hand-off already happened; there is nothing to wait for")
  end)

  it("falls through to inline when media.play fails too", function()
    external.reset()
    local saved_media = package.loaded["media"]
    local saved_ip = package.loaded["lib.nvim.image_preview"]
    package.loaded["lib.nvim.image_preview"] = {
      detect = function()
        return "stub"
      end,
    }
    package.loaded["media"] = stub_media({
      play = function()
        return false, "no handler registered"
      end,
    })

    local content = video.preview({
      type = "video",
      raw = "clip.mp4",
      path = "/tmp/clip.mp4",
      ext = "mp4",
      size = 1024,
    }, { inline_images = true, play = true, video_playback = "window", page = 1 }, function() end)

    package.loaded["media"] = saved_media
    package.loaded["lib.nvim.image_preview"] = saved_ip
    external.reset()

    assert.is_nil(
      content.play_external,
      "nothing actually opened -- the badge must not claim it did"
    )
    assert.is_nil(content.play_window)
  end)

  it("is never tried when video_playback is inline", function()
    external.reset()
    local saved_media = package.loaded["media"]
    local saved_ip = package.loaded["lib.nvim.image_preview"]
    package.loaded["lib.nvim.image_preview"] = {
      detect = function()
        return "stub"
      end,
    }
    local played = false
    package.loaded["media"] = stub_media({
      play = function()
        played = true
        return true
      end,
    })

    local content = video.preview({
      type = "video",
      raw = "clip.mp4",
      path = "/tmp/clip.mp4",
      ext = "mp4",
      size = 1024,
    }, { inline_images = true, play = true, video_playback = "inline", page = 1 }, function() end)

    package.loaded["media"] = saved_media
    package.loaded["lib.nvim.image_preview"] = saved_ip
    external.reset()

    assert.is_false(played, '"inline" must skip both the window and the system-player tiers')
    assert.is_nil(content.play_external)
  end)
end)

describe("the float a played run is drawn into", function()
  local DEFAULTS = require("hover.config.DEFAULTS")
  local float = require("hover.float")
  local blocks_ok, blocks = pcall(require, "images.blocks")
  local scale_ok = pcall(require, "images.scale")

  --- `hover.box()` for a played hover, which is private to `hover.init`.
  --- Duplicated here on purpose: this spec exists to catch the two derivations
  --- drifting apart, and it can only do that by holding one of them.
  ---@return integer width, integer height
  local function play_box()
    local w, h = DEFAULTS.max_width, DEFAULTS.max_lines
    local factor = DEFAULTS.video.play_scale
    if factor > 1 then
      w = math.min(math.floor(w * factor), math.max(20, vim.o.columns - 4))
      h = math.min(math.floor(h * factor), math.max(3, vim.o.lines - 4))
    end
    return w, h
  end

  -- **The invariant a wrap breaks, and it breaks silently.** `preview.video`
  -- builds a canvas from the box and `float.open` clamps the window to the
  -- same box. Scale one without the other and every canvas row wraps onto two
  -- screen rows -- the picture comes out as horizontal stripes and the control
  -- row falls off the bottom, with nothing raising an error. That shipped on
  -- 2026-09-08 and was reported with a screenshot of the wrap markers.
  it("is wide enough for every canvas row, and tall enough for all of them", function()
    if not (blocks_ok and scale_ok) then
      return
    end
    local columns, lines_before = vim.o.columns, vim.o.lines
    vim.o.columns, vim.o.lines = 200, 38

    local ok = pcall(function()
      for _, source in ipairs({ { 1280, 720 }, { 720, 1280 }, { 640, 640 } }) do
        local width, height = play_box()
        -- The real function, not a copy of its arithmetic: a spec that holds
        -- its own version of the thing it is checking cannot notice the two
        -- drifting apart, which is exactly the failure being guarded.
        local cols, rows = video.playback_cells(
          { width = source[1], height = source[2] },
          { max_width = width, max_lines = height }
        )
        local canvas = blocks.canvas_lines(cols, rows)
        canvas[#canvas + 1] = "▮▮♪ 0:00 / 9:05  ▯▯▯"

        local widest = 0
        for _, line in ipairs(canvas) do
          widest = math.max(widest, vim.fn.strdisplaywidth(line))
        end

        local w, h = float.size_for(canvas, { max_width = width, max_height = height })
        assert.is_true(
          w >= widest,
          ("float %d wide for a %d-wide canvas: every row would wrap"):format(w, widest)
        )
        assert.is_true(
          h >= #canvas,
          ("float %d tall for %d rows: the control row falls off"):format(h, #canvas)
        )
      end
    end)

    vim.o.columns, vim.o.lines = columns, lines_before
    assert.is_true(ok)
  end)

  it("keeps the enlarged box inside the screen it is drawn on", function()
    local columns, lines_before = vim.o.columns, vim.o.lines
    -- A terminal far smaller than the scaled budget asks for.
    vim.o.columns, vim.o.lines = 60, 14
    local width, height = play_box()
    vim.o.columns, vim.o.lines = columns, lines_before

    assert.is_true(width <= 56, "a generous factor on a small terminal is the terminal")
    assert.is_true(height <= 10)
  end)
end)
