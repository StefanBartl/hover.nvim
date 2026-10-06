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

  it("is strict about a port by default, which is what a credential rule needs", function()
    assert.is_false(pins.matches("https://wiki.corp:8090/x", "wiki.corp"))
    assert.is_false(pins.matches("https://wiki.corp:8090/x", "wiki.corp/*"))
    assert.is_true(pins.matches("https://wiki.corp:8090/x", "wiki.corp:8090"))
    assert.is_true(pins.matches("https://wiki.corp:8090/x", "wiki.corp:*"))
  end)

  it("lets a pin ignore a port its glob does not name", function()
    -- 8090 is Confluence's default port, so a pin written the way the
    -- documentation writes it has to find an intranet host.
    local loose = { ignore_port = true }
    assert.is_true(
      pins.matches("http://wiki.corp:8090/display/T/x", "wiki.corp/display/T/*", loose)
    )
    assert.is_true(pins.matches("http://wiki.corp:8090/x", "wiki.corp", loose))
    assert.is_true(pins.matches("http://wiki.corp:8090/x", "*.corp", loose))
    -- A port the glob names is still that port.
    assert.is_false(pins.matches("http://wiki.corp:8091/x", "wiki.corp:8090", loose))
    -- Never the userinfo: that is the safe direction.
    assert.is_false(pins.matches("https://me@wiki.corp/x", "wiki.corp", loose))
    assert.is_false(pins.matches("https://wiki.corp@evil.com/x", "wiki.corp", loose))
  end)

  it("does not backtrack: several stars against a long URL stay fast", function()
    -- As a Lua pattern this was cubic in the number of stars: measured 2.7 ms
    -- at 50 repeats, 475 ms at 200, 8.9 s at 400. The URL is text out of a
    -- document the reader did not write.
    local url = "https://example.com/" .. ("pages/view/"):rep(800) .. "x"
    local started = (vim.uv or vim.loop).hrtime()
    assert.is_false(pins.matches(url, "example.com/*/pages/*/view/*/edit"))
    assert.is_true(pins.matches(url, "example.com/*/pages/*/view/*/x"))
    local ms = ((vim.uv or vim.loop).hrtime() - started) / 1e6
    assert.is_true(ms < 100, ("took %.1f ms"):format(ms))
  end)

  it("agrees with a pattern-based reference on random globs and URLs", function()
    -- The matcher is hand-written, so it is held against the obvious (and
    -- slow) implementation on inputs small enough for the slow one.
    math.randomseed(7)
    local function random(alphabet, len)
      local out = {}
      for k = 1, len do
        out[k] = alphabet[math.random(#alphabet)]
      end
      return table.concat(out)
    end
    local function reference(subject, glob)
      local pieces = {}
      for piece in (glob .. "*"):gmatch("(.-)%*") do
        pieces[#pieces + 1] = vim.pesc(piece)
      end
      return subject:match("^" .. table.concat(pieces, ".*") .. "$") ~= nil
    end
    for _ = 1, 3000 do
      local host = random({ "a", "b", "." }, math.random(1, 5))
      local path = random({ "a", "b", ".", "/" }, math.random(0, 8))
      local glob = host .. "/" .. random({ "a", "b", ".", "/", "*" }, math.random(0, 6))
      local url = "https://" .. host .. "/" .. path
      assert.equals(
        reference(host .. "/" .. path, glob),
        pins.matches(url, glob),
        url .. " ~ " .. glob
      )
    end
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

  it("does not read a UNC path as a protocol-relative URL", function()
    -- `vim.fs.normalize` turns `\\server\share\x.pdf` into `//server/share/x.pdf`,
    -- which `classify.classify` reads as `https://server/share/x.pdf` -- a pin
    -- that then makes a network request instead of paging a file.
    config.setup({
      links = { pins = { { match = "wiki.example.com", show = "//fileserver/shots/team.pdf" } } },
    })
    local t = pins.apply(require("hover.classify").classify("https://wiki.example.com/a", nil))
    assert.not_equals("url", t.type)
    assert.is_nil(t.url)
    assert.matches("team%.pdf$", t.path)
    assert.equals("pdf", t.pinned.as)
  end)

  it("keeps a `#` in the file name, which is not an anchor", function()
    local pdf = file("report#1.pdf")
    config.setup({ links = { pins = { { match = "example.com", show = pdf } } } })
    local t = pins.apply(require("hover.classify").classify("https://example.com/a", nil))
    assert.equals("pdf", t.type)
    assert.equals(pdf, t.path)
  end)

  it("finds a pin for an intranet host whatever port the link carries", function()
    local pdf = file("intranet.pdf")
    config.setup({ links = { pins = { { match = "wiki.corp/display/T/*", show = pdf } } } })
    local t =
      pins.apply(require("hover.classify").classify("http://wiki.corp:8090/display/T/page", nil))
    assert.equals(pdf, t.path)
  end)

  it("says what a missing file would have been, by its extension", function()
    config.setup({
      links = {
        pins = {
          { match = "a.example.com", show = root .. "/gone.pdf" },
          { match = "b.example.com", show = root .. "/gone.md" },
          { match = "c.example.com", show = root .. "/gone.PNG" },
        },
      },
    })
    local classify = require("hover.classify")
    assert.equals("pdf", pins.apply(classify.classify("https://a.example.com/", nil)).pinned.as)
    assert.equals(
      "markdown",
      pins.apply(classify.classify("https://b.example.com/", nil)).pinned.as
    )
    assert.equals("image", pins.apply(classify.classify("https://c.example.com/", nil)).pinned.as)
  end)

  it("knows whether a URL as written in a document is covered", function()
    local pdf = file("covered.pdf")
    config.setup({ links = { pins = { { match = "example.com/*", show = pdf } } } })
    assert.is_true(pins.covers("https://example.com/a"))
    assert.is_true(pins.covers([[http:\\example.com]]), "the Windows typo is repaired first")
    assert.is_false(pins.covers("https://other.example.org/a"))
    assert.is_false(pins.covers("not a url"))
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

  it("does not claim an unpinned URL, so what would have answered still can", function()
    -- Claiming it ended the lookup: `show` then refused the URL and never
    -- reached the position previews and bare paths that answer without pins.
    config.setup({
      links = { web = false, pins = { { match = "other.example.com", show = pinned } } },
    })
    assert.is_nil(hover.target_under_cursor(buf, {}))
    config.setup({
      links = { web = false, pins = { { match = "confluence.example.com", show = pinned } } },
    })
    local found = hover.target_under_cursor(buf, {})
    assert.equals("https://confluence.example.com/x/y", found.target)
  end)

  it("matches a pin for a host on a port the link carries", function()
    vim.api.nvim_buf_set_lines(
      buf,
      0,
      -1,
      false,
      { "see http://confluence.example.com:8090/x/y now" }
    )
    config.setup({
      auto_hover = { markdown = true },
      links = { web = false, pins = { { match = "confluence.example.com", show = pinned } } },
    })
    assert.is_true(hover.show({}))
    assert.matches("stand%-in for the login page", shown())
  end)

  it("does not hover by itself with links off, whichever route found the URL", function()
    -- The bare-path route finds a URL whose last component has an extension,
    -- with `links` off, and the pin turned it into a file that passed the web
    -- gate: the master switch for link hovers was not one.
    vim.api.nvim_buf_set_lines(
      buf,
      0,
      -1,
      false,
      { "see https://confluence.example.com/x/y.html now" }
    )
    config.setup({
      auto_hover = { markdown = true },
      links = {
        enabled = false,
        pins = { { match = "confluence.example.com", show = pinned } },
      },
    })
    assert.is_false(hover.show({}))
    assert.is_falsy(float.win())
    assert.matches("links are off", table.concat(hover.why(), "\n"))
    -- Asked for outright, it still answers.
    assert.is_true(hover.show({ force = true }))
  end)

  it("announces a pinned PDF that has gone, where the PDF would have opened", function()
    -- `missing` is off in auto_hover, so the one hover that exists to say
    -- "the file you pinned is gone" stayed silent, and the link just stopped
    -- hovering.
    config.setup({
      links = {
        web = false,
        pins = { { match = "confluence.example.com", show = root .. "/gone.pdf" } },
      },
    })
    assert.is_false(config.auto_hover_for("missing"))
    assert.is_true(hover.show({}))
    assert.matches("pinned file not found", shown())
  end)

  it("keeps a gone pinned markdown file as quiet as the file would have been", function()
    config.setup({
      links = {
        web = false,
        pins = { { match = "confluence.example.com", show = root .. "/gone.md" } },
      },
    })
    assert.is_false(hover.show({}))
    assert.is_falsy(float.win())
  end)

  describe("<CR> on the float", function()
    local calls, real_open, real_registry

    before_each(function()
      calls = {}
      real_open = package.loaded["open"]
      real_registry = package.loaded["open.registry"]
      package.loaded["open"] = {
        open = function(target, scope)
          calls[#calls + 1] = { target = target, scope = scope }
        end,
      }
      package.loaded["open.registry"] = {
        list_keys = function()
          return { "default" }
        end,
      }
    end)

    after_each(function()
      package.loaded["open"] = real_open
      package.loaded["open.registry"] = real_registry
    end)

    it("opens the real URL the way an unpinned one is opened, not as a path=", function()
      -- Through the `default` handler as `path=<url>`, open.nvim expands `$VAR`
      -- in what it takes for a path, and the browser pick is bypassed.
      vim.api.nvim_buf_set_lines(
        buf,
        0,
        -1,
        false,
        { "see https://confluence.example.com/x/y?a=$HOME now" }
      )
      config.setup({
        links = { web = false, pins = { { match = "confluence.example.com", show = pinned } } },
      })
      assert.is_true(hover.show({ force = true }))
      assert.is_true(hover.open())
      assert.equals(1, #calls)
      assert.is_nil(calls[1].target, "the browser pick, not the `default` handler")
      assert.equals("https://confluence.example.com/x/y?a=$HOME", calls[1].scope)
    end)
  end)

  it("explains the pin in `why`", function()
    config.setup({
      links = { web = false, pins = { { match = "confluence.example.com", show = pinned } } },
    })
    assert.matches("pinned", table.concat(hover.why(), "\n"))
  end)
end)
