---@diagnostic disable: need-check-nil, duplicate-set-field
-- The test body is the guard; see the note in TESTS/bare_path_spec.lua
-- (`LLS-42`). `duplicate-set-field` is disabled for the same reason one step
-- further on: the fail-open cases below can only be reached by replacing a
-- `vim.treesitter` function with one that throws, and LuaLS reads every such
-- replacement as redefining a field it already knows. Stubbing the API under
-- test is the test.

-- TESTS/scope_spec.lua -- the position gate, and the three ways it is allowed
-- to be wrong.
--
-- The gate refuses a position only when Treesitter positively identifies it
-- as executable code. Every other outcome is "allowed", and each of those is
-- a separate failure mode worth pinning:
--
--   1. **Prose buffers have parsers.** markdown, gitcommit and rst are
--      parsed, so the obvious rule ("allow only inside a comment or string")
--      would stop a path hovering in an ordinary markdown paragraph -- which
--      is most of what the bare-path feature is for. The inverted rule is
--      the whole design, and the markdown case below is its regression test.
--   2. **An unknown capture family must fall through to allowed** (`ERR-20`).
--      A grammar this plugin has never seen must not silently disable the
--      feature in that language.
--   3. **`get_captures_at_pos` does not parse.** On an unparsed tree it
--      answers `{}`, which is indistinguishable from "plain text here". The
--      module parses first; if that is ever removed, the real-buffer code
--      cases below start answering `true` and the gate becomes a no-op that
--      still looks like it works.

local scope = require("hover.scope")

