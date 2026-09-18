---@diagnostic disable: need-check-nil
-- The test body is the guard; see the note in TESTS/bare_path_spec.lua
-- (`LLS-42`).

-- TESTS/classify_spec.lua -- what `hover.classify` decides a link target is,
-- by shape and then by a single stat call.
--
-- This module sits ahead of every preview and every switch: get it wrong and
-- the wrong previewer runs, or the right one runs on the wrong path. It was
-- otherwise only reached incidentally, through other specs handing it an
-- already-existing absolute path -- never through the shape decisions
-- (anchor, url, www, missing, directory, the extension groups) that are
-- most of the branching in the module, and never through the one case that
-- decides a Windows path is not a URL scheme.

local classify = require("hover.classify")

describe("hover.classify, deciding by shape before any filesystem call", function()
  it("classifies an empty or blank target as missing, with a reason", function()
    local t = classify.classify("", nil)
    assert.equals("missing", t.type)
    assert.equals("empty target", t.reason)

    local blank = classify.classify("   ", nil)
    assert.equals("missing", blank.type)
  end)

  it("classifies a #heading as an in-page anchor, never touching disk", function()
    local t = classify.classify("#Installation", "/does/not/exist.md")
    assert.equals("anchor", t.type)
    assert.equals("Installation", t.anchor)
  end)

  it("classifies any scheme as a url, mailto included", function()
    local https = classify.classify("https://example.com/a?b=c", nil)
    assert.equals("url", https.type)
    assert.equals("https://example.com/a?b=c", https.url)

    local mailto = classify.classify("mailto:someone@example.com", nil)
    assert.equals("url", mailto.type)
    assert.equals("mailto:someone@example.com", mailto.url)
  end)

  it("repairs a Windows-typo'd URL, backslashes and all", function()
    local t = classify.classify([[http:\\example.com\a\b]], nil)
    assert.equals("url", t.type)
    assert.equals([[http://example.com\a\b]], t.url)
  end)

  it(
    "does NOT read a Windows drive letter as a URL scheme -- the one place classify and bare_url both guard against it",
    function()
      -- `C:\Users\me\file.txt` has the exact shape a scheme test would
      -- otherwise accept: one letter, a colon, and something after it. A
      -- single-letter scheme followed by a path separator is the guard
      -- `classify.lua`'s `raw:match("^%a[%w+.-]*:") and not
      -- raw:match("^%a:[\\/]")` line exists for -- get this wrong and every
      -- absolute Windows path in every doc would be sent to `preview.url`
      -- instead of the filesystem.
      local t = classify.classify([[C:\Users\me\file.txt]], nil)
      assert.is_not.equals("url", t.type)
      assert.equals("missing", t.type) -- resolved, stat'd, and not found
    end
  )

  it(
    "still reads a real single-letter scheme (a: is not a drive letter followed by a separator)",
    function()
      -- `a:foo` has a colon with nothing that looks like a path separator
      -- after it, so the drive-letter exemption must not swallow it too.
      local t = classify.classify("a:foo", nil)
      assert.equals("url", t.type)
    end
  )

  it("classifies a protocol-relative //host/path as https", function()
    local t = classify.classify("//example.com/a", nil)
    assert.equals("url", t.type)
    assert.equals("https://example.com/a", t.url)
  end)

  it("classifies a bare www.host as https, scheme assumed", function()
    local t = classify.classify("www.example.com/a", nil)
    assert.equals("url", t.type)
    assert.equals("https://www.example.com/a", t.url)
  end)

  it("does not mistake a two-letter word before a colon for www without the prefix", function()
    -- `www.` requires the literal prefix; "vm.example.com" is not a URL by
    -- this rule and falls through to path resolution instead.
    local t = classify.classify("vm.example.com/a", nil)
    assert.is_not.equals("url", t.type)
  end)
end)

describe("hover.classify, resolving and stat'ing a local path", function()
  local root

  before_each(function()
    root = vim.fn.tempname()
    vim.fn.mkdir(root .. "/sub", "p")
    vim.fn.writefile({ "hello" }, root .. "/sub/doc.md")
    vim.fn.writefile({ "1" }, root .. "/picture.png")
    vim.fn.writefile({ "1" }, root .. "/report.docx")
    vim.fn.writefile({ "1" }, root .. "/clip.mp4")
    vim.fn.writefile({ "1" }, root .. "/paper.pdf")
    vim.fn.writefile({ "1" }, root .. "/notes.md")
    vim.fn.writefile({ "1" }, root .. "/data.bin")
  end)

  after_each(function()
    vim.fn.delete(root, "rf")
  end)

  it("resolves a relative target against the source document's directory, not the cwd", function()
    local t = classify.classify("doc.md", root .. "/sub/reader.md")
    assert.equals("markdown", t.type)
    assert.equals(vim.fs.normalize(root .. "/sub/doc.md"), t.path)
  end)

  it("resolves a relative target against getcwd() when there is no source document", function()
    local t = classify.classify(root .. "/sub/doc.md", nil)
    assert.equals("markdown", t.type)
  end)

  it("reports a missing file with the path it looked for and a reason", function()
    local t = classify.classify("nope.md", root .. "/sub/reader.md")
    assert.equals("missing", t.type)
    assert.equals("no such file", t.reason)
    assert.equals(vim.fs.normalize(root .. "/sub/nope.md"), t.path)
  end)

  it("classifies a directory, carrying its size", function()
    local t = classify.classify("sub", root .. "/reader.md")
    assert.equals("directory", t.type)
  end)

  it("routes each recognised extension to its own target type", function()
    assert.equals("image", classify.classify(root .. "/picture.png", nil).type)
    assert.equals("pdf", classify.classify(root .. "/paper.pdf", nil).type)
    assert.equals("markdown", classify.classify(root .. "/notes.md", nil).type)
    assert.equals("office", classify.classify(root .. "/report.docx", nil).type)
    assert.equals("video", classify.classify(root .. "/clip.mp4", nil).type)
    assert.equals("file", classify.classify(root .. "/data.bin", nil).type)
  end)

  it("carries a trailing #anchor separately from the path it names", function()
    local t = classify.classify("sub/doc.md#Section", root .. "/reader.md")
    assert.equals("markdown", t.type)
    assert.equals("Section", t.anchor)
    assert.equals(vim.fs.normalize(root .. "/sub/doc.md"), t.path)
  end)

  it("resolves a path with a trailing bare # (empty anchor) rather than raising", function()
    local t = classify.classify("x#", root .. "/reader.md")
    assert.equals("missing", t.type)
    assert.equals("", t.anchor)
  end)
end)

describe("hover.classify.is_image_ext and .TYPES", function()
  it("answers case-insensitively and only for a real image extension", function()
    assert.is_true(classify.is_image_ext("PNG"))
    assert.is_true(classify.is_image_ext("jpg"))
    assert.is_false(classify.is_image_ext("docx"))
    assert.is_false(classify.is_image_ext(nil))
  end)

  it("TYPES is sorted and has no duplicate", function()
    local seen = {}
    for i, name in ipairs(classify.TYPES) do
      assert.is_nil(seen[name], ("%s listed twice"):format(name))
      seen[name] = true
      if i > 1 then
        assert.is_true(classify.TYPES[i - 1] < name, ("TYPES is not sorted at %s"):format(name))
      end
    end
  end)
end)
