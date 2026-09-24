---@diagnostic disable: need-check-nil
-- The test body is the guard; see the note in TESTS/bare_path_spec.lua
-- (`LLS-42`).

-- TESTS/requested_hover_retrigger_spec.lua -- an explicitly requested hover
-- must survive its own trigger firing again.
--
-- **The bug this pins.** Every target type but `image`/`pdf` is off in
-- `auto_hover` by default -- a plain `file`, `office`, `markdown`, `url`,
-- `git`, and `directory` (see TESTS/dirbrowse_spec.lua's sibling coverage for
-- that one specifically) only open through an explicit `force = true`
-- (`:Hover show`, the `keymaps.show` key). Once open, pressing any key that
-- hover borrows for it -- a scroll, a resize, `nav_keys` -- is still a
-- keystroke, and `CursorHold` re-arms on any keystroke, "cursor movement or
-- not" (`hover.dismiss`'s own header explains why). So the *automatic*
-- trigger fires again with the cursor still reading the exact text that
-- opened the hover, unforced. Before this guard existed, `show()` had no way
-- to tell that apart from "the automatic trigger just found this for the
-- first time" -- it re-read `auto_hover_for(target.type)`, found it `false`,
-- and called `hide()`. Confirmed empirically: force-open a plain `file`
-- hover, then call `show({})` with the cursor untouched -- the float closed.
--
-- **The fix.** `M.show()` now recognises a same-origin, unforced re-trigger
-- of a hover that was either explicitly `requested` or is an active
-- directory browse (`_open.dir_entries` -- a reader who has opted into
-- `:Hover auto directory on` gets an auto-opened one, where `requested` is
-- unset but a re-trigger would still reset the browse to its root instead of
-- closing it) and leaves it alone entirely, before `auto_hover_for` is ever
-- consulted again.

local config = require("hover.config")
local registry = require("hover.registry")
local float = require("hover.float")
local hover = require("hover")

describe("hover.show, re-triggered on an explicitly requested hover", function()
  local root, win, prev_buf, buf, path

  before_each(function()
    config.reset()
    registry.reset()
    hover.hide()

    root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    path = root .. "/plain.txt"
    local lines = {}
    for i = 1, 30 do
      lines[i] = "line " .. i
    end
    vim.fn.writefile(lines, path)

    win = vim.api.nvim_get_current_win()
    prev_buf = vim.api.nvim_win_get_buf(win)

    buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, root .. "/notes.md")
    vim.api.nvim_win_set_buf(win, buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { path })
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
  end)

  after_each(function()
    hover.hide()
    pcall(vim.api.nvim_win_set_buf, win, prev_buf)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    vim.fn.delete(root, "rf")
    config.reset()
    registry.reset()
  end)

  ---@return string[]|nil
  local function shown_lines()
    local w = float.win()
    if not w then
      return nil
    end
    return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false)
  end

  it(
    "stays open across an unforced re-trigger, when `file` is off in auto_hover (the default)",
    function()
      assert.is_false(
        config.auto_hover_for("file"),
        "this test assumes the default: file is not auto-opened"
      )

      assert.is_true(hover.show({ force = true }))
      assert.is_truthy(float.win(), "the forced open did not show a float")

      -- The re-trigger `CursorHold` performs after any borrowed key is
      -- pressed, cursor untouched: same target, no force.
      assert.is_true(hover.show({}))
      assert.is_truthy(
        float.win(),
        "an unforced re-trigger closed a hover nothing asked it to close"
      )
    end
  )

  it("still closes on an unforced trigger once the cursor leaves the target", function()
    -- The guard is keyed on `identity(target)` matching `_open.origin`, not
    -- on "a requested hover is untouchable" -- moving to a place with
    -- nothing to show must still dismiss it, or the guard would pin a
    -- forced-open hover on screen forever.
    assert.is_true(hover.show({ force = true }))
    assert.is_truthy(float.win())

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "nothing pathlike on this line" })
    assert.is_false(hover.show({}))
    assert.is_falsy(float.win(), "the hover survived moving off its target")
  end)

  it("still resets to a fresh render when the re-trigger is itself forced", function()
    -- `force = true` is a reader asking again on purpose -- "look from
    -- scratch" -- and the guard must not swallow that. Scrolled state is the
    -- observable proxy: if the guard wrongly caught a forced call, `_open`
    -- would never be rebuilt and the scroll offset would survive; a real
    -- fresh open always starts back at line 1.
    assert.is_true(hover.show({ force = true }))
    assert.is_true(hover.scroll(1))
    local scrolled = shown_lines()
    assert.is_truthy(scrolled)
    assert.is_falsy(
      scrolled[1]:find("^line 1$"),
      "the scroll in this test did not move the view at all"
    )

    assert.is_true(hover.show({ force = true }))
    local reset = shown_lines()
    assert.equals("line 1", reset[1], "a forced re-trigger did not rebuild from the top")
  end)
end)
