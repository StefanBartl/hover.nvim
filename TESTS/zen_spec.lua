---@diagnostic disable: need-check-nil
-- The test body is the guard; see the note in TESTS/bare_path_spec.lua
-- (`LLS-42`).

-- TESTS/zen_spec.lua -- the float on the whole editor, and the four things
-- about it that a plausible implementation gets wrong.
--
--   1. **Zen is not a bigger window.** Every previewer renders against a
--      budget -- `max_lines` and `max_width` decide how many lines are read,
--      at what DPI a page is rasterized, how large a picture is drawn -- so a
--      float that merely opened larger would show the same twenty lines with
--      a great deal of margin. What is pinned here is that the *content*
--      grows: a 200-line file in a float taller than `max_lines` can only
--      have come from a previewer that was given a bigger box.
--
--   2. **The resize level still multiplies on top of it, and needs no code.**
--      The base becomes `columns - 4` / `lines - 4`, which is exactly the
--      ceiling `float.size_for` clamps against -- so `+` in zen produces an
--      identical float, `resize` sees that and steps its own level back off,
--      and `-` shrinks from full screen without leaving zen. Both directions
--      are checked, because "zen ends at the first `-`" was the alternative
--      reading and nothing in the code would have said which one shipped.
--
--   3. **Pinning is coupled, not fused.** The float is `focusable = false`
--      and its dismissal hangs on `CursorMoved`, so an unpinned full-screen
--      hover closes on the first `j` -- hence `zen.pin`, on by default. The
--      half that is easy to get wrong is the way back: leaving zen must
--      release only a pin *zen itself* took, and never one the reader set.
--
--   4. **The pin marker lives on the window, and every re-render replaces the
--      window.** `float.open` closes and reopens, so `📌` had been silently
--      lost on every resize and every scroll since pinning existed. It was
--      survivable while pinning was a rare deliberate gesture; zen pins by
--      default, which makes it the ordinary case.
--
-- The screen is set to 210x55 before anything asks for room on it: a plenary
-- run is 80x24, where `lines - 4` already equals the default `max_lines` and
-- zen would have nothing to prove.

local config = require("hover.config")
local keys = require("hover.bindings.keymaps")
local float = require("hover.float")
local registry = require("hover.registry")
local hover = require("hover")

--- Whether `lhs` currently has a normal-mode mapping.
---@param lhs string
---@return boolean
local function mapped(lhs)
  local m = vim.fn.maparg(lhs, "n", false, true)
  return type(m) == "table" and m.lhs ~= nil
end

