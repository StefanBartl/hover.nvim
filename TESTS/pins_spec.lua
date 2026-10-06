---@diagnostic disable: need-check-nil
-- The test body is the guard; see the note in TESTS/bare_path_spec.lua
-- (`LLS-42`).

-- TESTS/pins_spec.lua -- `links.pins`: a link shown as a file of the reader's
-- own.
--
-- **What is pinned here is the rule a reader has to be able to predict**, not
-- the plumbing. A glob that matches too much sends a pin to the wrong page
-- silently -- the float is a perfectly good PDF, just not of that link -- so
-- each decision that a plausible edit could reverse has a case of its own:
--
--   1. **`*` crosses `/`**, and is the only wildcard. `?` is literal, because
--      it is where a query string starts.
--   2. **A glob without a `/` is a host**, compared whole: `example.com` must
--      not match `example.com.evil.net`, and must match `example.com` with no
--      path at all.
--   3. **Scheme, fragment and case do not matter**, on either side.
--   4. **First match wins**, in the order written.
--   5. **A pin whose file is gone says so** instead of falling through to the
--      link's own preview -- which, for the page it exists for, is the login
--      form.
--   6. **It works with `links.web` off**, which is the part that needs the
--      bare-URL source to look.

local config = require("hover.config")
local registry = require("hover.registry")
local float = require("hover.float")
local pins = require("hover.pins")
local hover = require("hover")

describe("hover.pins.matches", function()
  it("matches a host glob against the host alone", function()
    assert.is_true(pins.matches("https://confluence.example.com/a/b?c=d", "confluence.example.com"))
    assert.is_true(pins.matches("https://confluence.example.com", "confluence.example.com"))
    assert.is_true(pins.matches("https://wiki.example.com/x", "*.example.com"))
  end)

  it("does not let a host glob match a host that merely starts with it", function()
    assert.is_false(pins.matches("https://example.com.evil.net/x", "example.com"))
    assert.is_false(pins.matches("https://notexample.com/x", "example.com"))
    assert.is_false(pins.matches("https://example.com/x", "*.example.com"))
  end)

  it("does not read the path when the glob names none", function()
    -- `example.com` is a statement about the host; a path that happens to
    -- contain it is not that host.
    assert.is_false(pins.matches("https://other.net/example.com", "example.com"))
  end)

  it("matches host, path and query when the glob has a slash", function()
    assert.is_true(pins.matches("https://example.com/wiki/a/b", "example.com/wiki/*"))
    assert.is_false(pins.matches("https://example.com/blog/a", "example.com/wiki/*"))
    assert.is_true(pins.matches("https://example.com/", "example.com/*"))
    -- No path at all is still a path of "/".
    assert.is_true(pins.matches("https://example.com", "example.com/*"))
  end)

  it("lets a star cross a slash, and treats nothing else as a wildcard", function()
    assert.is_true(pins.matches("https://example.com/a/b/c/d", "example.com/a/*/d"))
    -- `?` is a query string, not "any one character".
    assert.is_true(pins.matches("https://example.com/v?id=42", "example.com/v?id=42"))
    assert.is_false(pins.matches("https://example.com/vXid=42", "example.com/v?id=42"))
    -- A dot is a dot.
    assert.is_false(pins.matches("https://exampleXcom/a", "example.com"))
  end)

  it("ignores scheme, fragment and case on both sides", function()
    assert.is_true(pins.matches("HTTP://Example.COM/Wiki#top", "https://example.com/wiki"))
    assert.is_true(pins.matches("https://example.com/wiki", "EXAMPLE.com/WIKI#anything"))
  end)

  it("answers false for a glob that is not usable", function()
    assert.is_false(pins.matches("https://example.com", ""))
    assert.is_false(pins.matches("https://example.com", "https://"))
    assert.is_false(pins.matches("https://example.com", nil))
  end)
end)

