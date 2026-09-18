---@diagnostic disable: need-check-nil, duplicate-set-field
-- The test body is the guard; see the note in TESTS/bare_path_spec.lua
-- (`LLS-42`).

-- TESTS/office_spec.lua -- converting an office document to a PDF page, the
-- cache that makes that cost one LibreOffice start per document rather than
-- one per hover, and the eviction that keeps it from growing forever.
--
-- This module had no spec at all before this file, despite exporting
-- `M.reset()` with a doc comment that says outright what it is for: "Tests,
-- and anything that wants the next hover to convert again." `pdfport.nvim`
-- and `hover.preview.media` are stubbed via `package.loaded` before
-- `require`, per this campaign's convention (a `require()` dependency binds
-- to an upvalue at load time; patching a table field afterward does
-- nothing) -- neither is installed in this test environment anyway, which is
-- itself part of what several cases here exercise honestly.

local office = require("hover.preview.office")

---@param root string
---@param name string
---@return string path
local function write_doc(root, name)
  local path = root .. "/" .. name
  vim.fn.writefile({ "not a real office document" }, path)
  return path
end

--- The exact cache path `hover.preview.office` would compute for `path`,
--- replicated here rather than asked of the module -- the point of this
--- fixture is the *cross-session* half of the cache, the same reasoning
--- `TESTS/webpdf_spec.lua`'s own `on_disk` helper documents.
---@param path string
---@return string
local function expected_output_path(path)
  local st = assert(vim.uv.fs_stat(path))
  local key = path .. " " .. tostring(st.mtime and st.mtime.sec or 0)
  local dir = vim.fn.stdpath("cache") .. "/hover.nvim/office"
  local stem = vim.fn.fnamemodify(path, ":t:r"):gsub("[^%w%-_]", "_")
  local digest = vim.fn.sha256(key):sub(1, 16)
  return ("%s/%s-%s.pdf"):format(dir, stem, digest)
end

