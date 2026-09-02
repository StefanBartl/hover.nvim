---@diagnostic disable: need-check-nil
-- The test body *is* the guard: a spec that has to nil-check every expression
-- before asserting on it cements noise rather than catching anything, and the
-- assertion is what reports the nil in the first place (`LLS-42`). A
-- `TESTS/.luarc.json` cannot express this -- LuaLS reads only the one in the
-- repository root.

-- TESTS/bare_path_spec.lua -- what text on a line may open a hover, and --
-- the part that actually goes wrong -- what a *non-existent* target may be
-- reported as broken.
--
-- The rule is "a missing path is reported only when it cannot have been
-- anything else". Getting it wrong is not a quiet bug: a false positive is a
-- red float asserting a file is missing that nobody ever claimed existed,
-- over ordinary prose.
--
-- The rule has been wrong twice, in two different directions, and both
-- regressions are pinned below:
--
--   1. a separator alone (`and/or`, `sortiert/`, `60% / 27%`)
--   2. three or more components (`2026/09/01`, `TODO/FIXME/DONE`), and an
--      extension on any component rather than the last (`github.com/u/repo`)
--
-- Two layers are exercised deliberately. `is_unambiguous_path` is tested
-- directly, because it is one pure function and the case list is the point.
-- `under_cursor` is driven through a real window, cursor and `<cfile>`,
-- because `<cfile>` is half the logic: what counts as one token is
-- `'isfname'`, pinned here so the same line yields the same token on every
-- platform.

local bare = require("hover.bare_path")

describe("bare_path.is_unambiguous_path", function()
  describe("stays silent on text prose actually writes", function()
    -- Regression 1: a separator is not evidence. Every one of these opened a
    -- confident "no such file" for a directory nobody named.
    local prose = {
      ["and/or"] = "prose writes an alternative, not a directory",
      ["input/output"] = "so is a two-word pair",
      ["Actual/Insgesamt"] = "a two-word table header",
      ["sortiert/"] = "a word with a trailing slash is still one word",

      -- Regression 2: nor is a component count. Prose writes three-deep
      -- alternatives constantly.
      ["2026/09/01"] = "a date in slash notation",
      ["TODO/FIXME/DONE"] = "a list of markers",
      ["read/write/execute"] = "a permission triple",
      ["key/value/pair"] = "a three-word noun phrase",
      ["a/b/c"] = "the generic placeholder",

      -- Regression 2, second half: an extension has to be on the component
      -- the path points *at*. `.com` is on the first one.
      ["github.com/user/repo"] = "a repository slug is not a file",

      -- Extension-less imports. Half the languages there are spell a module
      -- reference exactly like this, and it resolves through a resolver this
      -- plugin does not have.
      ["./components/Button"] = "a JavaScript import",
      ["../lib/utils"] = "...and a relative one",

      -- Predates all of it, restated so a future loosening cannot quietly
      -- take it along: a bare `name.ext` is how every Lua module is spelled.
      ["vim.api"] = "a bare name.ext is an identifier",
      ["README.md"] = "one component is one word, extension or not",

      -- Real paths that simply do not exist here. Silence is the deliberate
      -- price of the tightened rule, not an oversight.
      ["~/notes"] = "a home-relative path with no extension",
      ["/etc/hosts"] = "a rooted path with no extension",
      ["lua/lib/nvim"] = "a directory-shaped path with no extension",
    }
    for text, why in pairs(prose) do
      it(("is silent on %q -- %s"):format(text, why), function()
        assert.is_false(bare.is_unambiguous_path(text))
      end)
    end
  end)

  describe("still marks text that only a path is spelled as", function()
    local paths = {
      ["docs/gone.md"] = "an extension on the last component",
      ["./src/app.ts"] = "...with an explicit relative prefix",
      ["../docs/BINDINGS.md"] = "...or a parent one",
      ["...nvim/init.lua"] = "a truncation",
      ["C:\\Users\\x"] = "a drive prefix",
      ["\\\\server\\share"] = "a UNC prefix",
    }
    for text, why in pairs(paths) do
      it(("marks %q -- %s"):format(text, why), function()
        assert.is_true(bare.is_unambiguous_path(text))
      end)
    end
  end)

  it("rejects punctuation with no name in it", function()
    -- `<cfile>` reads `/` and `/--%` out of a table of ratios and dashes.
    assert.is_false(bare.is_unambiguous_path("/"))
    assert.is_false(bare.is_unambiguous_path("/--%"))
    assert.is_false(bare.is_unambiguous_path(""))
  end)
end)

