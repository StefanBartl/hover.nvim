---@module 'hover.bare_url'
---@brief Find a URL under the cursor in text that carries no link syntax.
---@description
--- `hover.bare_path` answers "is the cursor on a path"; this answers
--- the same question for a URL:
---
---     see https://neovim.io/doc/user/api.html#nvim_open_win for the flags
---          └──────────────── hover here ────────────────┘
---
--- **Why not leave this to `bare_path`.** It very nearly worked by accident:
--- `<cfile>` reads `https://neovim.io/...` off the line, nothing on disk
--- matches, and the "could this only have been a path?" test says yes because
--- a component carries an extension. Accidental in every part — `<cfile>`
--- stops at whatever `'isfname'` happens to exclude (a `?query=`, a `#`
--- fragment, a comma), so the target was routinely a truncated URL, and in a
--- buffer where `'isfname'` is set differently there was no target at all.
--- A URL is found by *shape*, on the line, and the shape is not the
--- filesystem's.
---
--- **Why markdown.nvim does not cover it.** It does, inside a markdown
--- buffer: `markdown.core.link_scan` finds inline links, autolinks and bare
--- URLs and registers as a hover source. That is exactly one filetype. A URL
--- in a Lua comment, a `.txt`, a git commit message or a `:messages` dump is
--- the same URL, and none of them load markdown.nvim.
---
--- **Windows backslashes are accepted on purpose.** `http:\\example.com` is a
--- typo a Windows keyboard produces constantly, and every part of the chain
--- downstream can cope with it: `classify` normalizes the separators, and the
--- preview shows the host it was going to. Refusing to recognize it would
--- mean the hover stays silent on exactly the line where "why does this link
--- not work" is the question.

local M = {}

local api = vim.api

--- Shapes a URL takes in running text, most specific first.
---
--- The scheme is required to be **two or more characters**, which is not
--- pedantry: `C:\\Users\\me` inside a Lua string literal is a one-letter
--- "scheme" followed by two separators, and without that rule every Windows
--- path in every source file would be offered to the URL previewer.
---
--- The terminator set is what prose and markup wrap a URL in — whitespace,
--- angle brackets, quotes, backticks, pipes — and never part of a URL that
--- was written to be clicked.
---@type string[]
local PATTERNS = {
  "%a%a[%w+.-]*://[^%s<>\"'`|\\]+", -- https://example.com/a?b=c#d
  "%a%a[%w+.-]*:\\+[^%s<>\"'`|/]+", -- http:\\example.com  (the Windows typo)
  "mailto:[^%s<>\"'`|\\]+",
  "www%.[%w%-_]+%.[^%s<>\"'`|\\]+", -- www.example.com/a — scheme omitted
}

---@internal
--- Strip what a sentence or a markup construct wrapped around the URL.
---
--- Two separate jobs. Trailing sentence punctuation is never part of a URL
--- ("see https://example.com."), and a closing bracket only belongs to the
--- URL if the URL opened it — `(https://example.com)` in prose closes a
--- parenthesis the URL never opened, but
--- `https://en.wikipedia.org/wiki/Vim_(text_editor)` closes its own.
---@param url string
---@return string
local function trim_trailing(url)
  local out = url
  for _ = 1, 8 do -- bounded: each pass must remove something or stop
    local before = out

    out = out:gsub("[%.,;:!%?]+$", "")

    local last = out:sub(-1)
    local opener = ({ [")"] = "(", ["]"] = "[", ["}"] = "{" })[last]
    if opener then
      local _, opens = out:gsub("%" .. opener, "")
      local _, closes = out:gsub("%" .. last, "")
      if closes > opens then
        out = out:sub(1, -2)
      end
    end

    if out == before then
      break
    end
  end
  return out
end

--- Every URL-shaped span on `line`, with 0-based column bounds.
---
--- Public because it is the whole testable part of this module: the cursor
--- handling around it is three lines and needs a window.
---@param line string
---@return { url: string, col: integer, col_end: integer }[]
function M.spans(line)
  local found = {}
  if type(line) ~= "string" or line == "" then
    return found
  end

  ---@param at integer 1-based start of an already-accepted span
  ---@param to integer 1-based end
  ---@return boolean
  local function overlaps(at, to)
    for _, span in ipairs(found) do
      if at <= span.col_end + 1 and to >= span.col + 1 then
        return true
      end
    end
    return false
  end

  for _, pattern in ipairs(PATTERNS) do
    local init = 1
    while init <= #line do
      local s, e = line:find(pattern, init)
      if not s then
        break
      end

      local url = trim_trailing(line:sub(s, e))
      -- A later, looser pattern must not re-report the tail of a URL an
      -- earlier one already claimed: `www.` sits inside `https://www.…`.
      if url ~= "" and not overlaps(s, s + #url - 1) then
        found[#found + 1] = { url = url, col = s - 1, col_end = s + #url - 2 }
      end
      init = e + 1
    end
  end

  return found
end

---@internal
--- The bytes no shape in `PATTERNS` may contain: what ends a URL in running text.
---@type table<integer, true>
local TERMINATOR = {}
for byte = 9, 13 do -- tab, newline, vertical tab, form feed, carriage return
  TERMINATOR[byte] = true
end
for _, ch in ipairs({ " ", "<", ">", '"', "'", "`", "|" }) do
  TERMINATOR[ch:byte()] = true
end

---@internal
--- The longest token `under_cursor` will look at, each way from the cursor.
--- Browsers and servers refuse URLs past a few KB, and the scan is quadratic in
--- a long run.
local MAX_TOKEN = 4096

--- The URL under the cursor, in the shape `hover` expects from a
--- source.
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
  if not line or line == "" then
    return nil
  end
  -- Cheapest possible gate: no line without one of these can hold a URL, and
  -- this runs on every CursorHold in every buffer.
  if
    not (
      line:find("://", 1, true)
      or line:find(":\\", 1, true)
      or line:find("www.", 1, true)
      or line:find("mailto:", 1, true)
    )
  then
    return nil
  end

  -- Only the token under the cursor can be the answer. No shape above contains
  -- whitespace, an angle bracket, a quote, a backtick or a pipe, so a URL never
  -- spans one -- and scanning the whole line is wasted work that is not merely
  -- linear: the patterns restart at every position of a long run, so a
  -- minified line of a few thousand characters costs seconds, on every
  -- CursorHold, for as long as the cursor rests there.
  local left, right = col + 1, col + 1
  if TERMINATOR[line:byte(left)] or left > #line then
    return nil
  end
  local lo, hi = math.max(1, left - MAX_TOKEN), math.min(#line, right + MAX_TOKEN)
  while left > lo and not TERMINATOR[line:byte(left - 1)] do
    left = left - 1
  end
  while right < hi and not TERMINATOR[line:byte(right + 1)] do
    right = right + 1
  end
  -- A token that runs on past the cap is not a URL anyone wrote to be clicked.
  if
    (left == lo and left > 1 and not TERMINATOR[line:byte(left - 1)])
    or (right == hi and right < #line and not TERMINATOR[line:byte(right + 1)])
  then
    return nil
  end

  local offset = left - 1
  for _, span in ipairs(M.spans(line:sub(left, right))) do
    if col - offset >= span.col and col - offset <= span.col_end then
      return {
        target = span.url,
        lnum = row,
        col = span.col + offset,
        col_end = span.col_end + offset,
        kind = "bare_url",
      }
    end
  end
  return nil
end

return M