describe("hover.preview.office.preview", function()
  local root, real_pdfport, real_media

  before_each(function()
    office.reset()
    root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    real_pdfport = package.loaded["pdfport"]
    real_media = package.loaded["hover.preview.media"]
    package.loaded["pdfport"] = nil
    package.loaded["hover.preview.media"] = {
      pdf = function(target)
        return { lines = { "PDF PAGE: " .. tostring(target.path) }, title = "pdfpage" }
      end,
    }
  end)

  after_each(function()
    office.reset()
    package.loaded["pdfport"] = real_pdfport
    package.loaded["hover.preview.media"] = real_media
    vim.fn.delete(root, "rf")
  end)

  it(
    "shows a badge naming the command, and converts nothing, when office_convert is off",
    function()
      local path = write_doc(root, "report.docx")
      local target = { type = "office", raw = path, path = path, ext = "docx", size = 1 }

      local content = office.preview(target, { office_convert = false }, function() end)

      local text = table.concat(content.lines, "\n")
      assert.is_truthy(text:find("no text preview", 1, true))
      assert.is_truthy(text:find(":Hover office on", 1, true))
      assert.is_nil(content.pending)
    end
  )

  it("shows '(file vanished)' when the source no longer exists", function()
    local target = {
      type = "office",
      raw = root .. "/gone.docx",
      path = root .. "/gone.docx",
      ext = "docx",
      size = 1,
    }

    local content = office.preview(target, { office_convert = true }, function() end)

    assert.is_truthy(table.concat(content.lines, "\n"):find("file vanished", 1, true))
  end)

  -- These two must run before any other test in this file that reaches a
  -- genuine cache miss: `sweep()` sets its own `_swept` module-local to
  -- `true` unconditionally on its first call, even when `days` is `nil` or
  -- invalid -- and every "not installed" / "cannot create" / "converts"
  -- test below reaches a miss too, since none of them ever answers from the
  -- cache. `_swept` is private and `M.reset()` does not touch it, so once it
  -- is true there is no way to observe a fresh sweep again in this process.
  it("sweeps a stale conversion once, on the first miss of the session", function()
    local stray = vim.fn.stdpath("cache") .. "/hover.nvim/office/stale-abc123.pdf"
    vim.fn.mkdir(vim.fn.fnamemodify(stray, ":h"), "p")
    vim.fn.writefile({ "old" }, stray)
    -- 10 days old; cache_days below is 1.
    local old = os.time() - 10 * 24 * 60 * 60
    vim.uv.fs_utime(stray, old, old)

    local path = write_doc(root, "report.docx")
    local target = { type = "office", raw = path, path = path, ext = "docx", size = 1 }
    package.loaded["pdfport"] = {
      can_create = function()
        return true
      end,
      create = function() end, -- never completes; sweep must already have run
    }

    office.preview(target, { office_convert = true, office_cache_days = 1 }, function() end)

    assert.is_nil(vim.uv.fs_stat(stray), "a conversion older than office_cache_days was kept")
  end)

  it("does not sweep a second time in the same session", function()
    local path1 = write_doc(root, "one.docx")
    local target1 = { type = "office", raw = path1, path = path1, ext = "docx", size = 1 }
    package.loaded["pdfport"] = {
      can_create = function()
        return true
      end,
      create = function() end,
    }
    -- Another miss: sweep no-ops on the `_swept` guard already set by the
    -- test above, regardless of order between these two specifically.
    office.preview(target1, { office_convert = true, office_cache_days = 1 }, function() end)

    local stray = vim.fn.stdpath("cache") .. "/hover.nvim/office/stale-after-sweep.pdf"
    vim.fn.writefile({ "old" }, stray)
    local old = os.time() - 10 * 24 * 60 * 60
    vim.uv.fs_utime(stray, old, old)

    local path2 = write_doc(root, "two.docx")
    local target2 = { type = "office", raw = path2, path = path2, ext = "docx", size = 1 }
    office.preview(target2, { office_convert = true, office_cache_days = 1 }, function() end)

    assert.is_not_nil(
      vim.uv.fs_stat(stray),
      "sweep ran a second time in the same session, past the module's own _swept guard"
    )
    vim.fn.delete(stray)
  end)

  it("says pdfport.nvim is not installed when it genuinely is not on this rtp", function()
    -- Not stubbed at all in this case -- pdfport is not one of this test
    -- environment's dependencies, so `pcall(require, "pdfport")` fails on
    -- its own, honestly.
    local path = write_doc(root, "report.docx")
    local target = { type = "office", raw = path, path = path, ext = "docx", size = 1 }

    local content = office.preview(target, { office_convert = true }, function() end)

    assert.is_truthy(table.concat(content.lines, "\n"):find("pdfport.nvim not installed", 1, true))
    assert.is_nil(content.pending)
  end)

  it("says LibreOffice is not on PATH when pdfport is present but cannot create", function()
    local path = write_doc(root, "report.docx")
    local target = { type = "office", raw = path, path = path, ext = "docx", size = 1 }
    package.loaded["pdfport"] = {
      create = function() end,
      can_create = function()
        return false
      end,
    }

    local content = office.preview(target, { office_convert = true }, function() end)

    assert.is_truthy(table.concat(content.lines, "\n"):find("LibreOffice not on PATH", 1, true))
  end)

  it(
    "converts once, marks the badge pending, then hands the rasterized page to on_result",
    function()
      local path = write_doc(root, "report.docx")
      local target = { type = "office", raw = path, path = path, ext = "docx", size = 1 }
      local output = expected_output_path(path)
      local create_calls = 0
      package.loaded["pdfport"] = {
        can_create = function()
          return true
        end,
        create = function(spec)
          create_calls = create_calls + 1
          assert.equals(path, spec.inputs[1])
          assert.equals("office", spec.from)
          spec.__callback({ status = "ok", path = output })
        end,
      }

      local result
      local pending = office.preview(target, { office_convert = true }, function(content)
        result = content
      end)

      assert.is_true(pending.pending)
      assert.is_truthy(table.concat(pending.lines, "\n"):find("converting to PDF", 1, true))

      vim.wait(500, function()
        return result ~= nil
      end, 10)

      assert.is_not_nil(result, "on_result was never called")
      assert.is_truthy(table.concat(result.lines, "\n"):find("PDF PAGE", 1, true))
      assert.equals(1, create_calls)
    end
  )

  it(
    "does not start a second conversion while one is already running for the same document",
    function()
      local path = write_doc(root, "report.docx")
      local target = { type = "office", raw = path, path = path, ext = "docx", size = 1 }
      local create_calls = 0
      package.loaded["pdfport"] = {
        can_create = function()
          return true
        end,
        create = function(spec)
          create_calls = create_calls + 1
          -- Deliberately never calls spec.__callback -- this conversion never
          -- finishes within the test, so `_running` stays set.
        end,
      }

      office.preview(target, { office_convert = true }, function() end)
      local second = office.preview(target, { office_convert = true }, function() end)

      assert.equals(1, create_calls, "a second conversion was started for the same document")
      assert.is_true(second.pending)
      assert.is_truthy(table.concat(second.lines, "\n"):find("converting to PDF", 1, true))
    end
  )

  it("serves the same document from the in-session cache without converting again", function()
    local path = write_doc(root, "report.docx")
    local target = { type = "office", raw = path, path = path, ext = "docx", size = 1 }
    local output = expected_output_path(path)
    local create_calls = 0
    package.loaded["pdfport"] = {
      can_create = function()
        return true
      end,
      create = function(spec)
        create_calls = create_calls + 1
        -- The in-session cache hit still checks `uv.fs_stat(pdf)` before
        -- trusting `_pdfs[key]` -- a stub that only claims success without
        -- writing anything is exactly the "temp sweeper took it" path, and
        -- would convert a second time for the wrong reason.
        vim.fn.writefile({ "%PDF-1.4 fixture" }, output)
        spec.__callback({ status = "ok", path = output })
      end,
    }

    local first_result
    office.preview(target, { office_convert = true }, function(content)
      first_result = content
    end)
    vim.wait(500, function()
      return first_result ~= nil
    end, 10)
    assert.is_not_nil(first_result)

    local second = office.preview(target, { office_convert = true }, function() end)

    assert.equals(1, create_calls, "the second hover converted the document again")
    assert.is_nil(second.pending)
    assert.is_truthy(table.concat(second.lines, "\n"):find("PDF PAGE", 1, true))
  end)

  it("finds a conversion an earlier session left on disk, converting nothing", function()
    local path = write_doc(root, "report.docx")
    local target = { type = "office", raw = path, path = path, ext = "docx", size = 1 }
    local output = expected_output_path(path)
    vim.fn.mkdir(vim.fn.fnamemodify(output, ":h"), "p")
    vim.fn.writefile({ "%PDF-1.4 fixture" }, output)

    local create_calls = 0
    package.loaded["pdfport"] = {
      can_create = function()
        return true
      end,
      create = function(spec)
        create_calls = create_calls + 1
        spec.__callback({ status = "ok", path = output })
      end,
    }

    local content = office.preview(target, { office_convert = true }, function() end)

    assert.equals(0, create_calls, "a cross-session hit was converted again")
    assert.is_nil(content.pending)
    assert.is_truthy(table.concat(content.lines, "\n"):find("PDF PAGE", 1, true))

    vim.fn.delete(output)
  end)

  it(
    "reports a conversion failure through on_result rather than leaving the badge pending forever",
    function()
      local path = write_doc(root, "report.docx")
      local target = { type = "office", raw = path, path = path, ext = "docx", size = 1 }
      package.loaded["pdfport"] = {
        can_create = function()
          return true
        end,
        create = function(spec)
          spec.__callback({ status = "error", error = "soffice timed out" })
        end,
      }

      local result
      office.preview(target, { office_convert = true }, function(content)
        result = content
      end)
      vim.wait(500, function()
        return result ~= nil
      end, 10)

      assert.is_not_nil(result)
      assert.is_truthy(table.concat(result.lines, "\n"):find("conversion failed", 1, true))
      assert.is_truthy(table.concat(result.lines, "\n"):find("soffice timed out", 1, true))
    end
  )
end)

