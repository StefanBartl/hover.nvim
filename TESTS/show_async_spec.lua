---@diagnostic disable: need-check-nil
-- The test body is the guard; see the note in TESTS/bare_path_spec.lua
-- (`LLS-42`).

-- TESTS/show_async_spec.lua -- a re-trigger for the link already open must
-- not orphan the render it is waiting on.
--
-- **The bug this pins.** `CursorHold` fires again after any keystroke
-- followed by `updatetime` of quiet, cursor movement or not (`M.dismiss`'s
-- own header explains why) -- so a reader who stays on one office/PDF/video
-- link while it converts gets `hover.show()` called more than once before
-- the conversion is done. `show()` used to bump its generation counter on
-- every one of those calls unconditionally, which invalidates the `on_result`
-- callback the still-running convert/render is holding: its answer lands
-- against a generation that has since moved on, and `guarded` drops it
-- silently. The content itself is not lost -- `cache.put` does not check the
-- generation -- so the visible symptom is "it only updates once you leave
-- the link and come back", which is exactly what a fresh `show()` for the
-- same target does: a plain cache hit.
--
-- `hover.preview.video` is stubbed out entirely -- the extraction itself
-- needs ffmpeg and a real video file, and is not what is under test here.
-- What matters is only that it answers with `pending = true` and later calls
-- `on_result`, the same contract `office` and `webpdf` share.

local config = require("hover.config")
local registry = require("hover.registry")
local float = require("hover.float")
local hover = require("hover")

describe("hover.show, re-triggered on the link it already has open", function()
  local root, win, prev_buf, prev_isfname, buf, saved_video

  before_each(function()
    config.reset()
    registry.reset()
    hover.hide()

    root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    vim.fn.writefile({ "" }, root .. "/clip.mp4")

    win = vim.api.nvim_get_current_win()
    prev_buf = vim.api.nvim_win_get_buf(win)
    prev_isfname = vim.o.isfname
    vim.o.isfname = "@,48-57,/,.,-,_,+,,,#,$,%,~,=,:"

    buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, root .. "/notes.md")
    vim.api.nvim_win_set_buf(win, buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "see ./clip.mp4 here" })
    vim.api.nvim_win_set_cursor(win, { 1, 5 })

    config.setup({ auto_hover = { video = true } })

    saved_video = package.loaded["hover.preview.video"]
  end)

  after_each(function()
    hover.hide()
    package.loaded["hover.preview.video"] = saved_video
    pcall(vim.api.nvim_win_set_buf, win, prev_buf)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    vim.o.isfname = prev_isfname
    vim.fn.delete(root, "rf")
    config.reset()
    registry.reset()
  end)

  ---@return { win: table, calls: integer, first_cb: fun(content: table)|nil }
  local function stub_video()
    local state = { calls = 0, first_cb = nil }
    package.loaded["hover.preview.video"] = {
      preview = function(_, _, on_result)
        state.calls = state.calls + 1
        if not state.first_cb then
          state.first_cb = on_result
        end
        return { lines = { "converting..." }, pending = true }
      end,
    }
    return state
  end

  ---@return string[]|nil
  local function shown_lines()
    local w = float.win()
    if not w then
      return nil
    end
    return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false)
  end

  it(
    "leaves the first render's callback able to answer, instead of starting a second one",
    function()
      local state = stub_video()

      assert.is_true(hover.show())
      assert.equals(1, state.calls, "the first trigger starts the one render this needs")
      local first_cb = state.first_cb
      assert.is_truthy(first_cb, "the stub was handed an on_result callback")

      -- The re-trigger `CursorHold` performs while the cursor never left the
      -- link: same target, nothing pending resolved yet.
      assert.is_true(hover.show())
      assert.equals(
        1,
        state.calls,
        "a re-trigger for the same, still-converting target must not start a second render"
      )
      assert.equals(first_cb, state.first_cb, "and the original callback is still the live one")

      -- The conversion finishes now, answering through the *first* callback --
      -- the one a re-trigger must not have orphaned.
      first_cb({ lines = { "converted!" } })

      local lines = shown_lines()
      assert.is_truthy(lines, "the finished render should have opened a float")
      assert.same({ "converted!" }, lines)
    end
  )

  it("still answers a move to a different target normally", function()
    local state = stub_video()

    assert.is_true(hover.show())
    assert.equals(1, state.calls)
    local first_cb = state.first_cb

    -- A real move away and back must still drop a stale answer -- this is the
    -- behaviour the generation counter exists for, and the fix above must not
    -- have removed it.
    hover.hide()
    first_cb({ lines = { "late, and for a line the reader left" } })
    assert.is_nil(float.win(), "a result for an abandoned target must not open anything")
  end)
end)