describe("bare_path.under_cursor", function()
  local api = vim.api
  local root, win, prev_buf, prev_isfname, buf

  before_each(function()
    -- A directory that really exists, so the "resolved" case is a real stat
    -- rather than a fixture pretending to be one.
    root = vim.fn.tempname()
    vim.fn.mkdir(root .. "/docs", "p")
    vim.fn.writefile({ "# real" }, root .. "/docs/real.md")

    win = api.nvim_get_current_win()
    prev_buf = api.nvim_win_get_buf(win)
    prev_isfname = vim.o.isfname
    vim.o.isfname = "@,48-57,/,.,-,_,+,,,#,$,%,~,=,:"

    buf = api.nvim_create_buf(false, true)
    api.nvim_buf_set_name(buf, root .. "/notes.md")
    api.nvim_win_set_buf(win, buf)
  end)

  after_each(function()
    pcall(api.nvim_win_set_buf, win, prev_buf)
    pcall(api.nvim_buf_delete, buf, { force = true })
    vim.o.isfname = prev_isfname
    vim.fn.delete(root, "rf")
  end)

  --- The target reported with the cursor parked on `marker` inside `line`.
  ---@param line string
  ---@param marker string substring of `line` to put the cursor on
  ---@param opts? table forwarded to `under_cursor`
  ---@return string|nil
  local function target(line, marker, opts)
    api.nvim_buf_set_lines(buf, 0, -1, false, { line })
    local at = line:find(marker, 1, true)
    assert.is_truthy(at, ("marker %q is in %q"):format(marker, line))
    api.nvim_win_set_cursor(win, { 1, at - 1 })
    local src = bare.under_cursor(buf, opts)
    return src and src.target or nil
  end

  it("reports a path that resolves", function()
    assert.equals("./docs/real.md", target("see ./docs/real.md ok", "./docs"))
  end)

  it("reports a broken path that could not have been anything else", function()
    assert.equals("./docs/gone.md", target("see ./docs/gone.md for it", "./docs"))
    assert.equals("docs/gone.md", target("see docs/gone.md for it", "docs/"))
  end)

  it("splits a :line suffix off the path but keeps the target", function()
    -- The suffix is display, not path: it must not be the reason a real path
    -- fails the test, and it must not survive into what `classify` stats.
    assert.equals("docs/gone.md", target("boom at docs/gone.md:42 ok", "docs/gone"))
  end)

  it("stays silent on prose carrying a separator", function()
    assert.is_nil(target("wenn man zb sortiert/ schreibt", "sortiert/"))
    assert.is_nil(target("| 60% / 27% |", "/ 2"))
    assert.is_nil(target("use and/or here", "and/or"))
  end)

  it("stays silent on a three-component phrase that is not a path", function()
    -- The case the old "three or more components" rule marked as broken.
    assert.is_nil(target("shipped 2026/09/01 finally", "2026/"))
    assert.is_nil(target("tagged TODO/FIXME/DONE here", "TODO/"))
  end)

  it("stays silent on an extension-less relative import", function()
    assert.is_nil(target('import x from "./components/Button"', "./components"))
  end)

  it("honours opts.missing = false by reporting nothing at all", function()
    -- The switch turns the class off; it does not loosen the rule. A target
    -- that resolves is unaffected either way.
    assert.is_nil(target("see ./docs/gone.md for it", "./docs", { missing = false }))
    assert.equals("./docs/real.md", target("see ./docs/real.md ok", "./docs", { missing = false }))
  end)

  it("ignores a position that is not on text", function()
    assert.is_nil(target("word    tail", "    "))
  end)
end)

