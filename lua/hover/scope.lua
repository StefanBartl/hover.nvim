---@module 'hover.scope'
---@brief Whether the cursor sits somewhere a path could plausibly be written.
---@description
--- The second half of the bare-path noise problem. `hover.bare_path` decides
--- whether a *string* is shaped like a path; this module decides whether the
--- *position* is one where a path can occur at all.
---
--- In a source file it almost always can't. A path is written in a comment or
--- inside a string literal — never in the middle of an expression. Everything
--- an expression is made of is spelled like something else: `vim.api.foo`,
--- `a / b`, `io.open`. Those are the remaining false starts once
--- `looks_like_path` has done its work, and no rule about the *text* can tell
--- them apart from a path, because textually they are not different.
---
--- **The gate is inverted from the obvious one, and that matters.** The
--- obvious rule is "allow only inside a comment or a string". It is wrong,
--- because it assumes prose buffers have no parser — and markdown, gitcommit,
--- rst and several others do. Under that rule a path in an ordinary markdown
--- paragraph would stop hovering, which is most of what this feature is for.
---
--- So the question asked here is the other one: **is this position positively
--- identifiable as executable code?** Only then is it refused.
---
---     no parser, or the parser errors     ==> allowed  (.txt, :messages, logs)
---     no captures at the position         ==> allowed  (plain markdown prose)
---     a prose-ish capture                 ==> allowed  (@comment, @string, @markup)
---     only code-ish captures              ==> refused  (@variable, @operator, …)
---     captures nobody here recognises     ==> allowed
---
--- Three of those five rows are "allowed", and the two that are not need
--- positive evidence. That is `ERR-20` applied to a gate: a buffer with no
--- parser, a parser that fails to load, or a grammar whose captures are named
--- something this module has never heard of must fall through to "check
--- anyway". A silently skipped region is much worse than an occasional extra
--- float — one is a feature that mysteriously does not work, the other is the
--- status quo.
---
--- **Where it sits in the pipeline, and why not first.** The roadmap asked
--- for this to be measured rather than assumed, and the measurement is the
--- reason for the ordering. On a 728-line Lua buffer, per call:
---
---     gate 1  `<cfile>` + looks_like_path      1.1 µs median
---     gate 2  this module, warm tree          90.2 µs median
---     gate 2  this module, after an edit     318.3 µs median
---
--- This gate is **roughly eighty times more expensive than the one in front
--- of it**, because answering at all means parsing. Put first, it would cost
--- every CursorHold in every buffer 90 µs and change; the intuition that a
--- syntax check is cheaper than a filesystem check is simply wrong here.
---
--- What makes it affordable is that it runs almost never. Of the 531 cursor
--- positions in that buffer, **one** survives gate 1 — an ordinary word is
--- not shaped like a path, so `looks_like_path` has already answered for
--- 99.8% of them. Amortised over every CursorHold the gate costs ~0.2 µs,
--- and it only ever runs on a token that already looks like a path, which is
--- exactly the population it exists to judge.
---
--- End to end this is not a slowdown: `bare_path.under_cursor` measures the
--- same 3.1 µs median with the gate on and off, because the gate is not on
--- the common path. The thing worth avoiding was always the resolver behind
--- both gates -- ~100 µs mean, ~1 ms p99, since it touches the filesystem.
---
--- The lesson is the ordering, not the number: a cheap gate belongs in front
--- of an expensive one even when the expensive one is more precise.
---
---@see hover.bare_path
---@see hover.config

local M = {}

local api = vim.api

---@internal
--- Capture families that mean "prose or data, not code". Matched on the first
--- dotted component, so `string.documentation` and `comment.error` are a
--- `string` and a `comment` without needing to be listed.
---@type table<string, true>
local PROSE = {
  comment = true,
  string = true,
  markup = true,
  text = true,
  spell = true,
  nospell = true,
  character = true,
  uri = true,
  url = true,
  none = true,
  conceal = true,
}

---@internal
--- Capture families that mean "executable code". A position captured only by
--- these, and by nothing in `PROSE`, is refused.
---
--- Deliberately explicit rather than "anything not in PROSE": an unfamiliar
--- capture from a grammar nobody here has seen must fall through to allowed,
--- and a denylist is the only shape that does that.
---@type table<string, true>
local CODE = {
  keyword = true,
  ["function"] = true,
  method = true,
  constructor = true,
  variable = true,
  parameter = true,
  field = true,
  property = true,
  module = true,
  namespace = true,
  type = true,
  constant = true,
  number = true,
  boolean = true,
  operator = true,
  punctuation = true,
  attribute = true,
  label = true,
  tag = true,
  preproc = true,
  define = true,
  include = true,
  conditional = true,
  repeat_ = true,
  ["repeat"] = true,
  exception = true,
  storageclass = true,
  structure = true,
  error = true,
  debug = true,
}

