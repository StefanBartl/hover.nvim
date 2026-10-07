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
end)