--- A scratch buffer with `lines`, its filetype set and its parser started.
--- Returns nil when this Neovim has no parser for `ft`.
---@param ft string
---@param lines string[]
---@return integer|nil
local function parsed_buf(ft, lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = ft
  if not pcall(vim.treesitter.start, buf, ft) then
    vim.api.nvim_buf_delete(buf, { force = true })
    return nil
  end
  return buf
end

--- `parsed_buf` for a language Neovim ships a parser for, so a missing one is
--- a broken environment rather than a reason to pass quietly.
---@param ft string
---@param lines string[]
---@return integer
local function require_buf(ft, lines)
  local buf = parsed_buf(ft, lines)
  if not buf then
    error("no bundled Treesitter parser for " .. ft .. "; cannot test the gate")
  end
  return buf
end

--- Ask the gate about one position in a throwaway buffer.
---@param ft string
---@param lines string[]
---@param row integer
---@param col integer
---@return boolean
local function allows(ft, lines, row, col)
  local buf = require_buf(ft, lines)
  local answer = scope.allows_path(buf, row, col)
  vim.api.nvim_buf_delete(buf, { force = true })
  return answer
end

--- Run `fn` with `vim.treesitter` stubbed, then put the real functions back
--- whether or not it threw.
---@param stub { parse?: fun(), captures?: fun():any }
---@param fn fun()
local function with_ts(stub, fn)
  local real_caps = vim.treesitter.get_captures_at_pos
  local real_parser = vim.treesitter.get_parser

  vim.treesitter.get_parser = function()
    if stub.parse then
      return { parse = stub.parse }
    end
    return { parse = function() end }
  end
  vim.treesitter.get_captures_at_pos = stub.captures or function()
    return {}
  end

  local ok, err = pcall(fn)

  vim.treesitter.get_captures_at_pos = real_caps
  vim.treesitter.get_parser = real_parser
  if not ok then
    error(err)
  end
end

--- The gate's answer for a capture list no real grammar has to produce.
---
--- Through `_decide` rather than `allows_path`: the memo in front of that one
--- keys on (buffer, changedtick, row, col), and these cases feed different
--- captures to the *same* position -- something only a stub can do, and
--- exactly what the memo is entitled to assume cannot happen. Testing the
--- rule through the cache would test the cache.
---@param caps any
---@return boolean
local function decide(caps)
  local answer
  with_ts({
    captures = function()
      return caps
    end,
  }, function()
    answer = scope._decide(0, 1, 0)
  end)
  return answer
end

describe("hover.scope", function()
  describe("in a source file", function()
    it("allows a path written in a comment", function()
      assert.is_true(allows("lua", { "-- see ./docs/BINDINGS.md for more" }, 1, 11))
    end)

    it("allows a path written inside a string", function()
      assert.is_true(allows("lua", { 'local p = "./docs/BINDINGS.md"' }, 1, 15))
    end)

    it("refuses an identifier in the middle of an expression", function()
      assert.is_false(allows("lua", { "local x = vim.api.nvim_buf_get_lines" }, 1, 16))
    end)

    it("refuses the operand of a division, which is spelled like a path", function()
      -- `alpha / beta` has a separator and two components, exactly like
      -- `docs/BINDINGS.md`. No rule about the text can separate them.
      assert.is_false(allows("lua", { "local r = alpha / beta" }, 1, 10))
    end)
  end)

  describe("in a buffer that is prose", function()
    it("allows an ordinary markdown paragraph, which HAS a parser", function()
      local buf = parsed_buf("markdown", { "See ./docs/BINDINGS.md for more." })
      if not buf then
        return -- no markdown parser here; nothing to assert
      end
      assert.is_true(scope.allows_path(buf, 1, 8))
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("allows a buffer with no parser at all", function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "...Local/nvim/init.lua:42" })
      assert.is_true(scope.allows_path(buf, 1, 10))
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  describe("the decision rule", function()
    it("allows when a prose capture is present, whatever else is", function()
      assert.is_true(decide({ { capture = "variable" }, { capture = "comment" } }))
    end)

    it("matches on the capture family, not the whole name", function()
      assert.is_true(decide({ { capture = "string.documentation" } }))
      assert.is_false(decide({ { capture = "variable.member" } }))
    end)

    it("allows a capture family it does not recognise", function()
      -- ERR-20: an unfamiliar grammar must not disable the feature silently.
      assert.is_true(decide({ { capture = "wittgenstein.ladder" } }))
    end)

    it("allows an empty capture list", function()
      assert.is_true(decide({}))
    end)

    it("allows when entries in the capture list are malformed", function()
      assert.is_true(decide({ "not a table", { no_capture_field = true } }))
    end)

    it("allows when the captures are not a list at all", function()
      assert.is_true(decide("nonsense"))
    end)
  end)

  describe("fail-open", function()
    it("allows when the parser lookup throws", function()
      local real = vim.treesitter.get_parser
      vim.treesitter.get_parser = function()
        error("no parser for this language")
      end
      local ok, allowed = pcall(scope._decide, 0, 1, 0)
      vim.treesitter.get_parser = real
      assert.is_true(ok)
      assert.is_true(allowed)
    end)

    it("allows when the capture lookup throws", function()
      local allowed
      with_ts({
        captures = function()
          error("query failed to load")
        end,
      }, function()
        allowed = scope._decide(0, 1, 0)
      end)
      assert.is_true(allowed)
    end)

    it("still answers when parsing throws but a tree is already there", function()
      local allowed
      with_ts({
        parse = function()
          error("parse failed")
        end,
        captures = function()
          return { { capture = "comment" } }
        end,
      }, function()
        allowed = scope._decide(0, 1, 0)
      end)
      assert.is_true(allowed)
    end)
  end)

  -- The memo in front of the decision. What it is entitled to assume is that
  -- the captures at a position cannot change while the buffer does not --
  -- true of every real buffer and false of a stub, which is why the rule
  -- specs above drive `_decide` directly.
  describe("the one-slot memo", function()
    it("answers the same position twice without asking again", function()
      local asked = 0
      local buf = parsed_buf("lua", { "-- see ./docs/BINDINGS.md for more" })
      assert.is_truthy(buf)
      local real = vim.treesitter.get_captures_at_pos
      vim.treesitter.get_captures_at_pos = function(...)
        asked = asked + 1
        return real(...)
      end
      scope.allows_path(buf, 1, 11)
      scope.allows_path(buf, 1, 11)
      scope.allows_path(buf, 1, 11)
      vim.treesitter.get_captures_at_pos = real
      assert.equals(1, asked)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("asks again for another column on the same line", function()
      -- Captures are per column, so moving along a line is all misses --
      -- which is why the memo is one slot and not a per-row table.
      local asked = 0
      local buf = parsed_buf("lua", { "-- see ./docs/BINDINGS.md for more" })
      assert.is_truthy(buf)
      local real = vim.treesitter.get_captures_at_pos
      vim.treesitter.get_captures_at_pos = function(...)
        asked = asked + 1
        return real(...)
      end
      scope.allows_path(buf, 1, 11)
      scope.allows_path(buf, 1, 12)
      vim.treesitter.get_captures_at_pos = real
      assert.equals(2, asked)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("asks again after the buffer changes", function()
      local asked = 0
      local buf = parsed_buf("lua", { "-- see ./docs/BINDINGS.md for more" })
      assert.is_truthy(buf)
      local real = vim.treesitter.get_captures_at_pos
      vim.treesitter.get_captures_at_pos = function(...)
        asked = asked + 1
        return real(...)
      end
      scope.allows_path(buf, 1, 11)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "local x = ./docs/BINDINGS.md" })
      scope.allows_path(buf, 1, 11)
      vim.treesitter.get_captures_at_pos = real
      assert.equals(2, asked)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  -- The gate in place, through the function the plugin actually calls. The
  -- fixture is the false-positive class itself: `lua/hover` is both a real
  -- directory and a valid Lua division, so the text resolves and only the
  -- position can tell the two readings apart.
  describe("through bare_path.under_cursor", function()
    local api = vim.api
    local bare = require("hover.bare_path")
    local root, win, prev_buf, prev_isfname, buf

    before_each(function()
      root = vim.fn.tempname()
      vim.fn.mkdir(root .. "/lua/hover", "p")

      win = api.nvim_get_current_win()
      prev_buf = api.nvim_win_get_buf(win)
      prev_isfname = vim.o.isfname
      vim.o.isfname = "@,48-57,/,.,-,_,+,,,#,$,%,~,=,:"

      buf = api.nvim_create_buf(false, true)
      api.nvim_buf_set_name(buf, root .. "/probe.lua")
      api.nvim_win_set_buf(win, buf)
      vim.bo[buf].filetype = "lua"
      pcall(vim.treesitter.start, buf, "lua")
    end)

    after_each(function()
      pcall(api.nvim_win_set_buf, win, prev_buf)
      pcall(api.nvim_buf_delete, buf, { force = true })
      vim.o.isfname = prev_isfname
      vim.fn.delete(root, "rf")
    end)

    ---@param line string
    ---@param marker string
    ---@param code boolean whether paths in code are allowed
    ---@return string|nil
    local function target(line, marker, code)
      api.nvim_buf_set_lines(buf, 0, -1, false, { line })
      local at = line:find(marker, 1, true)
      assert.is_truthy(at)
      api.nvim_win_set_cursor(win, { 1, at - 1 })
      local src = bare.under_cursor(buf, { missing = true, code = code })
      return src and src.target or nil
    end

    it("still reports a path written in a comment", function()
      assert.equals("lua/hover", target("-- see lua/hover for the modules", "lua/hover", false))
    end)

    it("does not report the same text used as a division", function()
      assert.is_nil(target("local r = lua/hover", "lua/hover", false))
    end)

    it("reports it again once paths in code are allowed", function()
      assert.equals("lua/hover", target("local r = lua/hover", "lua/hover", true))
    end)
  end)
end)
