---@diagnostic disable: need-check-nil
-- The test body is the guard; see the note in TESTS/bare_path_spec.lua
-- (`LLS-42`).

-- TESTS/bare_git_spec.lua -- the object-id shape test, and the one property
-- that matters more than any of it: this class never rides the automatic
-- trigger.
--
-- Measured on this machine, a git start costs ~41 ms and a miss costs the
-- same as a hit -- there is no cheap way to ask whether a hex string is an
-- object. The bare-path pipeline was reworked in this repository because a
-- miss there cost 13 ms. Three times that, on a trigger that fires after
-- every keystroke followed by quiet, would be a stutter rather than a
-- feature, so the whole class hangs off `show({ force = true })`.
--
-- The shape test is what keeps even the explicit ask cheap for ordinary text,
-- and it is pure: no process, no repository, no buffer.

local bare_git = require("hover.bare_git")

describe("bare_git.hex_run_at", function()
  ---@param line string
  ---@param col integer
  ---@return string|nil
  local function at(line, col)
    return bare_git.hex_run_at(line, col)
  end

  it("finds a short id in prose", function()
    assert.equals("bba2064", at("fixes bba2064 in the resolver", 8))
  end)

  it("finds a full 40-character id", function()
    local sha = string.rep("a1b2c3d4", 5)
    assert.equals(sha, at("see " .. sha .. " for it", 10))
  end)

  it("is bounded by punctuation, not by whitespace", function()
    assert.equals("deadb33f", at("reverted [deadb33f] yesterday", 12))
    assert.equals("deadb33f", at("fixes: deadb33f", 9))
  end)

  it("declines a run that is too short or too long", function()
    assert.is_nil(at("see abc123 here", 5)) -- 6
    assert.is_nil(at("see " .. string.rep("a1", 21) .. " here", 10)) -- 42
  end)

  it("declines a hex tail inside a longer word", function()
    -- The character on either side decides: `ff00ff` in `color_ff00ff` is
    -- part of an identifier, not an id someone can ask git about.
    assert.is_nil(at("local color_ff00ff = 1", 14))
    assert.is_nil(at("xdeadbeefy", 4))
  end)

  it("declines an all-digit run, which is a number", function()
    -- A line count, a year, a port. Requiring one a-f costs a few real short
    -- ids and saves asking git about every long integer in a log.
    assert.is_nil(at("took 12345678 ms", 7))
  end)

  it("declines a non-hex character", function()
    assert.is_nil(at("not hex: zzzzzzzz here", 12))
  end)

  it("declines an empty or out-of-range position", function()
    assert.is_nil(at("", 0))
    assert.is_nil(at("abc", 99))
  end)
end)

describe("bare_git and the trigger", function()
  local api = vim.api
  local hover = require("hover")
  local win, prev_buf, buf, asked

  before_each(function()
    require("hover.config").reset()
    vim.g.hover_disable = nil
    win = api.nvim_get_current_win()
    prev_buf = api.nvim_win_get_buf(win)
    buf = api.nvim_create_buf(true, false)
    api.nvim_win_set_buf(win, buf)
    api.nvim_buf_set_lines(buf, 0, -1, false, { "fixes bba2064 in the resolver" })
    api.nvim_win_set_cursor(win, { 1, 8 })

    -- Count the asks rather than time them: "was git started" is the
    -- property, and a timing assertion in a spec is a flaky test waiting to
    -- happen.
    asked = 0
    local real = vim.system
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.system = function(cmd, ...)
      if type(cmd) == "table" and cmd[1] == "git" then
        asked = asked + 1
      end
      return real(cmd, ...)
    end
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.system_real = real
  end)

  after_each(function()
    vim.system = vim.system_real
    vim.system_real = nil
    hover.hide()
    pcall(api.nvim_win_set_buf, win, prev_buf)
    pcall(api.nvim_buf_delete, buf, { force = true })
    require("hover.config").reset()
    vim.g.hover_disable = nil
  end)

  it("never starts git on the automatic trigger", function()
    hover.show()
    assert.equals(0, asked)
  end)

  it("starts git when the request is explicit", function()
    hover.show({ force = true })
    assert.is_true(asked > 0)
  end)
end)
