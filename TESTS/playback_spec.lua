---@diagnostic disable: need-check-nil
-- The test body is the guard; see the note in TESTS/bare_path_spec.lua
-- (`LLS-42`).

-- TESTS/playback_spec.lua -- the transport for a video hover.
--
-- **The decode is not here** -- that needs ffmpeg and a video file, and
-- media.nvim's suite holds the argv that produces the run. What a run can
-- check is the state machine, and every case below is one where the wrong
-- behaviour is invisible rather than loud:
--
--   1. **Nothing plays until asked.** A hover appears because a cursor rested
--      somewhere. If loading a run started it, every glance at a video path
--      would set a timer going.
--   2. **A stopped playback frees its timer.** One that outlives its float
--      paints into an invisible buffer at 12 fps, forever, and nothing on
--      screen says so.
--   3. **Stepping is a position in the file, not an index into the window.**
--      A window is two seconds; while a step was clamped to it, the transport
--      keys could not leave one -- stepping back stopped at the window's start
--      and play resumed from there, which right after play began *was* the
--      opening offset. Reported 2026-09-08 as "it jumps back to 0:54". With a
--      decoder, a step past an edge fetches the window that contains the
--      target; without one, the window is all that exists and the edge is the
--      edge. Neither wraps: running off the end back to the beginning reads as
--      the video looping when it is not.
--   3b. **The bar measures the film, not the window.** It used to fill up and
--      reset every two seconds, which reads as reloading rather than as a
--      position -- and contradicts the clock beside it.
--   4. **Painting never rewrites the picture rows.** The canvas text is
--      written once and only highlights change after that -- the property the
--      whole approach rests on, since re-rendering the float at 12 fps is a
--      strobe.
--   5. **Sound is additive, never a precondition.** A run with no `path`
--      never even looks for `media.core.audio` -- the fallback path is
--      unchanged from before sound existed. A run *with* one starts it on
--      play, pauses it in place rather than killing it, seeks it on a step,
--      and stops it on teardown -- and a reply that arrives after the run it
--      was asked for is gone gets its mpv stopped rather than kept.

local blocks_ok, blocks = pcall(require, "images.blocks")

