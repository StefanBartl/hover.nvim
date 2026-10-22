---@diagnostic disable: need-check-nil
-- The test body is the guard; see the note in TESTS/bare_path_spec.lua
-- (`LLS-42`).

-- TESTS/linkcache_spec.lua -- a fetched page kept on disk for the links the
-- reader named, and refreshed behind the reader's back once it is old.
--
-- The network is `lib.nvim.net.curl.fetch_raw` and nothing else, so it is
-- stubbed here; "a new session" is the three in-memory stores dropped
-- (`preview.url`'s last answer, `hover.cache`, `hover.linkcache`'s claims)
-- with the directory left standing, which is exactly what a restart leaves.

local url = require("hover.preview.url")
local cache = require("hover.cache")
local store = require("hover.linkcache")

local LINK = "https://docs.example.com/guide/start"

describe("hover.linkcache through preview.url.fetch", function()
  local saved_curl, saved_dir, saved_auth
  local dir

  ---@type table[] Every request the stub saw, in order.
  local requests
  ---@type (fun(ok: boolean, response: any))[] Answers not given yet.
  local held
  ---@type boolean Whether the stub holds its answer instead of giving it.
  local hold
  ---@type table|string The answer the stub gives.
  local reply
  ---@type boolean
  local reply_ok

  local function page(text, headers)
    return {
      status = 200,
      status_text = "OK",
      headers = vim.tbl_extend(
        "force",
        { ["content-type"] = "text/html", ["set-cookie"] = "session=secret" },
        headers or {}
      ),
      body = (
        "<html><head><title>%s</title><script>var big = 1;</script></head>"
        .. "<body><p>%s</p></body></html>"
      ):format(text, text),
    }
  end

  local function new_session()
    url.reset()
    cache.reset()
    store.reset()
  end

  ---@param policy? table
  ---@return Hover.PreviewOpts
  local function opts(policy)
    return {
      max_lines = 20,
      max_width = 80,
      url_cache = vim.tbl_extend("force", {
        persist = true,
        patterns = { "docs.example.com/*" },
        max_age_days = 7,
        stale_ok = true,
      }, policy or {}),
    }
  end

  ---@param link string
  ---@param o Hover.PreviewOpts
  ---@return Hover.Content|nil
  local function fetched(link, o)
    local content
    url.fetch({ type = "url", raw = link, url = link }, o, function(c)
      content = c
    end)
    return content
  end

  local function joined(content)
    return table.concat(content and content.lines or {}, "\n")
  end

  --- Push the kept entry for `link` back in time, as if it had been checked
  --- `days` ago.
  local function age(link, days)
    local entry = store.read(link)
    entry.checked_at = os.time() - days * 24 * 60 * 60
    require("lib.nvim.fs.json").write(
      ("%s/%s-%s.json"):format(dir, "docs.example.com", vim.fn.sha256(link):sub(1, 16)),
      entry
    )
  end

  before_each(function()
    requests, held, hold = {}, {}, false
    reply_ok, reply = true, page("First")
    dir = vim.fn.tempname() .. "-links"
    saved_dir = store.dir
    store.dir = function()
      return dir
    end
    saved_curl = package.loaded["lib.nvim.net.curl"]
    package.loaded["lib.nvim.net.curl"] = {
      fetch_raw = function(_, request, callback)
        requests[#requests + 1] = vim.deepcopy(request)
        if hold then
          held[#held + 1] = callback
          return
        end
        callback(reply_ok, reply)
      end,
    }
    saved_auth = package.loaded["hover.auth"]
    new_session()
  end)

  after_each(function()
    package.loaded["lib.nvim.net.curl"] = saved_curl
    package.loaded["hover.auth"] = saved_auth
    store.dir = saved_dir
    new_session()
    vim.fn.delete(dir, "rf")
  end)

  it("answers from disk in the next session without asking the host", function()
    fetched(LINK, opts())
    assert.same(1, #requests)
    new_session()
    reply_ok, reply = false, "could not resolve host"
    local content = fetched(LINK, opts())
    assert.same(1, #requests, "a kept page went back to the host")
    assert.is_truthy(joined(content):find("First", 1, true), joined(content))
    assert.is_nil(content.transient, "a fresh entry may be cached for the session")
  end)

  it("keeps only the headers it reads, never a cookie", function()
    fetched(LINK, opts())
    local entry = store.read(LINK)
    assert.is_nil(entry.headers["set-cookie"])
    assert.same("text/html", entry.headers["content-type"])
    assert.is_falsy(entry.body:find("<script", 1, true), "the kept body still has its scripts")
  end)

  it("keeps nothing while persist is off", function()
    fetched(LINK, opts({ persist = false }))
    new_session()
    fetched(LINK, opts({ persist = false }))
    assert.same(2, #requests)
    assert.same(0, (store.stats()))
  end)

  it("keeps nothing for a link outside the patterns", function()
    fetched("https://elsewhere.example.org/page", opts())
    new_session()
    fetched("https://elsewhere.example.org/page", opts())
    assert.same(2, #requests)
    assert.same(0, (store.stats()))
  end)

  it("keeps nothing without a pattern, whatever persist says", function()
    fetched(LINK, opts({ patterns = {} }))
    assert.same(0, (store.stats()))
  end)

  it("never keeps a 5xx, so a recovered server is asked again", function()
    reply = { status = 500, status_text = "Internal Server Error", headers = {}, body = "oops" }
    local first = fetched(LINK, opts())
    assert.same("HoverError", first.highlight)
    assert.same(0, (store.stats()))
    new_session()
    reply = page("Back")
    local second = fetched(LINK, opts())
    assert.same(2, #requests)
    assert.is_truthy(joined(second):find("Back", 1, true))
  end)

  it("never keeps a page fetched with a credential", function()
    package.loaded["hover.auth"] = {
      apply = function()
        return true
      end,
    }
    fetched(LINK, opts())
    assert.same(0, (store.stats()))
  end)

  it("shows a stale page at once and refreshes it with exactly one request", function()
    fetched(LINK, opts({ max_age_days = 1 }))
    age(LINK, 3)
    new_session()

    hold = true
    local shown = fetched(LINK, opts({ max_age_days = 1 }))
    assert.is_truthy(joined(shown):find("First", 1, true), "the stale page was not shown")
    assert.is_true(shown.transient, "content built from a stale page must not be cached")
    assert.same(2, #requests, "the stale hit started no refresh")

    -- Hovered again while the refresh is still out: no second request.
    cache.reset()
    fetched(LINK, opts({ max_age_days = 1 }))
    assert.same(2, #requests, "a second refresh went out for the same link")

    held[1](true, page("Second"))
    local next_hover = fetched(LINK, opts({ max_age_days = 1 }))
    assert.is_truthy(joined(next_hover):find("Second", 1, true), joined(next_hover))
    new_session()
    local next_session = fetched(LINK, opts({ max_age_days = 1 }))
    assert.is_truthy(joined(next_session):find("Second", 1, true), "the refresh was not written")
    assert.same(2, #requests)
  end)

  it(
    "asks conditionally when the server gave a validator, and a 304 only moves the clock",
    function()
      reply = page("First", { etag = '"v1"', ["last-modified"] = "Mon, 05 Oct 2026 10:00:00 GMT" })
      fetched(LINK, opts({ max_age_days = 1 }))
      age(LINK, 3)
      new_session()

      reply = { status = 304, status_text = "Not Modified", headers = {}, body = "" }
      fetched(LINK, opts({ max_age_days = 1 }))
      assert.same(2, #requests)
      assert.same('"v1"', requests[2].headers["If-None-Match"])
      assert.same("Mon, 05 Oct 2026 10:00:00 GMT", requests[2].headers["If-Modified-Since"])

      local entry = store.read(LINK)
      assert.is_false(
        store.stale(entry, opts({ max_age_days = 1 }).url_cache),
        "a 304 did not renew it"
      )
      new_session()
      local content = fetched(LINK, opts({ max_age_days = 1 }))
      assert.is_truthy(joined(content):find("First", 1, true))
      assert.same(2, #requests)
    end
  )

  it("keeps the stale page when its refresh fails", function()
    fetched(LINK, opts({ max_age_days = 1 }))
    age(LINK, 3)
    new_session()
    reply = { status = 503, headers = {}, body = "" }
    fetched(LINK, opts({ max_age_days = 1 }))
    new_session()
    reply_ok, reply = false, "down"
    local content = fetched(LINK, opts({ max_age_days = 1 }))
    assert.is_truthy(joined(content):find("First", 1, true))
  end)

  it("waits for the refresh instead when stale_ok is off", function()
    fetched(LINK, opts({ max_age_days = 1, stale_ok = false }))
    age(LINK, 3)
    new_session()
    reply = page("Fresh")
    local content = fetched(LINK, opts({ max_age_days = 1, stale_ok = false }))
    assert.same(2, #requests)
    assert.is_truthy(joined(content):find("Fresh", 1, true), joined(content))
    assert.is_nil(content.transient)
  end)

  it("lets a dead link say so: a 404 on refresh deletes the page", function()
    fetched(LINK, opts({ max_age_days = 1 }))
    age(LINK, 3)
    new_session()
    reply = { status = 404, status_text = "Not Found", headers = {}, body = "gone" }
    fetched(LINK, opts({ max_age_days = 1 }))
    assert.same(0, (store.stats()), "a dead link kept its page")
    cache.reset()
    local next_hover = fetched(LINK, opts({ max_age_days = 1 }))
    assert.is_truthy(next_hover.lines[1]:find("404", 1, true), joined(next_hover))
  end)

  it("keeps the page through a 429, which says later and not gone", function()
    fetched(LINK, opts({ max_age_days = 1 }))
    age(LINK, 3)
    new_session()
    reply = { status = 429, headers = {}, body = "" }
    fetched(LINK, opts({ max_age_days = 1 }))
    assert.same(1, (store.stats()))
  end)

  it("never keeps a URL with credentials in it", function()
    -- A leading `*`, because that is the glob a `user:pw@` host matches: the
    -- credentials are part of what `pins` calls the host.
    local link = "https://alice:hunter2@docs.example.com/guide"
    local wide = opts({ patterns = { "*docs.example.com/*" } })
    assert.is_true(
      require("hover.pins").matches(link, "*docs.example.com/*", { ignore_port = true })
    )
    fetched(link, wide)
    assert.same(0, (store.stats()))
  end)

  it("takes one glob as well as a list", function()
    -- What `config.link_cache` hands over for `patterns = "docs.example.com/*"`.
    local cfg = require("hover.config")
    cfg.setup({ links = { cache = { persist = true, patterns = "docs.example.com/*" } } })
    assert.same({ "docs.example.com/*" }, cfg.link_cache().patterns)
    cfg.setup({ links = {} })
  end)

  it("is one page whatever the fragment says", function()
    fetched(LINK .. "#install", opts())
    new_session()
    fetched(LINK .. "#usage", opts())
    assert.same(1, #requests, "a different #fragment went back to the host")
    assert.same(1, (store.stats()))
  end)

  it("shows the downloaded size, not the size of the kept body", function()
    local first = fetched(LINK, opts())
    new_session()
    local second = fetched(LINK, opts())
    local function size_line(content)
      for _, line in ipairs(content.lines) do
        if line:find("text/html", 1, true) then
          return line
        end
      end
    end
    assert.same(size_line(first), size_line(second))
  end)

  it("keeps status and headers only for a body that is not HTML", function()
    reply = {
      status = 200,
      headers = { ["content-type"] = "application/json" },
      body = '{"a": 1}',
    }
    fetched(LINK, opts())
    local entry = store.read(LINK)
    assert.same("", entry.body)
    assert.same("8", entry.headers["content-length"])
  end)

  it("still answers when the page cannot be written", function()
    -- A file where the directory should be: `mkdir` raises E739.
    local blocker = vim.fn.tempname()
    vim.fn.writefile({ "x" }, blocker)
    store.dir = function()
      return blocker .. "/links"
    end
    local content = fetched(LINK, opts())
    assert.is_truthy(content, "the hover waited forever on a cache it could not write")
    assert.is_truthy(joined(content):find("First", 1, true))
    vim.fn.delete(blocker)
  end)

  it("falls back to the old page when stale_ok is off and the host is down", function()
    fetched(LINK, opts({ max_age_days = 1, stale_ok = false }))
    age(LINK, 3)
    new_session()
    reply_ok, reply = false, "could not resolve host"
    local content = fetched(LINK, opts({ max_age_days = 1, stale_ok = false }))
    assert.is_truthy(joined(content):find("First", 1, true), joined(content))
    assert.is_true(content.transient)
  end)

  it("deletes what is on disk with clear", function()
    fetched(LINK, opts())
    assert.same(1, (store.stats()))
    assert.same(1, store.clear())
    assert.same(0, (store.stats()))
  end)

  -- ── second review ─────────────────────────────────────────────────────

  it("keeps a clear a clear when a refresh answers after it", function()
    reply = page("First", { etag = '"v1"' })
    fetched(LINK, opts({ max_age_days = 1 }))
    age(LINK, 3)
    new_session()
    hold = true
    fetched(LINK, opts({ max_age_days = 1 }))
    store.clear()
    held[1](true, { status = 304, headers = {}, body = "" })
    assert.same(0, (store.stats()), "the 304 wrote the cleared entry back")
  end)

  it("keeps the page through a 403, which is a challenge as often as a removal", function()
    fetched(LINK, opts({ max_age_days = 1 }))
    age(LINK, 3)
    new_session()
    reply = { status = 403, status_text = "Forbidden", headers = {}, body = "" }
    fetched(LINK, opts({ max_age_days = 1 }))
    assert.same(1, (store.stats()))
  end)

  it("takes the validators a 304 brings", function()
    reply = page("First", { etag = '"v1"' })
    fetched(LINK, opts({ max_age_days = 1 }))
    age(LINK, 3)
    new_session()
    reply = { status = 304, headers = { etag = '"v2"' }, body = "" }
    fetched(LINK, opts({ max_age_days = 1 }))
    assert.same('"v2"', store.read(LINK).headers.etag)
  end)

  it("refreshes a page once, whichever #fragment the links carry", function()
    fetched(LINK, opts({ max_age_days = 1 }))
    age(LINK, 3)
    new_session()
    hold = true
    fetched(LINK .. "#a", opts({ max_age_days = 1 }))
    url.reset()
    cache.reset()
    fetched(LINK .. "#b", opts({ max_age_days = 1 }))
    assert.same(2, #requests, "a second refresh went out for the same page")
  end)

  it("reads the page text of an answer whose type is written in capitals", function()
    reply = page("Shouted")
    reply.headers["content-type"] = "Text/HTML; charset=UTF-8"
    local content = fetched(LINK, opts({ persist = false }))
    local text_lines = 0
    for _, line in ipairs(content.lines) do
      if line == "Shouted" then
        text_lines = text_lines + 1
      end
    end
    assert.same(2, text_lines, "the title and the page text, not the title alone")
  end)

  it("keeps the body of an answer that names no content type", function()
    reply = page("Untyped")
    reply.headers["content-type"] = nil
    fetched(LINK, opts())
    new_session()
    local content = fetched(LINK, opts())
    assert.is_truthy(joined(content):find("Untyped", 1, true), joined(content))
  end)

  it("tells checkhealth about a write that failed", function()
    local blocker = vim.fn.tempname()
    vim.fn.writefile({ "x" }, blocker)
    store.dir = function()
      return blocker .. "/links"
    end
    fetched(LINK, opts())
    assert.is_truthy(store.last_error(), "the failed write was not noted")
    vim.fn.delete(blocker)
  end)

  it("tells checkhealth about a write that answered false", function()
    local real = package.loaded["lib.nvim.fs.json"]
    package.loaded["lib.nvim.fs.json"] = {
      read = real.read,
      write = function()
        return false, "permission denied"
      end,
    }
    fetched(LINK, opts())
    package.loaded["lib.nvim.fs.json"] = real
    assert.is_truthy((store.last_error() or ""):find("permission denied", 1, true))
  end)

  it("shows the old page when curl cannot even start and stale_ok is off", function()
    fetched(LINK, opts({ max_age_days = 1, stale_ok = false }))
    age(LINK, 3)
    new_session()
    package.loaded["lib.nvim.net.curl"] = {
      fetch_raw = function()
        error("spawn failed")
      end,
    }
    local content = fetched(LINK, opts({ max_age_days = 1, stale_ok = false }))
    assert.is_truthy(content and joined(content):find("First", 1, true))
  end)

  -- ── third review ──────────────────────────────────────────────────────

  it("hands the refreshed page to a hover on another #fragment of it", function()
    fetched(LINK, opts({ max_age_days = 1 }))
    age(LINK, 3)
    new_session()
    hold = true
    fetched(LINK .. "#a", opts({ max_age_days = 1 }))
    cache.reset()
    -- no url.reset(): `_last` now holds the stale page for #b
    fetched(LINK .. "#b", opts({ max_age_days = 1 }))
    held[1](true, page("Second"))
    local content = fetched(LINK .. "#b", opts({ max_age_days = 1 }))
    assert.is_truthy(joined(content):find("Second", 1, true), joined(content))
  end)

  it("keeps a body only where the preview reads one", function()
    assert.is_true(store.keeps_body("text/html; charset=utf-8", "<p>"))
    assert.is_true(store.keeps_body("application/xhtml+xml", "<p>"))
    assert.is_true(store.keeps_body("application/rss+xml", "<rss>"))
    assert.is_true(store.keeps_body("text/xml", "<a/>"))
    assert.is_false(
      store.keeps_body(
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "PK"
      ),
      "an office document is a ZIP archive"
    )
    assert.is_false(store.keeps_body("application/json", "{}"))
    assert.is_true(store.keeps_body(nil, "  <html><title>T</title>"), "untyped markup")
    assert.is_false(store.keeps_body(nil, "%PDF-1.4\0binary"), "an untyped PDF")
    assert.is_false(store.keeps_body("", "<\0>"), "markup-looking, but with a NUL byte")
  end)

  it("lets a page go that keeps refusing for four times max_age_days", function()
    fetched(LINK, opts({ max_age_days = 1 }))
    age(LINK, 5)
    new_session()
    reply = { status = 403, status_text = "Forbidden", headers = {}, body = "" }
    fetched(LINK, opts({ max_age_days = 1 }))
    assert.same(0, (store.stats()), "a page refused for five days at max_age_days = 1 was kept")
  end)

  it("keeps a page that only the network cannot reach, however old", function()
    fetched(LINK, opts({ max_age_days = 1 }))
    age(LINK, 30)
    new_session()
    reply_ok, reply = false, "could not resolve host"
    fetched(LINK, opts({ max_age_days = 1 }))
    assert.same(1, (store.stats()))
  end)

  it("keeps a clear a clear for a first fetch that answers after it", function()
    hold = true
    fetched(LINK, opts())
    store.clear()
    held[1](true, page("First"))
    assert.same(0, (store.stats()), "the first fetch wrote after the clear")
  end)

  it("reads the title from <title>, not from a <title-bar> before it", function()
    reply = page("Ignored")
    reply.body =
      "<html><head><title-bar>Bar</title-bar><title>Real</title></head><body><p>x</p></body></html>"
    local content = fetched(LINK, opts({ persist = false }))
    assert.same("Real", content.lines[2], joined(content))
  end)

  it("forgets a write error once a write works again", function()
    store.note_error("E739")
    fetched(LINK, opts())
    assert.is_nil(store.last_error())
  end)
end)

describe("hover.preview.url, second review", function()
  it("does not take a custom element for the element it starts like", function()
    local body = "<html><body><style-x>x</style-x><p>Kept.</p><style>p{}</style></body></html>"
    assert.is_truthy(url.slim(body):find("Kept.", 1, true))
    assert.same({ "x", "Kept." }, url.page_text(body, { max_width = 80, max_lines = 10 }))
  end)

  it("does not take <title-bar> or <main-menu> for <title> or <main>", function()
    local body = "<html><head><title-bar>Bar</title-bar><title>Real</title></head><body>"
      .. "<main-menu><p>Menu</p></main-menu><main><p>Content.</p></main></body></html>"
    local content = url.page_text(body, { max_width = 80, max_lines = 10 })
    assert.same({ "Content." }, content)
  end)
end)

describe("hover.preview.url.slim", function()
  it("reads exactly as the downloaded body did", function()
    local body = "<html><head><title>T</title><style>p{}</style>"
      .. '<meta name="description" content="D"></head><body>'
      .. "<!-- </main> --><nav><p>Home</p></nav><main><p>Real text.</p>"
      .. "<script>var s = '<p>not text</p>';</script><noscript>no</noscript>"
      .. "<ul><li>one</li><li>two</li></ul></main></body></html>"
    local o = { max_width = 80, max_lines = 50 }
    assert.same(url.page_text(body, o), url.page_text(url.slim(body), o))
    assert.is_falsy(url.slim(body):find("not text", 1, true))
    assert.is_truthy(url.slim(body):find("<title>T</title>", 1, true))
  end)

  it("does not let a self-closing script swallow the title after it", function()
    local body = '<html><head><script src="a.js"/><title>Real Title</title>'
      .. "<script>x()</script></head><body><p>Text.</p></body></html>"
    local slim = url.slim(body)
    assert.is_truthy(slim:find("<title>Real Title</title>", 1, true), slim)
    assert.is_falsy(slim:find("x()", 1, true), slim)
  end)
end)
