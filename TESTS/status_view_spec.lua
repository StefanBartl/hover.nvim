---@diagnostic disable: need-check-nil
-- The test body is the guard; see the note in TESTS/bare_path_spec.lua
-- (`LLS-42`).

-- TESTS/status_view_spec.lua -- the `:Hover status` board.
--
-- **What this file is here to pin is one bug report.** Someone read
-- `link targets on` / `web links off`, typed `:Hover links on` at it, and
-- found `web links` still off. Nothing was broken: `web` is its own switch,
-- filed under `links` in the command tree, and `:Hover links web on` is the
-- command. The label and the route were different strings and only one of
-- them was on screen.
--
-- So the claims worth holding are not about pixels:
--
--   1. **Every actionable row carries the command that acts on it**, spelled
--      the way the command line spells it -- and that spelling comes from
--      `switches.route`, the same function the command tree is built from.
--      A board that derived it a second time would be the `route_path` bug
--      again, one file over.
--   2. **The three states are distinguishable.** `enabled` folds in the
--      implication chain, so `web` set while `links` is off reads as a plain
--      `off` -- and then turning `links` on appears to switch on something
--      nobody asked for. The board draws that as `◐`.
--   3. **Acting on a row goes through the public setter**, so the
--      implication chain, the cache drop and the announcement happen exactly
--      once and in one place. Checked by consequence: toggling `fetch` from
--      the board must turn `web` and `links` on too.
--   4. **`<Tab>` never lands on a line nothing acts on.** The board has
--      headings and blank lines, and a cursor parked on one makes the next
--      `<CR>` a no-op that reads as a broken key.
--
-- The `?` panel and the `winbar` legend are generated from the same table the
-- keys are bound from, so "the legend lists a key that is not bound" is not a
-- state this can reach -- see `ACTIONS` in `hover.status_view`.

local config = require("hover.config")
local switches = require("hover.switches")
local view = require("hover.status_view")

--- The board's buffer lines, with the board left open for the caller.
---@return integer bufnr, string[] lines
local function open()
  assert.is_true(view.open(), "the board did not open -- lib.nvim's UI kit is missing")
  local bufnr = vim.api.nvim_get_current_buf()
  return bufnr, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

--- Close whatever float is current, if any.
---@return nil
local function close()
  pcall(vim.api.nvim_win_close, 0, true)
end

--- Put the cursor on the first line containing `needle`.
---@param bufnr integer
---@param needle string
---@return integer line
local function goto_row(bufnr, needle)
  for i, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    if line:find(needle, 1, true) then
      vim.api.nvim_win_set_cursor(0, { i, 0 })
      return i
    end
  end
  error("no row matching " .. needle)
end