describe("hover.preview.office.reset", function()
  it(
    "removes a converted PDF from disk and forgets it, so the next hover converts again",
    function()
      office.reset()
      local root = vim.fn.tempname()
      vim.fn.mkdir(root, "p")
      local path = write_doc(root, "report.docx")
      local target = { type = "office", raw = path, path = path, ext = "docx", size = 1 }
      local output = expected_output_path(path)

      local real_pdfport = package.loaded["pdfport"]
      local real_media = package.loaded["hover.preview.media"]
      local create_calls = 0
      package.loaded["pdfport"] = {
        can_create = function()
          return true
        end,
        create = function(spec)
          create_calls = create_calls + 1
          vim.fn.writefile({ "%PDF-1.4 fixture" }, output)
          spec.__callback({ status = "ok", path = output })
        end,
      }
      package.loaded["hover.preview.media"] = {
        pdf = function()
          return { lines = { "page" } }
        end,
      }

      local result
      office.preview(target, { office_convert = true }, function(content)
        result = content
      end)
      vim.wait(500, function()
        return result ~= nil
      end, 10)
      assert.is_not_nil(result)
      assert.is_not_nil(vim.uv.fs_stat(output), "the conversion was never actually written")

      office.reset()

      assert.is_nil(vim.uv.fs_stat(output), "reset() left the converted PDF on disk")

      local second = office.preview(target, { office_convert = true }, function() end)
      assert.equals(2, create_calls, "reset() did not make the next hover convert again")
      assert.is_true(second.pending)

      package.loaded["pdfport"] = real_pdfport
      package.loaded["hover.preview.media"] = real_media
      office.reset()
      vim.fn.delete(root, "rf")
    end
  )
end)
