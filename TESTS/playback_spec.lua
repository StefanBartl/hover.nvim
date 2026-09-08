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
--   3. **Stepping clamps rather than wraps.** A run is a window into a file;
--      wrapping from its end to its start reads as the video looping when it
--      is not.
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
    -- Two pixel rows per text row: the half block is what doubles the
    -- vertical resolution, and a payload built for one row per cell is half
    -- a frame short -- which `paint` correctly refuses.
    parts[#parts + 1] = shade:rep(cols * rows * blocks.ROWS_PER_CELL)
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

  it("clamps stepping instead of wrapping", function()
    if not blocks_ok then
      return
    end
    local buf, raw = fixture(40, 4, 5)
    load_into(buf, raw, 5, 40, 4)

    playback.step(-5) -- already at frame 1
    local at_start = vim.api.nvim_buf_get_lines(buf, 4, 5, false)[1]
    assert.is_truthy(at_start:match("0[:.]0"))
    assert.is_truthy(at_start:find("▯", 1, true)) -- the bar is not full

    playback.step(99) -- past the end
    local at_end = vim.api.nvim_buf_get_lines(buf, 4, 5, false)[1]
    -- Frame 5 of a 12 fps run is a third of a second in, and the bar is full.
    assert.is_falsy(at_end:find("▯", 1, true))
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