--- Press `keys` in the board's window, synchronously.
---@param keys string
---@return nil
local function press(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

--- Whether a line is an actionable row: glyph, space, label.
---
--- By prefix rather than by pattern, and that is not style. A Lua character
--- class is a class of **bytes**, and each of these glyphs is three of them,
--- so `[●○◐]` matches one third of a glyph and the pattern never fires. It
--- passed as a `%S` for exactly as long as it took to run.
---@param text string
---@return boolean
local function is_row(text)
  for _, glyph in ipairs({ "●", "○", "◐" }) do
    if vim.startswith(text, " " .. glyph .. " ") then
      return true
    end
  end
  return false
end

--- How far a row's label is indented, in spaces -- the same byte trap as
--- `is_row`, so the glyph is removed by prefix rather than matched over.
---@param text string
---@return integer
local function indent_of(text)
  for _, glyph in ipairs({ "●", "○", "◐" }) do
    local prefix = " " .. glyph .. " "
    if vim.startswith(text, prefix) then
      return #(text:sub(#prefix + 1):match("^ *"))
    end
  end
  error("not a row: " .. text)
end

--- The line holding `needle`, re-read after a redraw.
---@param bufnr integer
---@param needle string
---@return string
local function row_text(bufnr, needle)
  for _, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    if line:find(needle, 1, true) then
      return line
    end
  end
  error("no row matching " .. needle)
end

describe("the :Hover status board", function()
  before_each(function()
    config.reset()
    vim.g.hover_disable = nil
  end)

  after_each(function()
    close()
    config.reset()
    vim.g.hover_disable = nil
  end)

  it(
    "gives every switch the command that acts on it, spelled as the command tree spells it",
    function()
      local bufnr, lines = open()
      local text = table.concat(lines, "\n")

      for _, name in ipairs(switches.names()) do
        local spec = switches.spec(name)
        local route = ":Hover " .. table.concat(switches.route(name), " ")
        assert.is_truthy(
          text:find(spec.label, 1, true),
          ("the board does not name the switch %q"):format(name)
        )
        assert.is_truthy(
          row_text(bufnr, spec.label):find(route, 1, true),
          ("the %q row does not carry %q"):format(name, route)
        )
      end
    end
  )

  it("indents a switch by its depth in the implication chain", function()
    local bufnr = open()
    -- `web` sits under `links`, `fetch` under `web`: the picture and the
    -- words to type are the same fact, so the indent is read from the route.
    local links = indent_of(row_text(bufnr, "link targets"))
    local web = indent_of(row_text(bufnr, "web links"))
    local fetch = indent_of(row_text(bufnr, "link fetching"))
    assert.is_true(links < web, "web links is not indented under link targets")
    assert.is_true(web < fetch, "link fetching is not indented under web links")
  end)

  it("draws a switch that is set while its parent is off as neither on nor off", function()
    -- The state a flat on/off list cannot express, and the one that made the
    -- board worth building: `web` is still set, and turning `links` back on
    -- brings it back rather than leaving it demoted.
    switches.set("web", true, { silent = true })
    switches.set("links", false, { silent = true })

    local bufnr = open()
    local web = row_text(bufnr, "web links")
    assert.is_truthy(web:find("◐", 1, true), "a held switch is drawn as a plain off: " .. web)
    assert.is_falsy(row_text(bufnr, "link targets"):find("◐", 1, true))
  end)

  it("toggles the row under the cursor through the switch setter, chain and all", function()
    local bufnr = open()
    goto_row(bufnr, ":Hover links web fetch")
    press("<CR>")

    -- Not just "fetch is on": the point of going through `switches.set` is
    -- that the two above it came with it.
    assert.is_true(switches.enabled("fetch"))
    assert.is_true(switches.enabled("web"))
    assert.is_true(switches.enabled("links"))
    assert.is_truthy(row_text(bufnr, "web links"):find("●", 1, true))
  end)

  it("takes an explicit state, and does nothing when the row is already in it", function()
    local bufnr = open()
    goto_row(bufnr, ":Hover office")
    press("+")
    assert.is_true(switches.enabled("office"))
    press("+")
    assert.is_true(switches.enabled("office"), "a second `+` turned the row back off")
    press("-")
    assert.is_false(switches.enabled("office"))
  end)

  it("cycles the mode on its own row, and takes the two ends explicitly", function()
    local hover = require("hover")
    local bufnr = open()

    goto_row(bufnr, ":Hover mode")
    press("<CR>")
    assert.equals("manual", hover.mode())
    goto_row(bufnr, ":Hover mode")
    press("<CR>")
    assert.equals("off", hover.mode())

    goto_row(bufnr, ":Hover mode")
    press("+")
    assert.equals("auto", hover.mode())
    goto_row(bufnr, ":Hover mode")
    press("-")
    assert.equals("off", hover.mode())
  end)

  it("toggles what opens by itself, on the same board", function()
    local bufnr = open()
    local before = config.auto_hover_for("file")
    goto_row(bufnr, ":Hover auto file")
    press("<CR>")
    assert.equals(not before, config.auto_hover_for("file"))
  end)

  it("yanks the command a row carries", function()
    local bufnr = open()
    goto_row(bufnr, ":Hover links web")
    press("y")
    assert.equals(":Hover links web", vim.fn.getreg('"'))
  end)

  it("never lets <Tab> rest on a heading or a blank line", function()
    local bufnr = open()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    local total = vim.api.nvim_buf_line_count(bufnr)
    for _ = 1, total + 2 do
      press("<Tab>")
      local line = vim.api.nvim_win_get_cursor(0)[1]
      local text = vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1] or ""
      assert.is_true(
        is_row(text),
        ("<Tab> landed on line %d, which nothing acts on: %q"):format(line, text)
      )
    end
  end)

  it("opens on an actionable row rather than on the leading blank", function()
    local bufnr = open()
    local line = vim.api.nvim_win_get_cursor(0)[1]
    local text = vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1] or ""
    assert.is_true(is_row(text), "the board opened on " .. vim.inspect(text))
  end)

  it("keeps a winbar legend that names only keys it binds", function()
    open()
    local legend = view.legend()
    assert.is_truthy(legend:find("? ", 1, true), "the legend drops the key that reaches the rest")
    -- `%#Group#` items, which is what makes the keys highlightable at all.
    assert.is_truthy(legend:find("%#HoverStatusKey#", 1, true))
  end)
end)