--- A canvas buffer plus a payload of `n` flat frames, alternating colours so
--- a repaint is observable.
---@param cols integer
---@param rows integer
---@param n integer
---@return integer buf, string raw
local function fixture(cols, rows, n)
  local buf = vim.api.nvim_create_buf(false, true)
  local lines = blocks.canvas_lines(cols, rows)
  lines[#lines + 1] = ""
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  local parts = {}
  for i = 1, n do
    local shade = string.char(math.min(255, i * 10), 0, 255 - math.min(255, i * 10))
    -- `frame_bytes`, never a sub-pixel count of this spec's own: a cell holds
    -- two sub-pixels with half blocks and six with sextants, and a payload
    -- built for the wrong one is short -- which `paint` correctly refuses.
    parts[#parts + 1] = shade:rep(blocks.frame_bytes(cols, rows) / 3)
  end
  return buf, table.concat(parts)
end

---@param buf integer
---@param raw string
---@param frames integer
---@param cols integer
---@param rows integer
local function load_into(buf, raw, frames, cols, rows)
  return require("hover.preview.playback").load({
    buf = buf,
    raw = raw,
    frames = frames,
    cols = cols,
    rows = rows,
    fps = 12,
    from = 0,
    duration = 12,
    status_row = rows,
  })
end

describe("the video transport", function()
  local playback = require("hover.preview.playback")

  after_each(function()
    playback.stop()
  end)

  it("loads paused -- a glance at a path is not a request for motion", function()
    if not blocks_ok then
      return
    end
    local buf, raw = fixture(8, 4, 5)
    assert.is_true(load_into(buf, raw, 5, 8, 4))
    assert.is_true(playback.is_active())
    assert.is_false(playback.is_playing())
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("writes a control row that says where in the source it is", function()
    if not blocks_ok then
      return
    end
    local buf, raw = fixture(40, 4, 5)
    load_into(buf, raw, 5, 40, 4)
    local control = vim.api.nvim_buf_get_lines(buf, 4, 5, false)[1]
    -- Paused marker, the source clock, and a progress bar.
    assert.is_truthy(control:find("▮▮", 1, true))
    assert.is_truthy(control:find("▯", 1, true))
    -- The clock reads "0:00" through media.ui and "0.0s" without it -- both
    -- start at zero, and media.nvim being absent is the ordinary case here.
    assert.is_truthy(control:match("0[:.]0"))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("paints the picture rows without rewriting them", function()
    if not blocks_ok then
      return
    end
    local cols, rows = 8, 4
    local buf, raw = fixture(cols, rows, 5)
    load_into(buf, raw, 5, cols, rows)
    local picture_before = vim.api.nvim_buf_get_lines(buf, 0, rows, false)

    playback.step(2)
    local picture_after = vim.api.nvim_buf_get_lines(buf, 0, rows, false)
    assert.are.same(picture_before, picture_after)

    -- ... while the highlights that make it a picture did change.
    local ns = vim.api.nvim_create_namespace("hover.playback")
    assert.is_true(#vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}) > 0)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("clamps a step to the window when nothing can decode another", function()
    if not blocks_ok then
      return
    end
    local buf, raw = fixture(40, 4, 5)
    -- `load_into` hands over no `request`, which is the "no resolvable offset"
    -- case: the window on screen is the whole of what exists.
    load_into(buf, raw, 5, 40, 4)

    playback.step(-5) -- already at frame 1
    assert.are.equal(0, playback.position())

    playback.step(99) -- past the end of the window
    -- Frame 5 of a 12 fps run is a third of a second in, and it stays there
    -- rather than wrapping back to the start.
    assert.is_true(math.abs(playback.position() - 4 / 12) < 1e-6)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("steps out of the window, fetching the one that holds the target", function()
    if not blocks_ok then
      return
    end
    local cols, rows, frames = 40, 4, 24
    local buf, raw = fixture(cols, rows, frames)
    local asked = {}
    playback.load({
      buf = buf,
      raw = raw,
      frames = frames,
      cols = cols,
      rows = rows,
      fps = 12,
      from = 100,
      duration = 544.75,
      status_row = rows,
      request = function(from, cb)
        asked[#asked + 1] = from
        cb({ raw = raw, frames = frames })
      end,
    })

    -- Thirty frames back is two and a half seconds -- half a second past the
    -- start of a two-second window. Clamped, this stopped at 100 and play
    -- resumed there, which is the reported "it jumps back to the start".
    for _ = 1, 30 do
      playback.step(-1)
    end
    assert.is_true(#asked > 0, "a step past the edge has to ask for a window")
    assert.is_true(math.abs(playback.position() - (100 - 30 / 12)) < 1e-6)
    -- And the window fetched is the one holding it, not the next one along.
    assert.is_true(math.abs(asked[#asked] - (100 - 30 / 12)) < 1e-6)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("coalesces a held step key into one decode at a time", function()
    if not blocks_ok then
      return
    end
    local cols, rows, frames = 40, 4, 24
    local buf, raw = fixture(cols, rows, frames)
    local pending, asked = {}, 0
    playback.load({
      buf = buf,
      raw = raw,
      frames = frames,
      cols = cols,
      rows = rows,
      fps = 12,
      from = 100,
      duration = 544.75,
      status_row = rows,
      -- Deferred, the way a real decode is: nothing answers until the test
      -- lets it, so every step below lands while one is in flight.
      request = function(from, cb)
        asked = asked + 1
        pending[#pending + 1] = function()
          cb({ raw = raw, frames = frames })
        end
      end,
    })

    for _ = 1, 60 do
      playback.step(-1)
    end
    -- A window is 24 frames, so the first 24 steps stay inside it and the rest
    -- would each have started an ffmpeg of their own.
    assert.are.equal(1, asked, "a held key must not start a decode per press")
    for _, answer in ipairs(pending) do
      answer()
    end
    -- The stale answer re-issues once for where the key actually ended up.
    assert.is_true(asked <= 2, "at most one re-issue for the final position")
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("measures the bar against the film, not against the window", function()
    if not blocks_ok then
      return
    end
    local cols, rows, frames = 60, 4, 5
    local buf, raw = fixture(cols, rows, frames)
    playback.load({
      buf = buf,
      raw = raw,
      frames = frames,
      cols = cols,
      rows = rows,
      fps = 12,
      from = 50,
      duration = 100,
      status_row = rows,
    })

    ---@return integer filled, integer total
    local function bar()
      local row = vim.api.nvim_buf_get_lines(buf, rows, rows + 1, false)[1] or ""
      -- Only the bar: the pause glyph is the same character.
      local segment = row:match("([▮▯]+)$") or ""
      local filled = select(2, segment:gsub("▮", ""))
      local empty = select(2, segment:gsub("▯", ""))
      return filled, filled + empty
    end

    local filled, total = bar()
    assert.is_true(total > 0)
    -- Halfway through a 100-second file, and the window has nothing to do
    -- with it: the last frame of this run is 0.33 s along, which as a window
    -- index would have filled the bar completely.
    assert.is_true(math.abs(filled / total - 0.5) < 0.05, "the bar reads 50% of the film")

    playback.step(99)
    local at_end = select(1, bar())
    assert.is_true(
      math.abs(at_end / total - 0.5) < 0.05,
      "the end of a window is not the end of the film"
    )
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("paints from a local clock, not once per mpv round trip", function()
    if not blocks_ok then
      return
    end
    -- **The frame rate must not hang off the IPC latency.** The transport
    -- used to ask mpv for `time-pos` once per painted frame and skip the tick
    -- while an answer was outstanding, which made the round trip a hard
    -- ceiling: measured against a stub, 0 ms gave 11.3 fps, 150 ms gave 5.7
    -- and 300 ms gave 3.0. A real round trip averages 9.5 ms here but was
    -- measured at 377, and every two seconds playback runs an ffmpeg and an
    -- ImageMagick for the next window -- so the spikes are not rare, and a
    -- reader reported 1-2 frames per second.
    --
    -- Asserted as a *ratio* rather than as a frame rate, because a frame rate
    -- in a spec measures the machine it runs on. What matters is that asking
    -- and painting have come apart.
    local cols, rows, frames = 20, 4, 24
    local buf, raw = fixture(cols, rows, frames)
    local asks = 0
    local saved = package.loaded["media.core.audio"]
    package.loaded["media.core.audio"] = {
      available = function()
        return true
      end,
      start = function(_, _, cb)
        local began = vim.uv.hrtime()
        cb({
          pause = function() end,
          resume = function() end,
          seek = function() end,
          stop = function() end,
          time_pos = function(callback)
            asks = asks + 1
            -- Answered late, the way a loaded machine answers.
            vim.defer_fn(function()
              callback((vim.uv.hrtime() - began) / 1e9)
            end, 120)
          end,
        })
      end,
    }

    local painted = 0
    local real_paint = blocks.paint
    blocks.paint = function(...)
      painted = painted + 1
      return real_paint(...)
    end

    playback.load({
      buf = buf,
      raw = raw,
      frames = frames,
      cols = cols,
      rows = rows,
      fps = 12,
      from = 0,
      duration = 600,
      status_row = rows,
      path = "/does/not/exist.mp4",
      request = function(_, cb)
        cb({ raw = raw, frames = frames })
      end,
    })
    painted = 0
    playback.play()
    vim.wait(1000, function()
      return false
    end, 20)
    playback.pause()

    blocks.paint = real_paint
    package.loaded["media.core.audio"] = saved

    assert.is_true(painted > 6, ("only %d frames in a second"):format(painted))
    assert.is_true(
      asks < painted,
      ("%d asks for %d frames: the clock is still one round trip per frame"):format(asks, painted)
    )
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("stops cleanly, and stopping twice is not an error", function()
    if not blocks_ok then
      return
    end
    local buf, raw = fixture(8, 4, 5)
    load_into(buf, raw, 5, 8, 4)
    playback.play()
    assert.is_true(playback.is_playing())

    playback.stop()
    assert.is_false(playback.is_active())
    assert.is_false(playback.is_playing())
    playback.stop()
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("gives up when the buffer it was painting into is gone", function()
    if not blocks_ok then
      return
    end
    local buf, raw = fixture(8, 4, 5)
    load_into(buf, raw, 5, 8, 4)
    vim.api.nvim_buf_delete(buf, { force = true })

    -- The float closing is what normally calls `stop`; this is the case where
    -- something else took the buffer first.
    playback.step(1)
    assert.is_false(playback.is_active())
  end)

  it("starts, pauses, seeks and stops audio when the run has a path", function()
    if not blocks_ok then
      return
    end
    local buf, raw = fixture(40, 4, 5)
    local calls = { pause = 0, resume = 0, seek = {}, stop = 0, started_at = nil }
    local saved = package.loaded["media.core.audio"]
    package.loaded["media.core.audio"] = {
      available = function()
        return true
      end,
      start = function(_, opts, callback)
        calls.started_at = opts.at
        callback({
          pause = function()
            calls.pause = calls.pause + 1
          end,
          resume = function()
            calls.resume = calls.resume + 1
          end,
          seek = function(s)
            calls.seek[#calls.seek + 1] = s
          end,
          time_pos = function(cb)
            cb(nil) -- the fake never answers a position; the fallback still has to work
          end,
          stop = function()
            calls.stop = calls.stop + 1
          end,
        }, nil)
      end,
    }

    require("hover.preview.playback").load({
      buf = buf,
      raw = raw,
      frames = 5,
      cols = 40,
      rows = 4,
      fps = 12,
      from = 0,
      duration = 12,
      status_row = 4,
      path = "/tmp/clip.mp4",
    })
    playback.play()
    assert.equals(0, calls.started_at)

    -- `pause` is also the next point the control row is guaranteed to have
    -- repainted (the timer's own repaint is on the next event-loop tick,
    -- which a synchronous test does not wait for) -- and the note marker
    -- joins the paused/playing glyph there, the one thing on screen that
    -- says sound is in play at all.
    playback.pause()
    assert.equals(1, calls.pause)
    local control = vim.api.nvim_buf_get_lines(buf, 4, 5, false)[1]
    assert.is_truthy(control:find("♪", 1, true))

    playback.step(1)
    assert.equals(1, #calls.seek)

    playback.play() -- audio already started once; this resumes it in place
    assert.equals(1, calls.resume)
    assert.equals(0, calls.started_at) -- still the one start, not a second

    playback.stop()
    assert.equals(1, calls.stop)

    package.loaded["media.core.audio"] = saved
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it(
    "stops a late-arriving audio handle rather than keeping it, once the run it answers for is gone",
    function()
      if not blocks_ok then
        return
      end
      local buf, raw = fixture(8, 4, 5)
      local resolve
      local stopped = 0
      local saved = package.loaded["media.core.audio"]
      package.loaded["media.core.audio"] = {
        available = function()
          return true
        end,
        start = function(_, _, callback)
          -- Deferred on purpose: this is the race `state.gen` exists for --
          -- mpv's socket answering after the reader has already moved on.
          resolve = function()
            callback({
              pause = function() end,
              resume = function() end,
              seek = function() end,
              time_pos = function(cb)
                cb(nil)
              end,
              stop = function()
                stopped = stopped + 1
              end,
            }, nil)
          end
        end,
      }

      require("hover.preview.playback").load({
        buf = buf,
        raw = raw,
        frames = 5,
        cols = 8,
        rows = 4,
        fps = 12,
        from = 0,
        duration = 12,
        status_row = 4,
        path = "/tmp/clip.mp4",
      })
      playback.play()
      playback.stop() -- gone before mpv's socket ever answered

      resolve()
      assert.equals(1, stopped)

      package.loaded["media.core.audio"] = saved
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  )

  it("stops a still-attached mpv on VimLeavePre, not only on a deliberate close", function()
    -- A float torn down as part of `:qa` does not run `on_close` the way a
    -- reader dismissing it does -- an mpv started right before quitting
    -- would otherwise outlive Neovim entirely and keep playing on its own.
    if not blocks_ok then
      return
    end
    local buf, raw = fixture(8, 4, 5)
    local stopped = 0
    local saved = package.loaded["media.core.audio"]
    package.loaded["media.core.audio"] = {
      available = function()
        return true
      end,
      start = function(_, _, callback)
        callback({
          pause = function() end,
          resume = function() end,
          seek = function() end,
          time_pos = function(cb)
            cb(nil)
          end,
          stop = function()
            stopped = stopped + 1
          end,
        }, nil)
      end,
    }

    require("hover.preview.playback").load({
      buf = buf,
      raw = raw,
      frames = 5,
      cols = 8,
      rows = 4,
      fps = 12,
      from = 0,
      duration = 12,
      status_row = 4,
      path = "/tmp/clip.mp4",
    })
    playback.play()
    assert.equals(0, stopped)

    vim.api.nvim_exec_autocmds("VimLeavePre", { modeline = false })
    assert.equals(1, stopped, "the exit sweep must stop the mpv it still holds")

    package.loaded["media.core.audio"] = saved
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)

describe("the transport keys", function()
  it("are declared with the toggle, and step in both directions", function()
    local cfg = require("hover.config")
    cfg.setup({})
    local keys = cfg.get().transport_keys
    assert.is_table(keys)
    -- Not `<Space>`, `]`, `[`: the first is `mapleader` in most
    -- configurations (and re-enters which-key's trigger on the same key), and
    -- the other two are prefixes -- `]d`, `[q` and every other bracket motion
    -- stop existing while a float is up. Both were shipped and both were
    -- wrong; see the note on `transport_keys` in config/DEFAULTS.lua.
    assert.are.same({ "<CR>" }, keys.toggle)
    assert.are.same({ "." }, keys.forward)
    assert.are.same({ "," }, keys.back)
  end)

  it("are borrowed only for content that says it can play", function()
    local keys = require("hover.bindings.keymaps")
    keys.release()

    keys.borrow({ lines = { "plain text" } }, {})
    assert.is_nil(vim.fn.maparg("<CR>", "n", false, true).desc)
    keys.release()

    local calls = 0
    keys.borrow({ lines = { "x" }, transport = true }, {
      transport = function()
        calls = calls + 1
      end,
    })
    local mapped = vim.fn.maparg("<CR>", "n", false, true)
    assert.is_truthy(mapped.desc)
    mapped.callback()
    assert.are.equal(1, calls)

    -- And handed back when the float goes: a transport key that outlives its
    -- hover is a key the reader cannot get rid of.
    keys.release()
    assert.is_nil(vim.fn.maparg("<CR>", "n", false, true).desc)
  end)
end)