describe("hover.zen", function()
  local root, win, prev_buf, prev_isfname, prev_cols, prev_lines, buf

  before_each(function()
    config.reset()
    registry.reset()
    keys.release()
    vim.g.hover_disable = nil

    root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    local long = {}
    for i = 1, 200 do
      long[i] = ("line %d"):format(i)
    end
    vim.fn.writefile(long, root .. "/many.txt")

    prev_cols, prev_lines = vim.o.columns, vim.o.lines
    vim.o.columns, vim.o.lines = 210, 55

    win = vim.api.nvim_get_current_win()
    prev_buf = vim.api.nvim_win_get_buf(win)
    prev_isfname = vim.o.isfname
    vim.o.isfname = "@,48-57,/,.,-,_,+,,,#,$,%,~,=,:"

    buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, root .. "/notes.md")
    vim.api.nvim_win_set_buf(win, buf)
  end)

  after_each(function()
    hover.hide()
    keys.release()
    pcall(vim.api.nvim_win_set_buf, win, prev_buf)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    vim.o.isfname = prev_isfname
    vim.o.columns, vim.o.lines = prev_cols, prev_lines
    vim.fn.delete(root, "rf")
    config.reset()
    registry.reset()
    vim.g.hover_disable = nil
  end)

  ---@param line string
  ---@param col integer
  ---@return boolean
  local function show_at(line, col)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line })
    vim.api.nvim_win_set_cursor(win, { 1, col })
    return hover.show({ force = true })
  end

  ---@return integer width
  ---@return integer height
  local function geometry()
    local w = float.win()
    assert(w, "no float is open")
    local cfg = vim.api.nvim_win_get_config(w)
    return cfg.width, cfg.height
  end

  --- The border title as one string. `nvim_open_win` stores it as the chunk
  --- list it was given, not as the string.
  ---@return string
  local function title()
    local w = float.win()
    assert(w, "no float is open")
    local cfg = vim.api.nvim_win_get_config(w)
    if type(cfg.title) == "table" then
      local parts = {}
      for _, chunk in ipairs(cfg.title) do
        parts[#parts + 1] = type(chunk) == "table" and tostring(chunk[1] or "") or tostring(chunk)
      end
      return table.concat(parts)
    end
    return type(cfg.title) == "string" and cfg.title or ""
  end

  -- (1) The budget, not the window. A text preview is capped by `max_lines`,
  -- so a float taller than that can only have come from a previewer that was
  -- handed a bigger box -- which is exactly what a "make the window larger"
  -- implementation would fail.
  it("gives the previewer the screen, not the float a wider margin", function()
    assert.is_true(show_at("see ./many.txt here", 5))
    local _, h0 = geometry()
    assert.is_true(h0 <= 20, ("the default box already gave %d rows"):format(h0))

    assert.is_true(hover.zen())
    local _, h1 = geometry()
    assert.is_true(h1 > h0, ("zen left the float at %d rows, was %d"):format(h1, h0))
    assert.is_true(h1 > 20, "the float grew but the previewer was still capped at max_lines")
    assert.is_true(hover.zenned())
  end)

  it("goes back to the configured box, and says so", function()
    assert.is_true(show_at("see ./many.txt here", 5))
    local w0, h0 = geometry()

    assert.is_true(hover.zen(true))
    assert.is_true(hover.zen(false))
    assert.is_false(hover.zenned())
    assert.same({ w0, h0 }, { geometry() })
  end)

  it("toggles when it is asked for nothing", function()
    assert.is_true(show_at("see ./many.txt here", 5))
    assert.is_true(hover.zen())
    assert.is_true(hover.zenned())
    assert.is_true(hover.zen())
    assert.is_false(hover.zenned())
  end)

  it("declines a state it is already in, without saying anything about it", function()
    assert.is_true(show_at("see ./many.txt here", 5))
    assert.is_true(hover.zen(true))
    local asked, why = hover.zen(true)
    assert.is_false(asked)
    assert.is_nil(why, "an explicit `on` twice is not worth a message")
  end)

  -- The one place a hover is deliberately not next to what it describes.
  it("centres the float instead of anchoring it at the cursor", function()
    assert.is_true(show_at("see ./many.txt here", 5))
    -- `assert` rather than the bare call: `float.win()` is `integer|nil`, and
    -- a nil here would reach `nvim_win_get_position` as a window id. The same
    -- guard `geometry()` and `resize_spec` use -- and bound to a local first,
    -- because plenary replaces the global `assert` with luassert, whose return
    -- is multi-valued: inlined into the argument list it expands, and the API
    -- call fails with "Expected 1 argument".
    local win = assert(float.win())
    local before = vim.api.nvim_win_get_position(win)

    assert.is_true(hover.zen(true))
    local w, h = geometry()
    local zen_win = assert(float.win())
    local pos = vim.api.nvim_win_get_position(zen_win)
    assert.same({
      math.max(1, math.floor((vim.o.lines - h) / 2)),
      math.max(1, math.floor((vim.o.columns - w) / 2)),
    }, pos)
    assert.is_true(
      pos[1] ~= before[1] or pos[2] ~= before[2],
      "the float stayed where the cursor put it"
    )
  end)

  -- (2) The interaction with `resize`, in both directions. Neither needed
  -- code of its own; both are worth pinning, because both were a decision.
  it("shrinks from full screen without leaving zen", function()
    assert.is_true(show_at("see ./many.txt here", 5))
    assert.is_true(hover.zen(true))
    local _, h1 = geometry()

    assert.is_true(hover.resize(-1))
    local _, h2 = geometry()
    assert.is_true(h2 < h1, ("one step smaller left %d rows, was %d"):format(h2, h1))
    assert.is_true(hover.zenned(), "a smaller step ended zen")
  end)

  it("is already at the ceiling, so a bigger step is refused and stepped back", function()
    assert.is_true(show_at("see ./many.txt here", 5))
    assert.is_true(hover.zen(true))
    local w1, h1 = geometry()

    hover.resize(1)
    assert.same({ w1, h1 }, { geometry() }, "the screen gave room zen had not already taken")
    -- The level was stepped back off, so one `-` still shrinks rather than
    -- undoing a step that never took effect.
    assert.is_true(hover.resize(-1))
    local _, h2 = geometry()
    assert.is_true(h2 < h1, "the refused step was kept, so `-` only cancelled it")
  end)

  -- (3) Pinning: coupled by default, and released only where zen took it.
  it("pins on the way in and releases that pin on the way out", function()
    assert.is_false(hover.pinned())
    assert.is_true(show_at("see ./many.txt here", 5))

    assert.is_true(hover.zen(true))
    assert.is_true(hover.pinned(), "a full-screen float would close on the first key")

    assert.is_true(hover.zen(false))
    assert.is_false(hover.pinned())
  end)

  it("takes no pin when the reader has turned that off", function()
    config.setup({ zen = { pin = false } })
    assert.is_true(show_at("see ./many.txt here", 5))
    assert.is_true(hover.zen(true))
    assert.is_false(hover.pinned())
    assert.is_true(hover.zenned(), "the pin setting also switched the feature off")
  end)

  it("leaves a pin the reader took themselves alone", function()
    assert.is_true(show_at("see ./many.txt here", 5))
    hover.pin(true)

    assert.is_true(hover.zen(true))
    assert.is_true(hover.zen(false))
    assert.is_true(hover.pinned(), "leaving zen released a pin it never took")
  end)

  it("hands the pin back to the reader when they set it by hand inside zen", function()
    assert.is_true(show_at("see ./many.txt here", 5))
    assert.is_true(hover.zen(true))
    -- Already pinned by zen; pinning again is the reader claiming it.
    hover.pin(true)

    assert.is_true(hover.zen(false))
    assert.is_true(hover.pinned())
  end)

  -- (4) The marker, which lives on the window a re-render replaces.
  it("keeps the pin marker across the re-render it performs", function()
    assert.is_true(show_at("see ./many.txt here", 5))
    assert.is_true(title() ~= "", "this preview has no title to carry a marker")

    assert.is_true(hover.zen(true))
    assert.is_truthy(title():find("📌", 1, true), ("the marker is gone: %q"):format(title()))
  end)

  it("keeps it across a resize as well, which is where it used to be lost", function()
    assert.is_true(show_at("see ./many.txt here", 5))
    hover.pin(true)
    assert.is_truthy(title():find("📌", 1, true))

    assert.is_true(hover.resize(1))
    assert.is_truthy(title():find("📌", 1, true), ("a resize dropped it: %q"):format(title()))
  end)

  -- The borrow: the widest condition in the plugin, and the one case it is
  -- withheld from.
  it("borrows its key for a text hover, where resize deliberately does not", function()
    assert.is_true(show_at("see ./many.txt here", 5))
    assert.is_true(mapped("F"), "the widest borrow here was not taken")
    assert.is_false(mapped("+"), "resize widened its own condition")
  end)

  it("binds nothing when the list is emptied", function()
    config.setup({ zen_keys = { toggle = {} } })
    assert.is_true(show_at("see ./many.txt here", 5))
    assert.is_false(mapped("F"))
  end)

  it("hands the key back when the float closes", function()
    assert.is_true(show_at("see ./many.txt here", 5))
    assert.is_true(mapped("F"))
    hover.hide()
    assert.is_false(mapped("F"))
  end)

  it("declines for a position preview, which has no target to ask again", function()
    registry.register("p", {
      positions = {
        function()
          return { lines = { "something about this place" } }
        end,
      },
    })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "ordinary prose here" })
    vim.api.nvim_win_set_cursor(win, { 1, 2 })
    assert.is_true(hover.show({ force = true }))

    local asked, why = hover.zen()
    assert.is_false(asked)
    assert.is_truthy(why and why:find("position preview", 1, true))
    -- A key bound to a refusal is worse than an unbound one.
    assert.is_false(mapped("F"))
  end)

  it("declines with a reason when there is no float at all", function()
    local asked, why = hover.zen()
    assert.is_false(asked)
    assert.is_truthy(why and why:find("no hover", 1, true))
  end)

  it("is reachable as a command, in both directions", function()
    require("hover.bindings.usrcmds").setup()
    assert.is_true(show_at("see ./many.txt here", 5))

    -- The float survives being typed at: its dismissal hangs on CursorMoved,
    -- InsertEnter, BufLeave and WinScrolled, and entering the command line
    -- fires none of them. The same property `:Hover resize` relies on.
    vim.cmd("Hover zen")
    assert.is_truthy(float.win(), "the command closed the float it acts on")
    assert.is_true(hover.zenned())

    vim.cmd("Hover zen off")
    assert.is_truthy(float.win())
    assert.is_false(hover.zenned())
  end)
end)
