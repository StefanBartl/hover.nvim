---@module 'hover.bare_path'
---@brief Find a filesystem path under the cursor that is not written as a link.
---@description
--- `hover` answers "what does the link under the cursor point at".
--- This module answers the same question for text that carries no link syntax
--- at all — a path sitting in prose, in a code comment, in a `:messages` dump:
---
---     ./assets/pdf_inline_hover.png
---     ../docs/BINDINGS.md
---     ...AppData/Local/nvim/init.lua:42
---
--- Everything downstream is unchanged: the raw string produced here goes into
--- `hover.classify` exactly like a link target would, so a bare path
--- gets the same image / PDF / markdown-section / file-head / directory
--- preview a linked one already gets. This module only widens *what counts as
--- a target*, never what a target can look like once found.
---
--- **Why gopath.nvim rather than `<cfile>` alone.** `<cfile>` reads a token
--- off the line under the cursor and stops there. gopath.nvim resolves the
--- awkward cases that a log or an error message actually produces: a
--- truncated path (`...nvim/init.lua`, `…/lua/config/init.lua`), a `:line:col`
--- suffix, a path only findable through `&path`/`rtp`/a tail search. That is
--- precisely the "a path in `:messages`, truncated or not, should hover too"
--- case, and it is gopath's whole subject matter — reimplementing any of it
--- here would be duplicating a sibling plugin for no gain. Soft dependency:
--- without gopath.nvim the `<cfile>` path below still covers ordinary
--- relative and absolute paths.
---
--- **Why existence is required.** A link is an explicit statement that
--- something is there, so `classify` reporting `missing` for a broken link is
--- useful. Bare text is not: every ordinary word under the cursor would
--- otherwise open a float saying "this target does not exist". So a bare path
--- must resolve to something real, or it is not a target at all.

local M = {}

local api = vim.api

