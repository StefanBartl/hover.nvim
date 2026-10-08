---@diagnostic disable: need-check-nil
-- The test body is the guard; see the note in TESTS/bare_path_spec.lua
-- (`LLS-42`).

-- TESTS/preview_target_spec.lua -- `hover.preview_target`, the entry for other
-- plugins (ui.slots asks it what an address or a path stands for).
--
-- What is pinned: the callback runs exactly once; a cancelled request never
-- reaches its callback; an address is fetched only when the setting or the
-- caller says so (a preview is a request to that host); a failing previewer
-- becomes an answer, not an error. The network is a stand-in: no request is
-- made by this suite.

local hover = require("hover")

describe("hover.preview_target", function()
  local saved_curl, requests, dir

  ---@param target string
  ---@param opts? table
  ---@return Hover.Content[] answers
  ---@return table handle
  local function ask(target, opts)
    local answers = {}
    local handle = hover.preview_target(target, function(content)
      answers[#answers + 1] = content
    end, opts)
    return answers, handle
  end

  ---@param answers Hover.Content[]
  local function settle(answers)
    vim.wait(500, function()
      return #answers > 0
    end, 5)
  end

  before_each(function()
    requests = 0
    saved_curl = package.loaded["lib.nvim.net.curl"]
    package.loaded["lib.nvim.net.curl"] = {
      fetch_raw = function(_, _, callback)
        requests = requests + 1
        callback(true, {
          status = 200,
          status_text = "OK",
          headers = { ["content-type"] = "text/html" },
          body = "<html><head><title>Hello page</title></head><body><p>Body text.</p></body></html>",
        })
      end,
    }
    require("hover.preview.url").reset()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
  end)

  after_each(function()
    package.loaded["lib.nvim.net.curl"] = saved_curl
    require("hover.preview.url").reset()
    vim.fn.delete(dir, "rf")
  end)

  describe("a local target", function()
    it("answers with the lines of a file, once", function()
      local path = dir .. "/a.lua"
      vim.fn.writefile({ "local a = 1", "return a" }, path)
      local answers = ask(path)
      assert.equals(1, #answers)
      assert.same({ "local a = 1", "return a" }, answers[1].lines)
    end)

    it("starts at the line asked for", function()
      local path = dir .. "/many.txt"
      local lines = {}
      for i = 1, 100 do
        lines[i] = "line " .. i
      end
      vim.fn.writefile(lines, path)
      local answers = ask(path, { line = 50, max_lines = 5 })
      assert.is_truthy(vim.tbl_contains(answers[1].lines, "line 50"))
    end)

    it("honours max_lines", function()
      local path = dir .. "/long.txt"
      local lines = {}
      for i = 1, 100 do
        lines[i] = "line " .. i
      end
      vim.fn.writefile(lines, path)
      local answers = ask(path, { max_lines = 3 })
      assert.is_true(#answers[1].lines <= 4)
    end)

    it("lists a directory", function()
      vim.fn.writefile({ "x" }, dir .. "/inside.txt")
      local answers = ask(dir)
      assert.is_truthy(table.concat(answers[1].lines, "\n"):find("inside.txt", 1, true))
    end)

    it("says so for a path that is not there", function()
      local answers = ask(dir .. "/missing.txt")
      assert.equals(1, #answers)
      assert.equals("HoverMissing", answers[1].highlight)
    end)

    it("resolves a relative path against the source document", function()
      vim.fn.writefile({ "from the neighbour" }, dir .. "/neighbour.txt")
      local answers = ask("neighbour.txt", { source_path = dir .. "/doc.md" })
      assert.same({ "from the neighbour" }, answers[1].lines)
    end)

    it("shows a binary file as a badge, not as bytes", function()
      local path = dir .. "/blob.bin"
      local fd = io.open(path, "wb")
      fd:write(string.rep("\0\1\2\3", 200))
      fd:close()
      local answers = ask(path)
      assert.equals(1, #answers)
      assert.is_nil(table.concat(answers[1].lines, "\n"):find("\0", 1, true))
    end)
  end)

  describe("an address", function()
    it("stays offline when neither the setting nor the caller allows a fetch", function()
      hover.setup({ links = { fetch = false } })
      local answers = ask("https://example.com/docs/page")
      assert.equals(1, #answers)
      assert.equals(0, requests)
      assert.equals("example.com", answers[1].lines[1])
    end)

    it("fetches when the caller asks for it, whatever the setting says", function()
      hover.setup({ links = { fetch = false } })
      local answers = ask("https://example.com/", { fetch = true })
      settle(answers)
      assert.equals(1, requests)
      assert.equals(1, #answers)
      assert.is_truthy(answers[1].lines[1]:find("HTTP 200", 1, true))
      assert.is_truthy(vim.tbl_contains(answers[1].lines, "Hello page"))
    end)

    it("stays offline when the caller says no, whatever the setting says", function()
      hover.setup({ links = { fetch = true } })
      local answers = ask("https://example.com/", { fetch = false })
      assert.equals(1, #answers)
      assert.equals(0, requests)
    end)

    it("makes one request for the same address asked twice", function()
      local first = ask("https://example.com/same", { fetch = true })
      settle(first)
      local second = ask("https://example.com/same", { fetch = true })
      settle(second)
      assert.equals(1, requests)
      assert.same(first[1].lines, second[1].lines)
    end)

    it("answers a refused request with a verdict, not nothing", function()
      package.loaded["lib.nvim.net.curl"] = {
        fetch_raw = function(_, _, callback)
          callback(false, "could not resolve host")
        end,
      }
      require("hover.preview.url").reset()
      local answers = ask("https://nowhere.invalid/", { fetch = true })
      settle(answers)
      assert.equals(1, #answers)
      assert.equals("HoverError", answers[1].highlight)
    end)

    it("never calls back after cancel", function()
      local pending
      package.loaded["lib.nvim.net.curl"] = {
        fetch_raw = function(_, _, callback)
          pending = callback
        end,
      }
      require("hover.preview.url").reset()
      local answers, handle = ask("https://example.com/slow", { fetch = true })
      handle.cancel()
      pending(true, { status = 200, headers = {}, body = "" })
      vim.wait(100, function()
        return #answers > 0
      end, 5)
      assert.equals(0, #answers)
    end)

    it("does not start a browser or download a document", function()
      local shot = require("hover.preview.shot")
      local original = shot.preview
      local started = false
      shot.preview = function()
        started = true
        return { lines = { "shot" } }
      end
      hover.setup({ links = { fetch = true, shot = { enabled = true, eager = true } } })
      local answers = ask("https://example.com/", { fetch = true })
      settle(answers)
      shot.preview = original
      assert.is_false(started)
    end)
  end)

  it("turns an error in a previewer into an answer, once", function()
    local text = require("hover.preview.text")
    local original = text.file
    text.file = function()
      error("boom")
    end
    local path = dir .. "/x.txt"
    vim.fn.writefile({ "x" }, path)
    local answers = ask(path)
    text.file = original
    assert.equals(1, #answers)
    assert.equals("HoverError", answers[1].highlight)
  end)

  it("calls a callback that raises once, and lets its error through", function()
    local path = dir .. "/y.txt"
    vim.fn.writefile({ "y" }, path)
    local calls = 0
    local ok = pcall(hover.preview_target, path, function()
      calls = calls + 1
      error("mine")
    end)
    assert.is_false(ok)
    assert.equals(1, calls)
  end)

  it("lets a registered preview claim the type, and may be declined", function()
    local registry = require("hover.registry")
    registry.reset()
    registry.register("spec", {
      previews = {
        markdown = function(target)
          if target.anchor == "intro" then
            return { lines = { "claimed " .. target.anchor } }
          end
        end,
      },
    })
    local path = dir .. "/doc.md"
    vim.fn.writefile({ "# Intro", "text" }, path)
    local claimed = ask(path .. "#intro")
    local declined = ask(path .. "#other")
    registry.reset()
    assert.same({ "claimed intro" }, claimed[1].lines)
    assert.same({ "# Intro", "text" }, declined[1].lines)
  end)

  it("does not serve one size to another, nor share the hover's cache", function()
    local path = dir .. "/sizes.txt"
    local lines = {}
    for i = 1, 30 do
      lines[i] = "line " .. i
    end
    vim.fn.writefile(lines, path)
    local few = ask(path, { max_lines = 3 })
    local many = ask(path, { max_lines = 20 })
    assert.is_true(#few[1].lines < #many[1].lines)
  end)

  it("answers an empty target", function()
    local answers = ask("")
    assert.equals(1, #answers)
  end)

  describe("hardening", function()
    it("flattens newlines inside lines so they fit nvim_buf_set_lines", function()
      local answers = ask("https://example.com/a%0Ab?q=x%0Ay", { fetch = false })
      for _, line in ipairs(answers[1].lines) do
        assert.is_nil(line:find("[\r\n]"))
      end
      assert.has_no.errors(function()
        local buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, answers[1].lines)
        vim.api.nvim_buf_delete(buf, { force = true })
      end)
    end)

    it("answers a picture, a pdf and an svg with a badge, not their source text", function()
      local svg = dir .. "/pic.svg"
      vim.fn.writefile({ "<svg><text>hello</text></svg>" }, svg)
      local pdf = dir .. "/small.pdf"
      vim.fn.writefile({ "%PDF-1.1", "1 0 obj", "endobj" }, pdf)
      for _, path in ipairs({ svg, pdf }) do
        local answers = ask(path)
        assert.equals("HoverInfo", answers[1].highlight)
        local text = table.concat(answers[1].lines, "\n")
        assert.is_nil(text:find("hello", 1, true))
        assert.is_nil(text:find("obj", 1, true))
      end
    end)

    it("reads only a bounded piece of a file that is one huge line", function()
      local path = dir .. "/minified.json"
      local fd = io.open(path, "wb")
      for _ = 1, 40 do
        fd:write(string.rep("a", 100000))
      end
      fd:write("\nsecond line\n")
      fd:close()
      local started = vim.uv.hrtime()
      local answers = ask(path, { max_lines = 5 })
      local ms = (vim.uv.hrtime() - started) / 1e6
      assert.is_true(#answers[1].lines[1] < 9000)
      assert.equals("second line", answers[1].lines[2])
      assert.is_true(ms < 1000)
    end)

    it("keeps lines shorter than the cap as they are, across chunk borders", function()
      local path = dir .. "/many.txt"
      local lines = {}
      for i = 1, 20000 do
        lines[i] = "line number " .. i
      end
      vim.fn.writefile(lines, path)
      local answers = ask(path, { max_lines = 20000 })
      assert.equals("line number 1", answers[1].lines[1])
      assert.equals("line number 12345", answers[1].lines[12345])
      assert.equals("line number 20000", answers[1].lines[20000])
    end)

    it("does not follow a network path, and does not stat it", function()
      local classify = require("hover.classify")
      local uv = vim.uv or vim.loop
      local original = uv.fs_stat
      local stats = 0
      uv.fs_stat = function(...)
        stats = stats + 1
        return original(...)
      end
      local target = classify.classify([[\\192.0.2.1\share\x.txt]])
      uv.fs_stat = original
      assert.equals("missing", target.type)
      assert.equals(0, stats)
      assert.is_true(classify.is_network_path([[\\server\share]]))
      assert.is_true(classify.is_network_path("//server/share"))
      assert.is_false(classify.is_network_path("C:/x"))
      assert.is_false(classify.is_network_path("/usr/x"))
    end)

    it("does not open something that is not a regular file", function()
      local classify = require("hover.classify")
      local uv = vim.uv or vim.loop
      local original = uv.fs_stat
      uv.fs_stat = function()
        return { type = "fifo", size = 0 }
      end
      local target = classify.file("/some/pipe", "pipe")
      uv.fs_stat = original
      assert.equals("missing", target.type)
      assert.equals("not a regular file", target.reason)
    end)

    it("stops reading a directory at the cap", function()
      for i = 1, 30 do
        vim.fn.writefile({ "x" }, dir .. ("/f%02d.txt"):format(i))
      end
      local dirbrowse = require("hover.preview.dirbrowse")
      local entries, capped = dirbrowse.scan(dir, 10)
      assert.equals(10, #entries)
      assert.is_true(capped)
      local _, whole = dirbrowse.scan(dir)
      assert.is_false(whole)
    end)

    it("asks a registered anchor preview only when the document is known", function()
      local registry = require("hover.registry")
      registry.reset()
      local seen = {}
      registry.register("spec", {
        previews = {
          anchor = function(target, _, bufnr)
            seen[#seen + 1] = bufnr
            return { lines = { "anchor " .. target.anchor } }
          end,
        },
      })
      local without = ask("#intro")
      local doc = dir .. "/doc.md"
      vim.fn.writefile({ "# Intro" }, doc)
      vim.cmd.edit(doc)
      local bufnr = vim.api.nvim_get_current_buf()
      vim.cmd.enew()
      local with = ask("#intro", { source_path = doc })
      registry.reset()
      assert.same({ "#intro" }, without[1].lines)
      assert.same({ "anchor intro" }, with[1].lines)
      assert.same({ bufnr }, seen)
    end)

    it("restricts the redirects of a fetch to http and https", function()
      local seen
      package.loaded["lib.nvim.net.curl"] = {
        fetch_raw = function(_, request, callback)
          seen = request.raw_args
          callback(true, { status = 200, headers = {}, body = "" })
        end,
      }
      require("hover.preview.url").reset()
      local answers = ask("https://example.com/proto", { fetch = true })
      settle(answers)
      local joined = table.concat(seen or {}, " ")
      assert.is_truthy(joined:find("--proto =http,https", 1, true))
      assert.is_truthy(joined:find("--proto-redir =http,https", 1, true))
    end)
  end)

  describe("hardening, round 4", function()
    --- classify.classify with the file system stubbed: a UNC stat may take twenty
    --- seconds, and nothing here may depend on one.
    ---@param fn fun(stats: string[])
    local function without_fs(fn)
      local uv = vim.uv or vim.loop
      local original = uv.fs_stat
      local stats = {}
      uv.fs_stat = function(path)
        stats[#stats + 1] = path
        return { type = "file", size = 1 }
      end
      local ok, err = pcall(fn, stats)
      uv.fs_stat = original
      assert(ok, err)
    end

    it("tells a network path from a local path in the long form", function()
      local classify = require("hover.classify")
      assert.is_true(classify.is_network_path([[\\server\share]]))
      assert.is_true(classify.is_network_path([[\\?\UNC\server\share]]))
      assert.is_false(classify.is_network_path([[\\?\C:\Windows\notepad.exe]]))
      assert.is_false(classify.is_network_path([[\\.\C:\x]]))
      assert.is_false(classify.is_network_path("/usr/x"))
      assert.is_false(classify.is_network_path("C:/x"))
    end)

    it("follows a relative link in a document that lives on a share", function()
      without_fs(function(stats)
        local target = require("hover.classify").classify("b.md", "//srv/share/a.md")
        assert.equals("markdown", target.type)
        assert.equals("//srv/share/b.md", target.path)
        assert.equals(1, #stats)
      end)
    end)

    it("does not make a leading double slash when it joins onto a root", function()
      without_fs(function()
        local target = require("hover.classify").classify("docs/a.md", "/readme.md")
        assert.equals("/docs/a.md", target.path)
        assert.not_equals("missing", target.type)
      end)
    end)

    it("says a network path was not looked at, and does not call it broken", function()
      local target = require("hover.classify").classify([[\\192.0.2.1\share\x.txt]])
      assert.equals("missing", target.type)
      assert.is_true(target.refused)
      local content = require("hover.preview.text").missing(target)
      assert.equals("HoverInfo", content.highlight)
      assert.equals("not previewed", content.title)
      -- a link that is really broken keeps the red mark
      local broken =
        require("hover.preview.text").missing({ type = "missing", reason = "no such file" })
      assert.equals("HoverMissing", broken.highlight)
    end)

    it("does not report a network path written with slashes in prose as a broken target", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(
        bufnr,
        0,
        -1,
        false,
        { "see //fileserver/share/docs/readme.md here" }
      )
      vim.api.nvim_set_current_buf(bufnr)
      vim.api.nvim_win_set_cursor(0, { 1, 10 })
      local found = require("hover.bare_path").under_cursor(bufnr, {})
      vim.api.nvim_buf_delete(bufnr, { force = true })
      assert.is_nil(found)
    end)

    it("does not report a network path in prose as a broken target", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(
        bufnr,
        0,
        -1,
        false,
        { [[see \\fileserver\share\docs\readme.md here]] }
      )
      vim.api.nvim_set_current_buf(bufnr)
      vim.api.nvim_win_set_cursor(0, { 1, 10 })
      local found = require("hover.bare_path").under_cursor(bufnr, {})
      vim.api.nvim_buf_delete(bufnr, { force = true })
      assert.is_nil(found)
    end)

    it("cuts every over-long line, also one whose newline is already read", function()
      local path = dir .. "/lines.txt"
      vim.fn.writefile({ string.rep("a", 20000), "short", string.rep("b", 70000), "end" }, path)
      local answers = ask(path, { max_lines = 10 })
      local lines = answers[1].lines
      assert.is_true(#lines[1] <= 8192 + 3)
      assert.equals("short", lines[2])
      assert.is_true(#lines[3] <= 8192 + 3)
      assert.equals("end", lines[4])
    end)

    it("does not cut a multibyte character in half", function()
      local path = dir .. "/wide.txt"
      -- 'x' first, so that the cap (8192) falls between the two bytes of a character
      vim.fn.writefile({ "x" .. string.rep("é", 6000), "x" .. string.rep("é", 6000) }, path)
      local answers = ask(path, { max_lines = 5 })
      assert.equals(2, #answers[1].lines)
      for _, line in ipairs(answers[1].lines) do
        assert.equals("…", line:sub(#line - 2))
        local body = line:sub(1, #line - 3)
        assert.equals("é", body:sub(-2))
        -- no lead byte left alone at the end
        assert.is_nil(body:find("[\194-\244]$"))
      end
    end)

    --- Read files in binary mode, as Linux and macOS do: on Windows the text mode
    --- takes the CR away before the code under test sees it.
    ---@param fn fun()
    local function reading_binary(fn)
      local original = io.open
      io.open = function(path, mode)
        return original(path, mode == "r" and "rb" or mode)
      end
      local ok, err = pcall(fn)
      io.open = original
      assert(ok, err)
    end

    it("does not count the CR of a CRLF line against the cap", function()
      local path = dir .. "/crlf.txt"
      local fd = assert(io.open(path, "wb"))
      fd:write(string.rep("a", 8192), "\r\n", "next\r\n")
      fd:close()
      reading_binary(function()
        local lines = ask(path, { max_lines = 5 })[1].lines
        assert.equals(string.rep("a", 8192), lines[1])
        assert.equals("next", lines[2])
      end)
    end)

    it("does not count it either when the chunk ends between the CR and the LF", function()
      local path = dir .. "/crlf_boundary.txt"
      local fd = assert(io.open(path, "wb"))
      -- 5213 lines of 11 bytes = 57343 bytes, then 8192 characters: the CR is byte 65536,
      -- the last byte of the first 64 KiB chunk
      fd:write(string.rep("short line\n", 5213))
      fd:write(string.rep("a", 8192), "\r\n", "next\r\n")
      fd:close()
      local data = assert(io.open(path, "rb")):read("*a")
      assert.equals(65536, data:find("\r", 1, true))
      reading_binary(function()
        local lines = ask(path, { max_lines = 100000 })[1].lines
        local seen_a, seen_next = false, false
        for _, l in ipairs(lines) do
          if l == string.rep("a", 8192) then
            seen_a = true
          end
          if l == "next" then
            seen_next = true
          end
        end
        assert.is_true(seen_a, "the 8192-character line was cut")
        assert.is_true(seen_next)
      end)
    end)

    it(
      "recognises something shaped like a network path anywhere on a line, and not a comment",
      function()
        local shaped = require("hover.bare_path")._line_has_network_path
        for _, line in ipairs({
          [[\\srv\share\a.md and notes.md]],
          "//srv/share/a.md and notes.md",
          "see `//srv/share/a.md` and notes.md",
          "see {\\\\srv\\share\\a.md} and notes.md",
          "see **//srv/share/a.md** and notes.md",
          "UNC:\\\\srv\\share\\a.md notes.md",
          "see http://srv/docs/readme and notes.md",
        }) do
          assert.is_true(shaped(line, true), line)
        end
        for _, line in ipairs({
          "    // see findme.md",
          "    //TODO findme.md",
          ";//x findme.md",
          "[//]: # findme.md",
          [[re.compile("\\d+")  # findme.md]],
          "nothing here at all",
        }) do
          assert.is_false(shaped(line, true), line)
        end
        -- elsewhere than on Windows a double slash is an ordinary local path
        assert.is_false(shaped("//srv/share/a.md and notes.md", false))
      end
    )

    it("does not let gopath stat a network path, wherever on the line it is (Windows)", function()
      if vim.fn.has("win32") ~= 1 then
        pending("a double slash is an ordinary path here; gopath is asked as before")
        return
      end
      local asked = 0
      local saved = package.loaded["gopath.resolve"]
      package.loaded["gopath.resolve"] = {
        resolve_at_cursor = function()
          asked = asked + 1
          return nil
        end,
      }
      local bare_path = require("hover.bare_path")
      local ok = true
      for _, text in ipairs({
        "//fileserver/share/docs/readme.md and notes.md",
        "see `//fileserver/share/docs/readme.md` and notes.md",
        "see http://fileserver/docs/readme and notes.md",
      }) do
        local bufnr = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { text })
        vim.api.nvim_set_current_buf(bufnr)
        vim.api.nvim_win_set_cursor(0, { 1, #text - 4 })
        ok = ok and pcall(bare_path.under_cursor, bufnr, { force = true })
        ok = ok and pcall(bare_path.under_cursor, bufnr, {})
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
      package.loaded["gopath.resolve"] = saved
      assert.is_true(ok)
      assert.equals(0, asked)
    end)

    it("still asks gopath on a line with a comment slash", function()
      local asked = 0
      local saved = package.loaded["gopath.resolve"]
      package.loaded["gopath.resolve"] = {
        resolve_at_cursor = function()
          asked = asked + 1
          return nil
        end,
      }
      local bufnr = vim.api.nvim_create_buf(false, true)
      local text = "    //TODO findme.md"
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { text })
      vim.api.nvim_set_current_buf(bufnr)
      vim.api.nvim_win_set_cursor(0, { 1, #text - 4 })
      pcall(require("hover.bare_path").under_cursor, bufnr, { force = true })
      package.loaded["gopath.resolve"] = saved
      vim.api.nvim_buf_delete(bufnr, { force = true })
      assert.equals(1, asked)
    end)

    it("takes a document whose buffer was deleted for a document without a buffer", function()
      local hover_mod = require("hover")
      local doc = dir .. "/deleted.md"
      vim.fn.writefile({ "# Intro" }, doc)
      vim.cmd.edit(doc)
      local buf = vim.api.nvim_get_current_buf()
      vim.cmd.enew()
      vim.cmd("bdelete " .. buf)
      assert.is_nil(hover_mod._buffer_of(doc))
    end)

    it("finds the buffer of a document on a share by its exact name", function()
      local hover_mod = require("hover")
      local share = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(share, "//host.invalid/share/doc.md")
      local found = hover_mod._buffer_of("//host.invalid/share/doc.md")
      vim.api.nvim_buf_delete(share, { force = true })
      assert.equals(share, found)
    end)

    it("asks the real path of file buffers only, never of a terminal or a share", function()
      local hover_mod = require("hover")
      local doc = dir .. "/real.md"
      vim.fn.writefile({ "# x" }, doc)
      vim.cmd.edit(doc)
      local doc_buf = vim.api.nvim_get_current_buf()
      local odd = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(odd, "term://" .. dir .. "//123:sh")
      local share = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(share, "//host.invalid/share/other.md")
      vim.cmd.enew()
      -- a spelling the first pass cannot fold: it is the real-path pass that finds it
      local alias = dir .. "/alias_of_real.md"
      local normkey = require("lib.nvim.fs.normkey")
      local asked = {}
      package.loaded["lib.nvim.fs.normkey"] = function(path)
        asked[#asked + 1] = path
        if path == alias then
          return normkey(doc)
        end
        return normkey(path)
      end
      local ok, found = pcall(hover_mod._buffer_of, alias)
      package.loaded["lib.nvim.fs.normkey"] = normkey
      assert.is_true(ok, found)
      assert.equals(doc_buf, found)
      assert.is_true(#asked > 0)
      for _, path in ipairs(asked) do
        assert.is_nil(path:find("term://", 1, true))
        assert.is_nil(path:find("host.invalid", 1, true))
      end
    end)

    it("says a directory is not all read when the cap is below the number asked for", function()
      local dirbrowse = require("hover.preview.dirbrowse")
      local original = dirbrowse.CAP
      dirbrowse.CAP = 40
      for i = 1, 60 do
        vim.fn.writefile({}, dir .. ("/many%05d.txt"):format(i))
      end
      local ok, lines = pcall(function()
        return require("hover.preview.text").directory({ path = dir }, { max_lines = 100 }).lines
      end)
      dirbrowse.CAP = original
      assert.is_true(ok, lines)
      assert.equals(41, #lines)
      assert.is_truthy(lines[#lines]:find("not all read", 1, true))
    end)

    it("calls the volume form of a local path local, and a pipe not", function()
      local classify = require("hover.classify")
      assert.is_false(
        classify.is_network_path([[\\?\Volume{b2b56ce8-e378-4995-8fa8-ca40713e733f}\Windows]])
      )
      assert.is_false(classify.is_network_path([[\\?\C:]]))
      assert.is_true(classify.is_network_path([[\\.\pipe\nvim.1234.0]]))
    end)

    it("does not stat a network path even when the lookup is asked for outright", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(
        bufnr,
        0,
        -1,
        false,
        { "see //fileserver/share/docs/readme.md here" }
      )
      vim.api.nvim_set_current_buf(bufnr)
      vim.api.nvim_win_set_cursor(0, { 1, 10 })
      local uv = vim.uv or vim.loop
      local original = uv.fs_stat
      local touched = {}
      uv.fs_stat = function(path)
        if tostring(path):find("fileserver", 1, true) then
          touched[#touched + 1] = path
        end
        return original(path)
      end
      local trace = {}
      local ok, found =
        pcall(require("hover.bare_path").under_cursor, bufnr, { force = true, trace = trace })
      uv.fs_stat = original
      vim.api.nvim_buf_delete(bufnr, { force = true })
      assert.is_true(ok, found)
      assert.is_nil(found)
      assert.equals("network", trace.stopped_at)
      assert.same({}, touched)
    end)

    it(
      "finds the document's buffer by the same spelling, and another spelling of its path",
      function()
        local registry = require("hover.registry")
        registry.reset()
        local seen = {}
        registry.register("spec", {
          previews = {
            anchor = function(_, _, bufnr)
              seen[#seen + 1] = bufnr
              return { lines = { "anchor" } }
            end,
          },
        })
        local doc = dir .. "/spelled.md"
        vim.fn.writefile({ "# Intro" }, doc)
        vim.cmd.edit(doc)
        local doc_buf = vim.api.nvim_get_current_buf()
        vim.cmd.enew()
        vim.fn.mkdir(dir .. "/sub", "p")
        ask("#intro", { source_path = dir .. "/sub/../spelled.md" })
        registry.reset()
        assert.same({ doc_buf }, seen)
      end
    )

    it("takes the head of a big directory in name order, not some entries", function()
      for i = 1, 50 do
        vim.fn.writefile({ "x" }, dir .. ("/h%02d.txt"):format(i))
      end
      local entries, capped = require("hover.preview.dirbrowse").scan(dir, 10)
      assert.is_true(capped)
      assert.equals(10, #entries)
      for i, e in ipairs(entries) do
        assert.equals(("h%02d.txt"):format(i), e.name)
      end
    end)

    it("does not follow a pipe or a device, and not a path through the redirector", function()
      local classify = require("hover.classify")
      assert.is_true(classify.is_network_path([[\\.\pipe\nvim.1234.0]]))
      assert.is_true(classify.is_network_path([[\\.\GLOBALROOT\Device\Mup\host\share\a.md]]))
      assert.is_true(classify.is_network_path([[\\?\UNC\server\share]]))
      assert.is_false(classify.is_network_path([[\\?\C:\Windows]]))
      assert.is_false(classify.is_network_path([[\\.\C:\x]]))
    end)

    it("finds the buffer of the document by its exact name", function()
      local registry = require("hover.registry")
      registry.reset()
      local seen = {}
      registry.register("spec", {
        previews = {
          anchor = function(_, _, bufnr)
            seen[#seen + 1] = bufnr
            return { lines = { "anchor" } }
          end,
        },
      })
      local doc = dir .. "/doc.md"
      vim.fn.writefile({ "# Intro" }, doc .. ".bak")
      vim.cmd.edit(doc .. ".bak")
      vim.cmd.enew()
      ask("#intro", { source_path = doc })
      registry.reset()
      assert.same({}, seen)
    end)

    it("names a picture and a pdf by what they are", function()
      local svg = dir .. "/pic.svg"
      vim.fn.writefile({ "<svg/>" }, svg)
      local pdf = dir .. "/doc.pdf"
      vim.fn.writefile({ "%PDF-1.1" }, pdf)
      assert.is_truthy(ask(svg)[1].lines[1]:find("Image", 1, true))
      assert.is_truthy(ask(pdf)[1].lines[1]:find("PDF document", 1, true))
    end)
  end)
end)
