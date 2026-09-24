---@diagnostic disable: need-check-nil
-- The test body is the guard; see the note in TESTS/bare_path_spec.lua
-- (`LLS-42`).

-- TESTS/text_spec.lua -- the plain-file preview, and the one distinction it
-- used to collapse: a file with nothing in it versus a file `io.open` could
-- not open at all (no permission, a FIFO, another process holding it
-- exclusively on Windows). Both used to hand back `{}, false, 0` out of
-- `head()`, so `M.file` rendered `(empty file, 1.2 MB)` for a file it never
-- actually read a byte of -- self-contradicting, since the size in that
-- message comes from the same `stat` that routed the hover here in the first
-- place (`ERR-11`).
--
-- `io.open` is monkey-patched rather than chmod'd: the failure-to-open case
-- must be provoked identically on Windows, macOS and Linux (all three of
-- this repo's CI runners), and permission semantics do not agree across
-- them -- a directory opened with `io.open("r")` alone already returns `nil`
-- on Windows but a valid, zero-byte-reading handle on Linux glibc.

local text = require("hover.preview.text")

describe("hover.preview.text.file", function()
  local root

  before_each(function()
    root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
  end)

  after_each(function()
    vim.fn.delete(root, "rf")
  end)

  it("reads an ordinary file's lines", function()
    local path = root .. "/plain.txt"
    vim.fn.writefile({ "one", "two", "three" }, path)
    local target = { type = "file", path = path, size = 11 }

    local content = text.file(target, {})

    assert.same({ "one", "two", "three" }, content.lines)
  end)

  it("says '(empty file, ...)' for a file that opened fine and has nothing in it", function()
    local path = root .. "/empty.txt"
    vim.fn.writefile({}, path)
    local target = { type = "file", path = path, size = 0 }

    local content = text.file(target, {})

    assert.equals(1, #content.lines)
    assert.is_truthy(content.lines[1]:find("empty file", 1, true))
  end)

  it("says '(cannot read file)', not '(empty file)', when io.open fails (ERR-11)", function()
    local path = root .. "/locked.txt"
    vim.fn.writefile({ "this would have been shown" }, path)
    -- The size the badge would have quoted if this had been misread as
    -- empty -- asserted absent below, so the fix is pinned rather than just
    -- "some other string came out".
    local target = { type = "file", path = path, size = 999999 }

    local real_open = io.open
    io.open = function(p, mode)
      if p == path then
        return nil
      end
      return real_open(p, mode)
    end

    local content
    assert.has_no.errors(function()
      content = text.file(target, {})
    end)

    io.open = real_open

    assert.equals(1, #content.lines)
    assert.is_truthy(content.lines[1]:find("cannot read file", 1, true))
    assert.is_falsy(
      content.lines[1]:find("empty file", 1, true),
      "an unreadable file was reported as an empty one"
    )
  end)

  it("does not cache an unreadable file's size into a confident-looking badge", function()
    -- `target.size` came from the same `stat` that routed the hover here;
    -- reusing it in the badge would have asserted a size for content nobody
    -- ever read.
    local path = root .. "/locked2.txt"
    vim.fn.writefile({ "x" }, path)
    local target = { type = "file", path = path, size = 12345 }

    local real_open = io.open
    io.open = function(p, mode)
      if p == path then
        return nil
      end
      return real_open(p, mode)
    end

    local content = text.file(target, {})

    io.open = real_open

    assert.is_falsy(content.lines[1]:find("12345", 1, true))
  end)
end)

describe("hover.preview.text.directory", function()
  local root

  before_each(function()
    root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
  end)

  after_each(function()
    vim.fn.delete(root, "rf")
  end)

  it("carries dir_entries alongside the rendered lines, index for index", function()
    vim.fn.mkdir(root .. "/child", "p")
    vim.fn.writefile({}, root .. "/leaf.txt")

    local content = text.directory({ type = "directory", path = root }, { max_lines = 20 })

    assert.same({ "child/", "leaf.txt" }, content.lines)
    assert.equals(2, #content.dir_entries)
    assert.equals("child", content.dir_entries[1].name)
    assert.is_true(content.dir_entries[1].is_dir)
    assert.equals("leaf.txt", content.dir_entries[2].name)
    assert.is_false(content.dir_entries[2].is_dir)
  end)

  it(
    "truncates dir_entries along with the lines, so a rendered line and its entry never drift apart",
    function()
      for i = 1, 5 do
        vim.fn.writefile({}, root .. ("/f%d.txt"):format(i))
      end

      local content = text.directory({ type = "directory", path = root }, { max_lines = 3 })

      assert.equals(3, #content.lines - 1) -- the summary line is not an entry
      assert.equals("… (5 entries)", content.lines[#content.lines])
      assert.equals(3, #content.dir_entries)
    end
  )

  it("carries no dir_entries for an empty directory", function()
    local content = text.directory({ type = "directory", path = root }, { max_lines = 20 })
    assert.same({ "(empty directory)" }, content.lines)
    assert.same({}, content.dir_entries)
  end)

  it("carries no dir_entries when the directory cannot be read at all", function()
    local content = text.directory(
      { type = "directory", path = root .. "/gone" },
      { max_lines = 20 }
    )
    assert.same({ "(cannot read directory)" }, content.lines)
    assert.is_nil(content.dir_entries)
  end)
end)