---@internal
--- The `/`- and `\`-separated components of `str`, empties dropped.
---
--- `a/b` and `C:\a\b` both come back as two components, `sortiert/` as one,
--- `/` as none. Nearly everything the two tests below want to know about a
--- string turns out to be a question about its components rather than about
--- the characters in it.
---@param str string
---@return string[]
local function segments(str)
  local out = {}
  for seg in str:gmatch("[^/\\]+") do
    out[#out + 1] = seg
  end
  return out
end

---@internal
--- Whether `str` is shaped like a path rather than an ordinary word.
---
--- Deliberately stricter than gopath's own heuristic: this runs on every
--- CursorHold in every buffer, so a plain word ("the", "config", "return")
--- must be rejected before any filesystem call. A separator or an extension
--- is the cheapest evidence that text was meant as a path.
---@param str string
---@return boolean
local function looks_like_path(str)
  if type(str) ~= "string" or str == "" then
    return false
  end
  if #str > 512 then
    return false
  end

  -- Punctuation on its own is never a path. A table cell writes `--% / --%`,
  -- a ratio writes `60% / 27%`, and `<cfile>` reads `/` or `/--%` out of
  -- those -- each carrying a separator, which the very next test accepts.
  -- One alphanumeric character anywhere is the cheapest way to ask "is there
  -- a name in here at all", and it costs a single pattern match to keep
  -- gopath's whole resolver pipeline out of a punctuation table.
  if not str:match("%w") then
    return false
  end

  if str:match("[/\\]") then
    return true
  end -- a/b, ./a, C:\a
  if str:match("^%.%.%.") or str:match("^…") then
    return true
  end -- truncated
  if str:match("%.[%w]+$") then
    return true
  end -- README.md
  if str:match("%.[%w]+:%d+") then
    return true
  end -- init.lua:42
  return false
end

---@internal
--- Whether `str` can *only* have been meant as a path.
---
--- The distinction that decides whether a **non-existent** target is worth
--- reporting. `looks_like_path` accepts a bare `name.ext` because `README.md`
--- in prose is a path — but so is `vim.api`, `string.format` or any Lua
--- module name, and those are the overwhelming majority of what a code buffer
--- puts under the cursor. Reporting those as broken paths would put a red ✗
--- on half the identifiers in every Lua file.
---
--- **A separator alone is not the evidence it looks like.** It was the whole
--- test here once, on the reasoning that no identifier is spelled `docs/a.md`
--- -- which is true, and beside the point, because prose is full of
--- separators that were never a path either: `and/or`, a table header
--- `Actual/Insgesamt`, a ratio `60% / 27%`, a word given a trailing slash
--- (`sortiert/`). Every one of those opened a confident "no such file" for a
--- directory nobody had mentioned.
---
--- **Nor is a component count.** "Three or more components" was the second
--- attempt, on the reasoning that prose writes `and/or` but not a three-deep
--- alternative. Measured against real text it writes rather a lot of them:
--- `2026/09/01`, `TODO/FIXME/DONE`, `read/write/execute`, `key/value/pair`,
--- `a/b/c`. Each one got a red mark.
---
--- **Nor is an extension anywhere in the path.** `github.com/user/repo`
--- carries `.com` on its *first* component and is not a path at all -- while
--- what a path points at is its *last* component, which is where an
--- extension actually says something.
---
--- What survives is deliberately narrow: the text has to be spelled the way
--- only a path is spelled, or end in something that names a file.
---
--- | Evidence | Example | But not |
--- | --- | --- | --- |
--- | a truncation | `...nvim/init.lua` | |
--- | a drive or UNC prefix | `C:\Users\x`, `\\server\share` | |
--- | an extension on the **last** component | `docs/gone.md`, `./src/app.ts` | `github.com/user/repo` |
---
--- Everything else stays silent -- including `./components/Button`, which is
--- how every extension-less JavaScript import is written, and `~/notes`,
--- `/etc/hosts` and `lua/lib/nvim` when they do not exist. That is a real
--- loss of true positives, taken on purpose: this is the only preview class
--- whose value goes *negative* when it is wrong, because a red mark on prose
--- is worse than no mark on a broken path. Silence is not "this target is
--- fine", it is "not confident enough to put a red mark on it".
---
--- Nothing that *exists* is affected: a resolved target never reaches this
--- test at all, so `docs/` and `and/or` both hover normally the moment
--- something of that name is on disk.
---@param str string
---@return boolean
local function is_unambiguous_path(str)
  if type(str) ~= "string" or str == "" then
    return false
  end
  if not str:match("%w") then
    return false
  end

  -- Two shapes prose simply does not produce, so they stand on their own: a
  -- leading truncation, and a Windows drive or UNC prefix.
  if str:match("^%.%.%.") or str:match("^…") then
    return true
  end
  if str:match("^%a:[/\\]") or str:match("^[/\\][/\\]") then
    return true
  end

  -- One component is one word, whatever punctuation is stuck to it: the
  -- trailing slash in `sortiert/` says no more about intent than the dot in
  -- `vim.api` does.
  local segs = segments(str)
  if #segs < 2 then
    return false
  end

  -- An extension on the component the path actually points at. Not on *any*
  -- component -- `github.com/user/repo` would pass that, and it is a
  -- repository slug, not a file.
  return segs[#segs]:match("%.[%w]+$") ~= nil
end

---@internal
--- Strip what surrounds a path in real prose but is not part of it: quotes,
--- markdown emphasis, brackets, and trailing sentence punctuation. A path at
--- the end of a sentence ("see ./docs/a.md.") must not lose its match to the
--- full stop, but `a.md` must keep its extension.
---@param str string
---@return string
local function trim_delimiters(str)
  local out = vim.trim(str)
  out = out:gsub("^[%(%[{<\"'`*_]+", ""):gsub("[%)%]}>\"'`*_]+$", "")
  out = out:gsub("[%.,;:!%?]+$", "")
  return out
end

---@internal
--- The `:line[:col]` suffix a log line carries, split off the path itself.
--- `classify` stats the path, so the suffix has to go; it is returned so the
--- caller can keep it for display.
---@param str string
---@return string path
---@return string|nil location
local function split_location(str)
  local path, location = str:match("^(.-)(:%d+:?%d*)$")
  if path and path ~= "" then
    return path, location
  end
  return str, nil
end

