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

  it("answers an empty target", function()
    local answers = ask("")
    assert.equals(1, #answers)
  end)
end)
