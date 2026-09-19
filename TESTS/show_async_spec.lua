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
-- **The fix, and why it is a generation number and not a flag.** A same-
-- target, non-forced re-trigger simply does not get a new generation --
-- `build()` still runs exactly as before, `cache.get` is still checked fresh
-- every time. A first version of this fix instead set a `pending` flag on
-- `_open` and returned early while it was set, skipping `build()` entirely.
-- That flag had no reliable place to clear: `office.lua`/`webpdf.lua`/
-- `shot.lua` each dedup their own in-flight request on a single boolean, not
-- a waiter list, so a second call made while the first is still running gets
-- back a synchronous placeholder and its `on_result` is simply never
-- invoked -- orphaned, same shape as the original bug, one level down. The
-- same is true for a build that legitimately/terminally answers `nil` (an
-- anchor no plugin claimed, a failed crop). Both left the flag stuck `true`
-- forever, which made *every later* trigger on that target a silent no-op --
-- worse than the original bug, and permanent rather than "until you leave
-- and come back". Found by an adversarial review the same day, 2026-09-19.
-- A generation number has no such stuck state: it either matches the current
-- one or it does not.
--
-- `hover.preview.video` is stubbed out entirely in most of these -- the
-- extraction itself needs ffmpeg and a real video file, and is not what is
-- under test here. What matters is only that a stub answers with
-- `pending = true` and later calls `on_result`, or answers nil/synchronously,
-- the same shapes `office`/`webpdf`/`shot`/`media.zoomed` actually use.

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

  ---@return { calls: integer, first_cb: fun(content: table)|nil }
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

  --- A stub shaped like `office.lua`/`webpdf.lua`/`shot.lua`: a single
  --- in-flight flag, not a waiter list, plus a persistent result cache that
  --- fills in independently of whatever hover.nvim's own generation is doing
  --- (`office.lua`'s `remember()`, called from inside its own callback before
  --- `on_result` is ever reached).
  ---@return { running: boolean, cache: table|nil, calls: integer, real_finish: fun(content: table)|nil }
  local function stub_single_flight()
    local state = { running = false, cache = nil, calls = 0, real_finish = nil }
    package.loaded["hover.preview.video"] = {
      preview = function(_, _, on_result)
        state.calls = state.calls + 1
        if state.running then
          -- Exactly `office.lua:227-229`'s shape: a synchronous placeholder,
          -- and `on_result` is never touched.
          return { lines = { "converting..." }, pending = true }
        end
        if state.cache then
          return state.cache
        end
        state.running = true
        state.real_finish = function(content)
          state.running = false
          state.cache = content
          on_result(content)
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

  it("leaves the first render's callback able to answer", function()
    local state = stub_video()

    assert.is_true(hover.show())
    assert.equals(1, state.calls, "the first trigger starts the one render this needs")
    local first_cb = state.first_cb
    assert.is_truthy(first_cb, "the stub was handed an on_result callback")

    -- The re-trigger `CursorHold` performs while the cursor never left the
    -- link: same target, nothing resolved yet. `build()` runs again -- that
    -- is allowed and expected now, and harmless: a real previewer dedups its
    -- own in-flight work, and this stub does not need to for the property
    -- under test here.
    assert.is_true(hover.show())
    assert.equals(first_cb, state.first_cb, "the original callback is still the live one")

    -- The conversion finishes now, answering through the *first* callback --
    -- the one a re-trigger must not have orphaned by moving the generation.
    first_cb({ lines = { "converted!" } })

    assert.same({ "converted!" }, shown_lines())
  end)

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

  -- The regression an earlier, flag-based version of this fix introduced:
  -- leaving a link whose render has its own single-flight guard (the shape
  -- office.lua/webpdf.lua/shot.lua actually have) and returning to it before
  -- that render finishes must not wedge the hover permanently. The module's
  -- own callback for this second visit is dropped (exactly as the real
  -- modules drop it), so the *first* job's answer is what has to land -- and
  -- if even that specific delivery is lost to a generation change from the
  -- leave, the very next trigger must still recover once the module's own
  -- cache has the answer, with no further leave-and-return needed.
  it("recovers on its own after leave-then-return, once a single-flight module finishes", function()
    local state = stub_single_flight()

    assert.is_true(hover.show())
    assert.is_true(state.running)
    local finish = state.real_finish
    assert.is_truthy(finish, "the first, real caller got a completion callback")

    -- Cursor leaves before the render finishes...
    hover.hide()
    -- ...and returns to the identical link while it is still running.
    assert.is_true(hover.show())
    assert.equals(
      2,
      state.calls,
      "the module is asked again -- its own guard is what must answer safely, not a count of calls"
    )

    -- The original job finishes now. Its own module-level cache fills in
    -- independently of hover.nvim's generation, exactly like
    -- `office.lua`'s `remember()` -- but this particular delivery's own
    -- callback may still be stale from the leave above and get dropped,
    -- same as it always would for a target genuinely abandoned and
    -- returned to.
    finish({ lines = { "converted!" } })
    assert.is_false(state.running)

    -- The reader is still sitting on the same link. The very next trigger
    -- must not be a permanent no-op -- it must ask the module again, find
    -- its cache now filled, and show the real result immediately, with no
    -- further leave-and-return required.
    assert.is_true(hover.show())
    assert.same({ "converted!" }, shown_lines())
  end)

  -- The other regression the same flag introduced: a build that legitimately
  -- and terminally answers with nothing (an anchor no plugin claimed, a
  -- failed crop -- `media.zoomed` returns bare `nil` for exactly this) must
  -- not block the next trigger on that same link from trying again.
  it("a render that terminally answers nothing does not block the next retry", function()
    local attempt = 0
    package.loaded["hover.preview.video"] = {
      preview = function(_, _, on_result)
        attempt = attempt + 1
        if attempt == 1 then
          -- A synchronous decline, the shape `media.zoomed` uses when there
          -- is no rect to crop: `on_result` is never even reached.
          return nil
        end
        return { lines = { "second try worked" } }
      end,
    }

    assert.is_true(hover.show())
    assert.equals(1, attempt)
    assert.is_nil(float.win(), "nothing to show yet -- a decline, not an error")

    assert.is_true(hover.show())
    assert.equals(2, attempt, "a terminal nil must not stop the next trigger from asking again")
    assert.same({ "second try worked" }, shown_lines())
  end)
end)
