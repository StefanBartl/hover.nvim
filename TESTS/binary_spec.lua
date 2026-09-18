---@diagnostic disable: need-check-nil
-- The test body is the guard; see the note in TESTS/bare_path_spec.lua
-- (`LLS-42`).

-- TESTS/binary_spec.lua -- the honest answer for a file whose bytes are not
-- text, and the byte test that decides it.
--
-- This module exists because of a real symptom (a `.docx` shown as mojibake
-- with the document's name in the border) and its whole design is "test the
-- bytes, not a list of extensions someone thought of" -- which makes
-- `is_binary` the one function in this plugin where getting the threshold
-- wrong is invisible until a real file trips it. It had no spec before this
-- file.

local binary = require("hover.preview.binary")

describe("hover.preview.binary.is_binary", function()
  local root

  before_each(function()
    root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
  end)

  after_each(function()
    vim.fn.delete(root, "rf")
  end)

  ---@param name string
  ---@param bytes string written as-is, in binary mode
  ---@return string path
  local function write(name, bytes)
    local path = root .. "/" .. name
    local fd = assert(io.open(path, "wb"))
    fd:write(bytes)
    fd:close()
    return path
  end

  it("is false for ordinary prose", function()
    local path = write("prose.txt", "Hello, this is just a line of text.\nAnd another.\n")
    assert.is_false(binary.is_binary(path))
  end)

  it("is true the moment a NUL byte appears in the sample", function()
    local path = write("nul.bin", "abc\0def")
    assert.is_true(binary.is_binary(path))
  end)

  it("is true for a high ratio of other control bytes, even with no NUL at all", function()
    -- Every one of these is below 0x20 and none is tab/LF/VT/FF/CR, so all
    -- of them count -- comfortably over CONTROL_RATIO with no NUL in sight.
    local control = string.char(1, 2, 3, 4, 5, 6, 7, 11, 14, 16)
    local path = write("control.bin", control .. control .. control .. control)
    assert.is_true(binary.is_binary(path))
  end)

  it("is false for a file that is only tab, newline, CR and form-feed", function()
    -- These five are explicitly exempted (9-13): a text file with a CRLF
    -- ending and the odd form-feed page break must not be called binary.
    local path = write("whitespace.txt", "a\tb\r\nc\fd\r\n")
    assert.is_false(binary.is_binary(path))
  end)

  it("is false right at the ratio boundary, and true just past it", function()
    -- 10% of a 100-byte sample is 10 control bytes. The test is a strict
    -- `>`, so exactly the threshold must still read as text.
    local exactly_ten_pct = string.rep("a", 90) .. string.rep("\1", 10)
    local path = write("boundary.bin", exactly_ten_pct)
    assert.is_false(binary.is_binary(path), "exactly CONTROL_RATIO must not trip the gate")

    local just_over = string.rep("a", 89) .. string.rep("\1", 11)
    local path2 = write("boundary2.bin", just_over)
    assert.is_true(binary.is_binary(path2), "just past CONTROL_RATIO must trip the gate")
  end)

  it("is false for an empty file -- nothing to misinterpret", function()
    local path = write("empty.bin", "")
    assert.is_false(binary.is_binary(path))
  end)

  it("is false for a file that does not exist", function()
    assert.is_false(binary.is_binary(root .. "/does-not-exist.bin"))
  end)

  it("only reads the declared sample size, not the whole file", function()
    -- A file that is all NUL past the sample window must not be reported as
    -- binary from its tail: only the head decides, cheaply, on a large file.
    local huge = string.rep("a", 5000) .. string.rep("\0", 5000)
    local path = write("huge.bin", huge)
    -- The first 4096 bytes are plain "a" -- no NUL in the sample -- so this
    -- must read as text despite the file being unambiguously binary later.
    assert.is_false(binary.is_binary(path))
  end)
end)

describe("hover.preview.binary.badge", function()
  it("names the format, the extension and a human size", function()
    local content = binary.badge({ path = "/x/report.docx", ext = "docx", size = 2048 })
    assert.equals("report.docx", content.title)
    local text = table.concat(content.lines, "\n")
    assert.is_truthy(text:find("Word document", 1, true))
    assert.is_truthy(text:find("DOCX", 1, true))
  end)

  it("falls back to a generic 'binary file' label for an unrecognised extension", function()
    local content = binary.badge({ path = "/x/mystery.qzx", ext = "qzx", size = 10 })
    assert.is_truthy(table.concat(content.lines, "\n"):find("binary file", 1, true))
  end)

  it("falls back to a plain byte count when lib.lua.strings.format is unavailable", function()
    local had = package.loaded["lib.lua.strings.format"]
    package.loaded["lib.lua.strings.format"] = nil
    local prev_preload = package.preload["lib.lua.strings.format"]
    package.preload["lib.lua.strings.format"] = function()
      error("stubbed missing for a test")
    end

    local content = binary.badge({ path = "/x/data.bin", ext = "bin", size = 42 })

    package.preload["lib.lua.strings.format"] = prev_preload
    package.loaded["lib.lua.strings.format"] = had

    assert.is_truthy(table.concat(content.lines, "\n"):find("42 B", 1, true))
  end)

  it("shows '?' for a size that was never known", function()
    local content = binary.badge({ path = "/x/data.bin", ext = "bin" })
    assert.is_truthy(table.concat(content.lines, "\n"):find("?", 1, true))
  end)

  it("appends the note when one is given, and omits the line when there is none", function()
    local with_note = binary.badge(
      { path = "/x/r.docx", ext = "docx", size = 1 },
      { note = "hint here" }
    )
    assert.equals("hint here", with_note.lines[#with_note.lines])

    local without = binary.badge({ path = "/x/r.docx", ext = "docx", size = 1 })
    for _, line in ipairs(without.lines) do
      assert.is_not.equals("hint here", line)
    end
  end)

  it("uses HoverInfo, not an error colour -- the file is fine, just unreadable as text", function()
    local content = binary.badge({ path = "/x/r.docx", ext = "docx", size = 1 })
    assert.equals("HoverInfo", content.highlight)
  end)

  it("takes an explicit label over the extension-derived one", function()
    local content = binary.badge(
      { path = "/x/r.docx", ext = "docx", size = 1 },
      { label = "custom label" }
    )
    assert.is_truthy(table.concat(content.lines, "\n"):find("custom label", 1, true))
  end)
end)
