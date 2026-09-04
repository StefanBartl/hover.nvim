---@diagnostic disable: need-check-nil
-- The test body is the guard; see the note in TESTS/bare_path_spec.lua
-- (`LLS-42`).

-- TESTS/webpdf_spec.lua -- a link that answers with a PDF, shown as its page.
--
-- **The download itself is not here** -- it needs a network and a server, and
-- the page after it needs pdfport and a terminal. What a run can check is the
-- four decisions around it, and each one is a real failure when it is wrong:
--
--   1. **What counts as a PDF.** The *server's* content type, never the URL's
--      extension. This module is about to spend a request and up to
--      `max_bytes`, and a `.pdf` in a path is the author's word rather than
--      the server's -- they disagree often enough to matter (a download
--      endpoint with no extension; a `.pdf` that 404s to an HTML error page).
--   2. **A refusal before the download, not after it.** A PDF over the cap is
--      reported with both numbers rather than fetched and truncated.
--   3. **A truncated file never reaches the rasterizer.** Half a PDF is not a
--      smaller PDF; it is a file `pdftoppm` will not open, and the error would
--      read as a broken renderer. It is also never left in the cache, where it
--      would be served for a week.
--   4. **`implies = "fetch"`, which is a mechanism rather than a policy.** The
--      content type is what identifies the link, and only a fetch produces
--      one.

local config = require("hover.config")
local switches = require("hover.switches")
local webpdf = require("hover.preview.webpdf")

---@param headers table<string, string>
---@return table
local function response(headers)
  return { status = 200, headers = headers, body = "" }
end

describe("the PDF-link switch", function()
  before_each(function()
    config.reset()
    webpdf.reset()
    vim.g.hover_disable = nil
  end)

  after_each(function()
    config.reset()
    webpdf.reset()
    vim.g.hover_disable = nil
  end)

  it("is reachable as `:Hover links web fetch pdf`", function()
    assert.same({ "links", "web", "fetch", "pdf" }, switches.route("pdf"))
  end)

  it("turns fetching on with it, because only a fetch names the content type", function()
    switches.set("pdf", true, { silent = true })
    assert.is_true(config.fetch_enabled(), "a PDF link with no content type to identify it")
    assert.is_true(config.web_enabled())
    assert.is_true(config.url_pdf_enabled())
  end)

  it("goes silent when fetching goes off, without demoting itself", function()
    switches.set("pdf", true, { silent = true })
    switches.set("fetch", false, { silent = true })
    assert.is_false(config.url_pdf_enabled())

    switches.set("fetch", true, { silent = true })
    assert.is_true(config.url_pdf_enabled(), "turning the parent back on demoted the child")
  end)

  it("carries its configured shape into the preview options", function()
    config.setup({
      links = {
        web = true,
        fetch = true,
        pdf = { enabled = true, max_bytes = 7, timeout_ms = 8, cache_days = 9 },
      },
    })
    local opts = config.preview_opts()
    assert.is_true(opts.url_pdf)
    assert.same(7, opts.url_pdf_max_bytes)
    assert.same(8, opts.url_pdf_timeout_ms)
    assert.same(9, opts.url_pdf_cache_days)
  end)

  it("drops the preview cache when thrown, since it changes what a link is", function()
    local cache = require("hover.cache")
    cache.put("k", { lines = { "old" } })
    switches.set("pdf", true, { silent = true })
    assert.is_nil(cache.get("k"))
  end)
end)