describe("hover.pins, resolving a link", function()
  local root

  before_each(function()
    config.reset()
    root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
  end)

  after_each(function()
    config.reset()
    vim.fn.delete(root, "rf")
  end)

  ---@param name string
  ---@return string
  local function file(name)
    local path = root .. "/" .. name
    vim.fn.writefile({ "x" }, path)
    return vim.fs.normalize(path)
  end

  it("is empty by default and changes nothing", function()
    assert.is_false(pins.any())
    local t = require("hover.classify").classify("https://example.com/a", nil)
    assert.equals("url", pins.apply(t).type)
  end)

  it("turns a matching URL into the file it names, typed by extension", function()
    local pdf = file("page.pdf")
    config.setup({ links = { pins = { { match = "example.com/*", show = pdf } } } })

    local t = pins.apply(require("hover.classify").classify("https://example.com/a", nil))
    assert.equals("pdf", t.type)
    assert.equals(pdf, t.path)
    assert.equals("https://example.com/a", t.raw, "raw stays the link as written")
    assert.equals("https://example.com/a", t.pinned.url)
    assert.equals("example.com/*", t.pinned.glob)

    local png = file("page.png")
    config.setup({ links = { pins = { { match = "wiki.example.com", show = png } } } })
    local img = pins.apply(require("hover.classify").classify("https://wiki.example.com/z", nil))
    assert.equals("image", img.type)
  end)

  it("takes the first pin that matches, in the order written", function()
    local first, second = file("first.pdf"), file("second.pdf")
    config.setup({
      links = {
        pins = {
          { match = "example.com/a/*", show = first },
          { match = "example.com/*", show = second },
        },
      },
    })
    local classify = require("hover.classify")
    assert.equals(first, pins.apply(classify.classify("https://example.com/a/b", nil)).path)
    assert.equals(second, pins.apply(classify.classify("https://example.com/c", nil)).path)
  end)

  it("accepts a list of globs for one file", function()
    local pdf = file("both.pdf")
    config.setup({
      links = { pins = { { match = { "one.example.com", "two.example.com" }, show = pdf } } },
    })
    local classify = require("hover.classify")
    assert.equals(pdf, pins.apply(classify.classify("https://two.example.com/x", nil)).path)
    assert.equals("url", pins.apply(classify.classify("https://three.example.com/x", nil)).type)
  end)

  it("says the file is missing rather than falling back to the link", function()
    config.setup({
      links = { pins = { { match = "example.com/*", show = root .. "/gone.pdf" } } },
    })
    local t = pins.apply(require("hover.classify").classify("https://example.com/a", nil))
    assert.equals("missing", t.type)
    assert.matches("pinned file not found", t.reason)
    assert.matches("example.com/%*", t.reason)
  end)

  it("resolves a relative `show` against the Neovim configuration", function()
    config.setup({ links = { pins = { { match = "example.com", show = "no-such-dir/p.pdf" } } } })
    local pin = pins.resolve("https://example.com/")
    assert.equals(vim.fs.normalize(vim.fn.stdpath("config") .. "/no-such-dir/p.pdf"), pin.path)
  end)

  it("skips an entry it cannot use instead of raising", function()
    config.setup({
      links = {
        pins = {
          { match = "example.com" }, -- no show
          { show = "x.pdf" }, -- no match
          { match = 3, show = "x.pdf" },
          "not a table",
          { match = "ok.example.com", show = "x.pdf" },
        },
      },
    })
    local list = pins.list()
    assert.equals(1, #list)
    assert.same({ "ok.example.com" }, list[1].match)
  end)

  it("leaves a link that is not a URL alone", function()
    local pdf = file("p.pdf")
    config.setup({ links = { pins = { { match = "*", show = pdf } } } })
    local t = { type = "file", raw = "a.txt", path = "/x/a.txt" }
    assert.equals(t, pins.apply(t))
  end)

  it("is replaced, not merged, by a second setup", function()
    local a, b = file("a.pdf"), file("b.pdf")
    config.setup({
      links = {
        pins = { { match = "a.example.com", show = a }, { match = "b.example.com", show = b } },
      },
    })
    assert.equals(2, #pins.list())
    config.setup({ links = { pins = { { match = "a.example.com", show = a } } } })
    assert.equals(1, #pins.list(), "an earlier call's pins survived a shorter list")
  end)

  it("is not asked about when links are off", function()
    local pdf = file("p.pdf")
    config.setup({ links = { enabled = false, pins = { { match = "example.com", show = pdf } } } })
    assert.is_false(pins.any())
  end)
end)

describe("hover.show on a pinned link, with the web hover off", function()
  local root, win, prev_buf, buf, pinned

  before_each(function()
    config.reset()
    registry.reset()
    hover.hide()

    root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    -- Markdown, not a PDF: this spec is about which file the link becomes,
    -- and a text file shows its own first line without a rasterizer.
    pinned = root .. "/stand-in.md"
    vim.fn.writefile({ "the stand-in for the login page" }, pinned)

    win = vim.api.nvim_get_current_win()
    prev_buf = vim.api.nvim_win_get_buf(win)
    buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, root .. "/notes.txt")
    vim.api.nvim_win_set_buf(win, buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "see https://confluence.example.com/x/y now" })
    vim.api.nvim_win_set_cursor(win, { 1, 12 })
  end)

  after_each(function()
    hover.hide()
    pcall(vim.api.nvim_win_set_buf, win, prev_buf)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    vim.fn.delete(root, "rf")
    config.reset()
    registry.reset()
  end)

  ---@return string
  local function shown()
    local w = float.win()
    if not w then
      return ""
    end
    return table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false), "\n")
  end

  it("shows the file, although links.web is off and nothing is requested", function()
    config.setup({
      links = { web = false, pins = { { match = "confluence.example.com", show = pinned } } },
    })
    assert.is_true(hover.show({ force = true }))
    assert.matches("stand%-in for the login page", shown())
  end)

  it("is found by the automatic trigger too, which is where the web switch bites", function()
    -- `force` opens the bare-URL source whatever the web switch says, so the
    -- case above cannot tell whether a pin makes the URL findable at all.
    config.setup({
      auto_hover = { markdown = true },
      links = { web = false, pins = { { match = "confluence.example.com", show = pinned } } },
    })
    assert.is_true(hover.show({}))
    assert.matches("stand%-in for the login page", shown())
  end)

  it("still refuses an unpinned URL while the web hover is off", function()
    config.setup({
      links = { web = false, pins = { { match = "other.example.com", show = pinned } } },
    })
    assert.is_false(hover.show({}))
    assert.is_falsy(float.win())
  end)

  it("explains the pin in `why`", function()
    config.setup({
      links = { web = false, pins = { { match = "confluence.example.com", show = pinned } } },
    })
    assert.matches("pinned", table.concat(hover.why(), "\n"))
  end)
end)