---@internal
--- gopath.nvim's answer for the cursor position, when it is installed, is
--- enabled, and confirms the path exists.
---@return string|nil path absolute path
---@return integer|nil line 1-based line the target named, if any
local function via_gopath()
  local ok, gopath = pcall(require, "gopath.resolve")
  if not ok or type(gopath.resolve_at_cursor) ~= "function" then
    return nil
  end

  local ok_res, res = pcall(gopath.resolve_at_cursor)
  if not ok_res or type(res) ~= "table" then
    return nil
  end

  -- A URL result is gopath's own concern (it opens a browser); the hover has
  -- its own URL previewer reached through the link path, and a bare URL is
  -- already found by `link_scan`. Only local, confirmed files interest us.
  if res.kind == "url" then
    return nil
  end
  if not (res.exists and type(res.path) == "string" and res.path ~= "") then
    return nil
  end
  -- gopath resolves `:line:col` suffixes as part of its job, so the line is
  -- already known here. It used to be thrown away.
  return res.path, type(res.line) == "number" and res.line or nil
end

---@internal
--- Whether gopath is worth asking, once `<cfile>` has already failed.
---
--- **Measured, and the reason this gate exists.** gopath answers every case
--- it can answer in under 500 us -- 128 us for a relative path, 368 us for a
--- truncated one, 469 us for a bare name found through `&path`/`rtp`. Its
--- *failures* are the expensive half: 1.4 ms for a bare name that does not
--- exist, and **12.7 ms** for a token with a separator that does not. That
--- last population is exactly what a log, a diff or a stack trace is full
--- of, and it was being paid on every trigger.
---
--- None of that is gopath behaving badly. Running `&path`, `rtp` and a tail
--- search that may shell out to `fd`/`rg` is right for `gP`, where a human
--- asked and is waiting. It is wrong for something that fires on a timer.
---
--- So on the automatic trigger gopath is asked only where it can contribute
--- something `<cfile>` cannot: a truncation, which is its whole subject
--- matter, or a name with no separator, which is the `&path`/`rtp` case.
--- A separator-carrying token that `<cfile>` could not resolve against the
--- buffer's directory or the cwd is skipped.
---
--- **What that gives up**, so it is a decision and not a discovery: a
--- relative path that exists somewhere else in the project -- not beside the
--- buffer, not under the cwd -- stops resolving automatically. gopath's tail
--- search would have found it. `:Hover show` still runs the full resolver,
--- which is this plugin's standing answer for an expensive result: on
--- explicit request, never on a timer.
---@param token string
---@return boolean
local function gopath_can_help(token)
  if token:find("...", 1, true) or token:find("…", 1, true) then
    return true
  end
  return not token:find("[/\\]")
end