-- `init.lua:42` out of a log or a stack trace. Two separate things had to
-- change for this: the line number was extracted by `split_location` and then
-- discarded at both call sites, and the text preview started at the top
-- regardless. Neither is visible from the outside except as "the wrong twenty
-- lines".
describe("bare_path, a target that names a line", function()
  local api = vim.api
  local bare = require("hover.bare_path")
  local text = require("hover.preview.text")
  local classify = require("hover.classify")
  local root, win, prev_buf, prev_isfname, buf

  before_each(function()
    root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    -- Sixty numbered lines, so which window was picked is unambiguous.
    local body = {}
    for i = 1, 60 do
      body[i] = ("line %d"):format(i)
    end
    vim.fn.writefile(body, root .. "/big.txt")

    win = api.nvim_get_current_win()
    prev_buf = api.nvim_win_get_buf(win)
    prev_isfname = vim.o.isfname
    vim.o.isfname = "@,48-57,/,.,-,_,+,,,#,$,%,~,=,:"

    buf = api.nvim_create_buf(false, true)
    api.nvim_buf_set_name(buf, root .. "/notes.md")
    api.nvim_win_set_buf(win, buf)
  end)

  after_each(function()
    pcall(api.nvim_win_set_buf, win, prev_buf)
    pcall(api.nvim_buf_delete, buf, { force = true })
    vim.o.isfname = prev_isfname
    vim.fn.delete(root, "rf")
  end)

  ---@param line string
  ---@param marker string
  ---@return Hover.Source|nil
  local function source_for(line, marker)
    api.nvim_buf_set_lines(buf, 0, -1, false, { line })
    local at = line:find(marker, 1, true)
    api.nvim_win_set_cursor(win, { 1, at - 1 })
    return bare.under_cursor(buf, { missing = true, code = false })
  end

  it("carries the line number instead of discarding it", function()
    local src = source_for("at ./big.txt:42 it breaks", "./big.txt")
    assert.equals("./big.txt", src.target)
    assert.equals(42, src.line)
  end)

  it("reads a :line:col suffix as the line, ignoring the column", function()
    local src = source_for("at ./big.txt:42:7 it breaks", "./big.txt")
    assert.equals(42, src.line)
  end)

  it("leaves the line nil when the target names none", function()
    local src = source_for("see ./big.txt for it", "./big.txt")
    assert.is_nil(src.line)
  end)

  it("previews the named line, with a few lines of lead-in", function()
    local target = classify.classify(root .. "/big.txt", root .. "/notes.md")
    local content = text.file(target, { max_lines = 10, line = 42 })
    -- Line 42 has to be in the window, and not as its first line: context
    -- above is what makes it placeable.
    local body = table.concat(content.lines, "\n")
    assert.is_truthy(body:find("line 42", 1, true))
    assert.is_not.equals("line 42", content.lines[1])
    assert.is_truthy(content.title:find(":42", 1, true))
  end)

  it("starts at the top when no line was named", function()
    local target = classify.classify(root .. "/big.txt", root .. "/notes.md")
    local content = text.file(target, { max_lines = 10 })
    assert.equals("line 1", content.lines[1])
  end)

  it("lets an explicit scroll offset win over the named line", function()
    -- Once the reader has scrolled, the line they asked about must not drag
    -- them back to it on the next render.
    local target = classify.classify(root .. "/big.txt", root .. "/notes.md")
    local content = text.file(target, { max_lines = 10, line = 42, offset = 0 })
    assert.is_truthy(table.concat(content.lines, "\n"):find("line 42", 1, true))
    local scrolled = text.file(target, { max_lines = 10, line = 42, offset = 5 })
    assert.equals("line 6", scrolled.lines[1])
  end)

  it("does not run off the top for a line near the start", function()
    local target = classify.classify(root .. "/big.txt", root .. "/notes.md")
    local content = text.file(target, { max_lines = 10, line = 2 })
    assert.equals("line 1", content.lines[1])
  end)
end)