---@internal
--- The captures Treesitter reports for one position, or nil when there is no
--- answer to be had -- no parser, or a parser that threw.
---
--- `nil` and `{}` are different answers and both are "allowed", but for
--- different reasons: nil is "nothing could tell us", `{}` is "the grammar
--- looked and this position is not anything in particular".
---
--- **`get_captures_at_pos` does not parse.** On an unparsed tree it answers
--- `{}` rather than failing, and `{}` is indistinguishable from "plain text
--- here" -- so without the explicit parse below this gate would silently
--- allow everything and look like it was working. In an editing session the
--- highlighter usually keeps the tree fresh and it would appear correct;
--- headless, or in a buffer nothing is highlighting, it would not. Relying on
--- another feature to have done the parse is exactly the kind of invisible
--- dependency this plugin's placement bugs were made of.
---
--- Parsed for the one line being asked about rather than the document: the
--- answer needed is about a single position, and a whole-file parse on every
--- candidate token would be the cost the roadmap was right to worry about.
---@param bufnr integer
---@param row integer 1-based, as `nvim_win_get_cursor` reports it.
---@param col integer 0-based.
---@return table[]|nil
local function captures_at(bufnr, row, col)
  if not vim.treesitter or not vim.treesitter.get_captures_at_pos then
    return nil
  end
  local ok_parser, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok_parser or type(parser) ~= "table" then
    return nil
  end
  pcall(parser.parse, parser, { row - 1, row })

  local ok, caps = pcall(vim.treesitter.get_captures_at_pos, bufnr, row - 1, col)
  if not ok or type(caps) ~= "table" then
    return nil
  end
  return caps
end

---@internal
--- The last answer, and what it was an answer to.
---
--- **One slot, because the pattern is one position asked twice.** Under
--- `CursorHold` the trigger fires after any keystroke followed by quiet --
--- cursor movement or not -- so the same position is asked again and again
--- while a reader sits still. Measured, that repeat is the only cache hit
--- worth having here: the parse costs 0.2 us and is not the problem, while
--- `get_captures_at_pos` costs 61 us and is per *column*, so moving along a
--- line is all misses anyway.
---
--- A single slot has no eviction policy to get wrong and no memory to grow.
--- `changedtick` retires it on any edit, which is the only way the answer for
--- a position can change without the position changing.
---
--- Measured, and both halves recorded because the second is a real cost:
---
---     dieselbe Position erneut      8.2 us  ->  0.2 us
---     wandernde Spalte (Fehlgriff)  8.2 us  ->  9.5 us
---
--- The miss pays ~1.3 us for the `changedtick` lookup. It is worth it because
--- the hit is not the rare case here: under `CursorHold` the trigger fires
--- after any keystroke followed by quiet, so a reader sitting still asks the
--- same position over and over.
---
--- How often it is asked at all depends entirely on the buffer -- 1.7% of
--- cursor positions in ordinary source, 62% in a file whose comments are full
--- of paths, 0% in prose with no parser. The second population is the one
--- that made this worth building.
---@type { bufnr: integer, tick: integer, row: integer, col: integer, answer: boolean }|nil
local _last = nil

--- Whether a bare path may be looked for at this position.
---
--- Answers `true` unless the position is positively identifiable as
--- executable code. See the module description for the five cases and why
--- three of them are permissive.
---@param bufnr integer
---@param row integer 1-based.
---@param col integer 0-based.
---@return boolean
function M.allows_path(bufnr, row, col)
  local ok_tick, tick = pcall(api.nvim_buf_get_changedtick, bufnr)
  if not ok_tick then
    tick = nil
  end

  if
    _last
    and tick
    and _last.bufnr == bufnr
    and _last.tick == tick
    and _last.row == row
    and _last.col == col
  then
    return _last.answer
  end

  local answer = M._decide(bufnr, row, col)
  if tick then
    _last = { bufnr = bufnr, tick = tick, row = row, col = col, answer = answer }
  end
  return answer
end

---@internal
--- The decision itself, without the memo in front of it. Separate so the
--- specs can drive it directly: a cache that answers correctly and a decision
--- that answers correctly are two different claims.
---@param bufnr integer
---@param row integer
---@param col integer
---@return boolean
function M._decide(bufnr, row, col)
  local caps = captures_at(bufnr, row, col)
  if not caps or #caps == 0 then
    return true
  end

  local code = false
  for _, cap in ipairs(caps) do
    local name = type(cap) == "table" and cap.capture or nil
    if type(name) == "string" then
      local family = name:match("^[^.]+")
      if family then
        if PROSE[family] then
          return true
        end
        if CODE[family] then
          code = true
        end
      end
    end
  end

  return not code
end

return M