---@internal
--- The `<cfile>` token, resolved against the buffer's own directory first and
--- the cwd second — the same order `classify.resolve_path` uses for a link,
--- so a bare `./a.png` and a linked `./a.png` resolve identically.
---@param bufnr integer
---@return string|nil path raw target as written
---@return integer|nil line 1-based line the target named, if any
local function via_cfile(bufnr)
  local cfile = vim.fn.expand("<cfile>")
  if type(cfile) ~= "string" or cfile == "" then
    return nil
  end

  cfile = trim_delimiters(cfile)
  local path, location = split_location(cfile)
  if not looks_like_path(path) then
    return nil
  end
  -- `:42` and `:42:7` both yield 42; the column is not something a preview
  -- of twenty lines can use.
  local line = location and tonumber(location:match("^:(%d+)")) or nil

  local uv = vim.uv or vim.loop
  local expanded = vim.fn.expand(path)

  -- Absolute already: hand it back untouched.
  if expanded:match("^/") or expanded:match("^%a:[\\/]") or expanded:match("^[\\/][\\/]") then
    if uv.fs_stat(expanded) then
      return path, line
    end
    return nil
  end

  local bases = {}
  local name = api.nvim_buf_get_name(bufnr)
  if name ~= "" then
    bases[#bases + 1] = vim.fs.dirname(name)
  end
  bases[#bases + 1] = uv.cwd()

  for _, base in ipairs(bases) do
    if base and base ~= "" then
      if uv.fs_stat(base .. "/" .. expanded) then
        return path, line
      end
    end
  end
  return nil
end

--- Whether `str` can only have been meant as a path -- the test that decides
--- whether a *non-existent* target is worth a red mark.
---
--- Public for the spec suite. It is the most consequential single decision in
--- this plugin and the one whose regressions are hardest to notice through
--- the UI, so it is tested directly rather than through a live cursor.
---@param str string
---@return boolean
function M.is_unambiguous_path(str)
  return is_unambiguous_path(str)
end

--- A path under the cursor written without link syntax.
---
--- Returns a `Hover.Source`-shaped table so `hover` can treat it exactly
--- like a scanned link -- `target` is what `classify` receives.
---
--- `opts.missing` is the `:Hover paths missing` switch: with it off, text
--- that resolves to nothing is simply not a target, and no float opens at
--- all. The stricter `is_unambiguous_path` test still runs underneath it --
--- the switch turns the whole class off, it does not loosen the rule.
---
--- `opts.code` is the `:Hover paths code` switch, and like `opts.missing` it
--- is taken as the caller's word rather than read back out of the
--- configuration: **only an explicit `false` applies the gate.** `hover.show`
--- passes `config.paths_code_enabled()`, which is false by default, so in the
--- plugin the gate is on; a direct call to this function with no opts behaves
--- exactly as it did before the switch existed.
---
--- With the gate applied, a position Treesitter identifies as executable code
--- is not a target at all, which is what keeps `vim.api.foo` and `a / b` from
--- reaching the resolver. See `hover.scope` for what counts as code and for
--- the five ways it declines to decide.
---@param bufnr? integer
---@param opts? { missing?: boolean, code?: boolean, force?: boolean, trace?: table } `missing` and `code` default to true; `force` runs the full resolver; `trace`, when given, is filled with which gate refused.
---@return Hover.Source|nil
function M.under_cursor(bufnr, opts)
  opts = opts or {}
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

  -- Cheap gate before anything else: the cursor has to sit on non-blank text
  -- that could be part of a path at all. Without this, every CursorHold in
  -- prose would reach gopath's resolver pipeline.
  local trace = opts.trace

  local char = line:sub(col + 1, col + 1)
  if char == "" or char:match("%s") then
    if trace then
      trace.stopped_at = "blank"
    end
    return nil
  end

  local cfile = vim.fn.expand("<cfile>")
  local token = trim_delimiters(type(cfile) == "string" and cfile or "")
  if trace then
    trace.token = token
  end
  if not looks_like_path(token) then
    if trace then
      trace.stopped_at = "shape"
    end
    return nil
  end

  -- Second gate, and deliberately *after* the first rather than in front of
  -- it. In a source file a path is written in a comment or a string and never
  -- inside an expression, so a position identifiable as executable code is
  -- not a target. The order is the measured part: this gate costs ~90 us
  -- because answering means parsing, against ~1.1 us for the token gate
  -- above. It is affordable only because the token gate rejects 99.8% of
  -- cursor positions before it -- put first it would cost every CursorHold
  -- in every buffer. It fails open in every direction it can: see
  -- `hover.scope`.
  if opts.code == false and not require("hover.scope").allows_path(bufnr, row, col) then
    if trace then
      trace.stopped_at = "scope"
    end
    return nil
  end

  -- `<cfile>` first, gopath second, and only where gopath can contribute --
  -- see `gopath_can_help` for the measurements that decided the order. An
  -- explicit request gets the old order and the full pipeline: the cost is
  -- the point of asking.
  -- `target_line`, not `line`: `line` is already the buffer line's *text*
  -- above, and this is a line *number* the target named.
  local resolved, target_line
  if opts.force then
    resolved, target_line = via_gopath()
    if not resolved then
      resolved, target_line = via_cfile(bufnr)
    end
  else
    resolved, target_line = via_cfile(bufnr)
    if not resolved and gopath_can_help(token) then
      resolved, target_line = via_gopath()
    end
  end

  -- Nothing on disk. Worth reporting only when the text cannot have been
  -- anything but a path -- see `is_unambiguous_path`. `classify` then turns
  -- it into a `missing` target and the preview marks it with a red ✗, the
  -- same answer a broken *link* already gets.
  if not resolved then
    if opts.missing == false then
      if trace then
        trace.stopped_at = "missing_off"
      end
      return nil
    end
    -- Tested without the `:line[:col]` suffix: `docs/gone.md:42` is as
    -- unambiguously a path as `docs/gone.md`, but only one of the two ends
    -- in an extension, and that is what the test looks for.
    local path_token = (split_location(token))
    if not is_unambiguous_path(path_token) then
      if trace then
        trace.stopped_at = "ambiguous"
      end
      return nil
    end
    resolved = path_token
  end

  return {
    target = resolved,
    col = col,
    col_end = col,
    lnum = row,
    line = target_line,
    kind = "bare_path",
  }
end

return M
