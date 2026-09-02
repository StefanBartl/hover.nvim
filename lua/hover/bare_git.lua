---@module 'hover.bare_git'
---@brief A git object id under the cursor, on explicit request only.
---@description
--- A 7-to-40 character hex string in a commit message, a log, a review or a
--- bisect transcript is a target: `git show --stat` of it says what that
--- commit did, without leaving the buffer.
---
--- **Why this one never fires on a timer, unlike every other target class.**
--- Knowing whether a hex string *is* an object means asking git, and asking
--- git means starting git. Measured on this machine:
---
---     git cat-file -e   (hit)     40.9 ms
---     git cat-file -e   (miss)    41.1 ms
---     git show --stat             40.9 ms
---
--- Forty-one milliseconds, and the miss costs the same as the hit — there is
--- no cheap way to ask. For comparison, the whole bare-path pipeline was
--- reworked in this repository because a miss there cost 13 ms, and that was
--- considered a wall. Three times the wall, on a trigger that fires after
--- every keystroke followed by quiet, is not a feature, it is a stutter.
---
--- So this class is reached from `show({ force = true })` and nothing else:
--- `:Hover show`, or a key bound to it. That is the same bargain the rest of
--- the plugin already makes for expensive answers — `links web fetch`
--- discloses, `office convert` starts LibreOffice, and neither happens
--- unasked. This one goes further because its cost cannot be gated behind a
--- switch the way those can: a switch would only move the decision, not the
--- 41 ms.
---
--- **The shape test is free and runs first**, so the ask only happens for
--- text that could plausibly be an object id: hex, 7 to 40 characters, and
--- not a fragment of a longer word. `deadbeef` in prose still costs a git
--- call — there is no way around that — but only when someone asked about
--- `deadbeef` specifically.
---
---@see hover.bare_path
---@see hover.preview.git

local M = {}

local api = vim.api

---@internal
--- The hex run the cursor is inside, or nil.
---
--- Bounded by non-hex characters rather than by whitespace: a SHA in
--- `fixes: a1b2c3d4` or `[a1b2c3d4]` is the same SHA. The bounds are also why
--- a 41-character run answers nil rather than its first 40 -- that is not an
--- object id with punctuation around it, it is something else.
---@param line string
---@param col integer 0-based
---@return string|nil
local function hex_run_at(line, col)
  if type(line) ~= "string" or line == "" then
    return nil
  end
  local char = line:sub(col + 1, col + 1)
  if not char:match("%x") then
    return nil
  end

  local first = col + 1
  while first > 1 and line:sub(first - 1, first - 1):match("%x") do
    first = first - 1
  end
  local last = col + 1
  while last < #line and line:sub(last + 1, last + 1):match("%x") do
    last = last + 1
  end

  -- The characters immediately outside the run decide whether this is a
  -- standalone token. `abcdefg` inside `xabcdefgy` is not an object id, and
  -- neither is the hex tail of an identifier like `color_ff00ff`.
  local before = first > 1 and line:sub(first - 1, first - 1) or ""
  local after = last < #line and line:sub(last + 1, last + 1) or ""
  if before:match("[%w_]") or after:match("[%w_]") then
    return nil
  end

  local run = line:sub(first, last)
  if #run < 7 or #run > 40 then
    return nil
  end
  -- All-digits is a number: a line count, a year, a port. Requiring at least
  -- one a-f costs a small number of real short SHAs and saves asking git
  -- about every long integer in a log.
  if not run:match("%a") then
    return nil
  end
  return run
end

--- The hex run under the cursor, if it looks like an object id.
---
--- Pure and free: no process is started here. Confirming that the object
--- *exists* is `hover.preview.git`'s job, because that is the part that
--- costs 41 ms and it belongs on the far side of the force gate.
---@param bufnr? integer
---@return Hover.Source|nil
function M.under_cursor(bufnr)
  if not bufnr or bufnr == 0 then
    bufnr = api.nvim_get_current_buf()
  end
  local win = api.nvim_get_current_win()
  if api.nvim_win_get_buf(win) ~= bufnr then
    return nil
  end

  local pos = api.nvim_win_get_cursor(win)
  local row, col = pos[1], pos[2]
  local line = api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1]
  local run = hex_run_at(line, col)
  if not run then
    return nil
  end

  return {
    target = run,
    col = col,
    col_end = col,
    lnum = row,
    kind = "git",
  }
end

--- Exposed for the spec suite: the shape test on its own, without a buffer.
---@param line string
---@param col integer 0-based
---@return string|nil
function M.hex_run_at(line, col)
  return hex_run_at(line, col)
end

return M