-- When gopath is asked, and when it is not. This is the 13-millisecond
-- problem, pinned: gopath answers everything it can answer in under 500 us
-- and *fails* in 1.4 ms for a bare name and 12.7 ms for a token with a
-- separator. A log, a diff or a stack trace is full of the second kind, and
-- it was being paid on every trigger.
--
-- gopath is stubbed through `package.loaded` rather than measured, because
-- "was it asked" is the property that matters and a timing assertion in a
-- spec is a flaky test waiting to happen.
describe("bare_path, when gopath is asked at all", function()
  local api = vim.api
  local bare = require("hover.bare_path")
  local root, win, prev_buf, prev_isfname, buf, real_gopath, asked

  before_each(function()
    root = vim.fn.tempname()
    vim.fn.mkdir(root .. "/docs", "p")
    vim.fn.writefile({ "# real" }, root .. "/docs/real.md")

    win = api.nvim_get_current_win()
    prev_buf = api.nvim_win_get_buf(win)
    prev_isfname = vim.o.isfname
    vim.o.isfname = "@,48-57,/,.,-,_,+,,,#,$,%,~,=,:"

    buf = api.nvim_create_buf(false, true)
    api.nvim_buf_set_name(buf, root .. "/notes.md")
    api.nvim_win_set_buf(win, buf)

    asked = 0
    real_gopath = package.loaded["gopath.resolve"]
    package.loaded["gopath.resolve"] = {
      resolve_at_cursor = function()
        asked = asked + 1
        return nil
      end,
    }
  end)

  after_each(function()
    package.loaded["gopath.resolve"] = real_gopath
    pcall(api.nvim_win_set_buf, win, prev_buf)
    pcall(api.nvim_buf_delete, buf, { force = true })
    vim.o.isfname = prev_isfname
    vim.fn.delete(root, "rf")
  end)

  ---@param line string
  ---@param marker string
  ---@param opts table|nil
  local function resolve(line, marker, opts)
    api.nvim_buf_set_lines(buf, 0, -1, false, { line })
    local at = line:find(marker, 1, true)
    api.nvim_win_set_cursor(win, { 1, at - 1 })
    return bare.under_cursor(
      buf,
      vim.tbl_extend("force", { missing = true, code = false }, opts or {})
    )
  end

  it("does not ask for a separator token that does not resolve", function()
    -- The expensive case: `<cfile>` already failed against the buffer's
    -- directory and the cwd, and gopath can only fail too -- for 12.7 ms.
    resolve("see docs/nope-not-here.md ok", "docs/nope")
    assert.equals(0, asked)
  end)

  it("does not ask for a path that already resolved", function()
    local src = resolve("see ./docs/real.md ok", "./docs")
    assert.equals("./docs/real.md", src.target)
    assert.equals(0, asked)
  end)

  it("asks for a truncated path, which is its whole subject matter", function()
    resolve("at ...somewhere/init.lua:42 it broke", "...somewhere")
    assert.equals(1, asked)
  end)

  it("asks for a bare name, which is the &path/rtp case", function()
    resolve("in someplace.lua somewhere", "someplace.lua")
    assert.equals(1, asked)
  end)

  it("asks for everything once the request is explicit", function()
    -- `:Hover show` gets the full pipeline: the cost is the point of asking.
    resolve("see docs/nope-not-here.md ok", "docs/nope", { force = true })
    assert.equals(1, asked)
  end)
end)