describe("hover.preview.webpdf", function()
  local target = {
    type = "url",
    raw = "https://example.com/paper.pdf",
    url = "https://example.com/paper.pdf",
  }

  before_each(function()
    config.reset()
    webpdf.reset()
  end)

  after_each(function()
    config.reset()
    webpdf.reset()
  end)

  it("reads the server's content type, and only that", function()
    assert.is_true(webpdf.is_pdf(response({ ["content-type"] = "application/pdf" })))
    assert.is_true(
      webpdf.is_pdf(response({ ["content-type"] = "Application/PDF; charset=binary" }))
    )
    assert.is_false(webpdf.is_pdf(response({ ["content-type"] = "text/html" })))
  end)

  it("does not take a .pdf in the path as an answer", function()
    -- The URL says `paper.pdf` and the server says HTML — which is what a 404
    -- page at a PDF URL looks like. Believing the path would spend a request
    -- and up to `max_bytes` on an error page.
    assert.is_false(webpdf.is_pdf(response({ ["content-type"] = "text/html" })))
    assert.is_false(webpdf.is_pdf(response({})))
    assert.is_false(webpdf.is_pdf("some error string"))
    assert.is_false(webpdf.is_pdf(nil))
  end)

  it("refuses a document over the cap, naming both numbers and the option", function()
    local content = webpdf.preview(
      target,
      response({ ["content-type"] = "application/pdf", ["content-length"] = "99000000" }),
      { max_lines = 20, url_pdf_max_bytes = 25000000 },
      function() end
    )
    local text = table.concat(content.lines, "\n")
    assert.is_truthy(text:find("links.pdf.max_bytes", 1, true), "the option to change is unnamed")
    assert.is_nil(content.pending, "a refused download was reported as in flight")
    -- The URL is still underneath, so a refusal is never an empty float.
    assert.is_truthy(vim.tbl_contains(content.lines, "example.com"))
  end)

  it(
    "says nothing is cached for a link never downloaded, and downloads nothing to find out",
    function()
      -- `hover.scroll` and `hover.zoom` ask this to decide whether a link is
      -- currently a paged document. A capability question must not have a
      -- thirty-second answer.
      assert.is_nil(webpdf.cached(target))
    end
  )

  --- A document sitting in the cache directory under this link's own key, as
  --- an earlier session would have left it.
  ---@param length string|nil the length the server declared, if any
  ---@param body? string what is in the file; a complete PDF by default
  ---@return string path
  ---@return table response
  local function on_disk(length, body)
    local root = vim.fn.stdpath("cache") .. "/hover.nvim/webpdf"
    vim.fn.mkdir(root, "p")

    -- The key and the filename are written out here rather than asked of the
    -- module, and that is the point of this fixture: it is the *cross-session*
    -- half of the cache. A spec that derived the name through the module could
    -- not tell a key that survives a restart from one that only holds while
    -- `_pdfs` does -- it would pass either way.
    local key = ("%s %s"):format(target.url, length or "?")
    local path = ("%s/%s-%s.pdf"):format(root, "example.com", vim.fn.sha256(key):sub(1, 16))

    -- Minimal but *complete*: the `%PDF-` header and the `%%EOF` trailer are
    -- the two things `looks_complete` reads.
    local fd = assert(io.open(path, "wb"))
    fd:write(body or "%PDF-1.4\n1 0 obj\n<<>>\nendobj\ntrailer\n<<>>\n%%EOF\n")
    fd:close()

    local headers = { ["content-type"] = "application/pdf" }
    headers["content-length"] = length
    return path, response(headers)
  end

  it("shows a document an earlier session left on disk, downloading nothing", function()
    local path, resp = on_disk("1234")
    local content = webpdf.preview(
      target,
      resp,
      { max_lines = 20, url_pdf_max_bytes = 25000000 },
      function() end
    )

    -- Not the placeholder: this went straight into the PDF previewer. What
    -- that previewer answers depends on whether pdfport and an image provider
    -- are installed, and the point here is only that nothing was fetched.
    local text = table.concat(content.lines, "\n")
    assert.is_nil(text:find("downloading", 1, true), "a cached document was downloaded again")
    assert.is_truthy(
      webpdf.cached(target),
      "a document on disk under its own key was not found by a later session"
    )
    assert.same(path, webpdf.cached(target))

    vim.fn.delete(path)
  end)

  it("throws away a half-downloaded document instead of serving it for a week", function()
    -- **The file this finds was written by a *previous* session**, and nothing
    -- else ever revisits it: curl's partial output is left at exactly this
    -- path when Neovim is killed, the machine sleeps, or the network goes.
    -- The completeness check used to run only after a download, so such a file
    -- was served from the cache until it aged out -- and `pdftoppm` failing on
    -- it reads as a broken renderer rather than as an interrupted download.
    --
    -- The declared length is over the cap, so what happens *after* the file is
    -- discarded is a refusal rather than a download: this spec needs no
    -- network to say that the discard happened.
    local path, resp = on_disk("99000000", "%PDF-1.4" .. string.rep("x", 64))
    local content = webpdf.preview(
      target,
      resp,
      { max_lines = 20, url_pdf_max_bytes = 25000000 },
      function() end
    )

    assert.is_nil(vim.uv.fs_stat(path), "a truncated document was left in the cache")
    assert.is_nil(webpdf.cached(target), "a truncated document was adopted as this link's page")
    local text = table.concat(content.lines, "\n")
    assert.is_truthy(
      text:find("links.pdf.max_bytes", 1, true),
      "a truncated file was handed to the rasterizer instead of being discarded"
    )
  end)

  it("does not take a stray file in its own directory for a hit", function()
    -- The cache is keyed by a digest of URL-and-length. A `.pdf` that merely
    -- sits in the directory -- a leftover, a half-swept file, something a
    -- reader dropped there -- is not this link's document, and serving it
    -- would show the wrong paper under the right URL.
    local root = vim.fn.stdpath("cache") .. "/hover.nvim/webpdf"
    vim.fn.mkdir(root, "p")
    local before = vim.fn.readdir(root)

    local pdf = root .. "/example.com-testfixture.pdf"
    local fd = assert(io.open(pdf, "wb"))
    fd:write("%PDF-1.4\n1 0 obj\n<<>>\nendobj\ntrailer\n<<>>\n%%EOF\n")
    fd:close()

    assert.is_nil(webpdf.cached(target), "a stray file in the directory was taken for a hit")

    vim.fn.delete(pdf)
    assert.same(#before, #vim.fn.readdir(root), "the fixture was left behind")
  end)
end)
