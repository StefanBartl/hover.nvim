---@module 'hover.preview.webpdf'
---@brief A link that answers with a PDF, shown as its first page.
---@description
--- **The cheapest picture this plugin produces, and the one with the least new
--- machinery behind it.** Nothing is converted and nothing is rendered by this
--- module: the bytes at the other end of the link already *are* a PDF, so they
--- go into the pdfport/`pdftoppm` pipeline a local `.pdf` has always used --
--- the same rasterizing, the same paging keys, the same sharp zoom. This file
--- is a download and a cache, and then it hands over.
---
--- **Why the document is fetched a second time.** The plan for this said it
--- would need no request of its own, because `links.fetch` had already
--- downloaded the body. That was wrong, and the reason is worth keeping:
--- `lib.nvim.net.curl` runs `vim.system(..., { text = true })`, and that
--- option **replaces `\r\n` with `\n` in the output**. For HTML it is
--- invisible. For a PDF it is fatal -- a binary stream rewritten at every
--- `0D 0A` is a file `pdftoppm` will not open, and the failure would arrive
--- looking like a broken renderer rather than like a mangled download. So the
--- bytes never pass through Lua as text: `curl -o` writes them to the cache
--- file directly.
---
--- **And that second request is what makes the size cap answerable at all.**
--- A fetch is capped at 2 MB, which is right for a page and far too small for
--- a document. The content type is not known until the first response has
--- returned, so *one* request cannot carry both numbers -- but the second one
--- can, because by then the answer is known. `links.pdf.max_bytes` is that
--- number, and a document over it is refused rather than truncated: half a
--- PDF is not a smaller PDF, it is a file that will not open.
---
--- **The cache is keyed by URL and declared length**, which is weaker than the
--- path-and-mtime key `preview.office` uses and is the honest limit of what is
--- available: a URL has no mtime this side of a request. A document replaced
--- by one of a different size is fetched again; one replaced by an identically
--- sized file is not.
---
---@see hover.preview.url
---@see hover.preview.media

local M = {}

local uv = vim.uv or vim.loop

---@type table<string, string> Downloaded documents, keyed by URL and length.
local _pdfs = {}
---@type table<string, boolean> Downloads in flight, keyed the same way.
local _running = {}
---@type boolean Whether this session has already swept the cache directory.
local _swept = false

---@internal
--- Where downloaded documents live. One place, so `sweep` and `output_path`
--- cannot disagree about which directory this plugin owns.
---@return string
local function cache_dir()
  return vim.fn.stdpath("cache") .. "/hover.nvim/webpdf"
end

---@internal
--- Whether a response is a PDF, as the *server* describes it.
---
--- Read off the content type and nothing else -- not the URL's extension. A
--- `.pdf` in a path is the author's word for what a link points at, and this
--- module is about to spend a request and up to `max_bytes` on the answer, so
--- the server's word is the one worth acting on. The two disagree often enough
--- to matter: a download endpoint with no extension, a `.pdf` that 404s to an
--- HTML error page.
---@param response table|string|nil
---@return boolean
function M.is_pdf(response)
  if type(response) ~= "table" then
    return false
  end
  local headers = response.headers
  local ctype = type(headers) == "table" and headers["content-type"] or nil
  if type(ctype) ~= "string" then
    return false
  end
  return ctype:lower():find("application/pdf", 1, true) ~= nil
end

---@internal
--- The length the server declared, as a number, or nil when it declared none.
---@param response table
---@return integer|nil
local function declared_length(response)
  local headers = type(response.headers) == "table" and response.headers or {}
  return tonumber(headers["content-length"])
end

---@internal
--- Identity of a document: the URL, plus the length the server declared.
---
--- The length is the whole of what stands in for an mtime here. It is weak --
--- a replacement of exactly the same size is invisible to it -- and it is what
--- a response offers without asking for the document again.
---@param url string
---@param response table|nil
---@return string
local function key_for(url, response)
  local len = response and declared_length(response) or nil
  return ("%s %s"):format(url, len and tostring(len) or "?")
end

---@internal
--- Where the document goes. Named after the host so a stray file in the cache
--- directory is identifiable, plus a digest of the key so two documents on one
--- host, and two versions of one document, do not collide.
---@param url string
---@param key string
---@return string
local function output_path(url, key)
  local dir = cache_dir()
  vim.fn.mkdir(dir, "p")
  local host = (url:match("^https?://([^/]+)") or "page"):gsub("[^%w%-_.]", "_")
  return ("%s/%s-%s.pdf"):format(dir, host, vim.fn.sha256(key):sub(1, 16))
end

---@internal
--- Delete documents older than `days`, once per session. The same sweep
--- `preview.office` and `preview.shot` perform, on this module's own directory
--- and on `*.pdf` only.
---@param days integer
---@return nil
local function sweep(days)
  if _swept then
    return
  end
  _swept = true
  if type(days) ~= "number" or days <= 0 then
    return
  end

  local dir = cache_dir()
  local ok, entries = pcall(vim.fn.readdir, dir)
  if not ok or type(entries) ~= "table" then
    return
  end

  local cutoff = os.time() - days * 24 * 60 * 60
  for _, name in ipairs(entries) do
    if type(name) == "string" and name:sub(-4) == ".pdf" then
      local file = dir .. "/" .. name
      local st = uv.fs_stat(file)
      if st and st.mtime and st.mtime.sec < cutoff then
        pcall(os.remove, file)
      end
    end
  end
end

---@internal
--- Whether a file on disk is a PDF at all.
---
--- **A truncated download is the failure this catches, and it has to be caught
--- here** rather than left to `pdftoppm`: a half-written PDF produces a
--- rasterizer error, and a rasterizer error reads as "the PDF preview is
--- broken" rather than as "the file is incomplete". The header is the cheap
--- half of the check; `%%EOF` near the end is the half that says the transfer
--- finished.
---@param path string
---@return boolean
local function looks_complete(path)
  local fd = io.open(path, "rb")
  if not fd then
    return false
  end
  local head = fd:read(5)
  if head ~= "%PDF-" then
    fd:close()
    return false
  end
  -- The trailer is at the end, and `%%EOF` may be followed by a newline or
  -- two. A generous window costs one small read and avoids rejecting a
  -- perfectly good file over trailing whitespace.
  local size = fd:seek("end")
  fd:seek("set", math.max(0, size - 2048))
  local tail = fd:read(2048) or ""
  fd:close()
  return tail:find("%%%%EOF") ~= nil
end

--- The document for this target, if one is already on disk.
---
--- Never downloads anything, and that is the contract: `hover.scroll` and
--- `hover.zoom` ask this to decide whether a web link is currently a *paged*
--- document, and a question about capability must not have a thirty-second
--- answer.
---@param target Hover.Target
---@return string|nil path
function M.cached(target)
  local url = target.url or target.raw
  if type(url) ~= "string" then
    return nil
  end
  for key, path in pairs(_pdfs) do
    if key:sub(1, #url + 1) == url .. " " and uv.fs_stat(path) then
      return path
    end
  end
  return nil
end

---@internal
--- Hand a downloaded document to the PDF previewer, as if the reader had
--- hovered the file itself. Everything past this point -- rasterizing, sizing
--- the float, the page cache, paging, the sharp zoom -- is `preview.media`'s,
--- unchanged. The same move `preview.office` makes with its converted PDF.
---@param target Hover.Target
---@param pdf string
---@param opts Hover.PreviewOpts
---@param on_result fun(content: Hover.Content): nil
---@return Hover.Content
local function page_of(target, pdf, opts, on_result)
  local st = uv.fs_stat(pdf)
  ---@type Hover.Target
  local pdf_target = {
    type = "pdf",
    raw = target.raw,
    path = pdf,
    ext = "pdf",
    size = st and st.size or nil,
  }
  return require("hover.preview.media").pdf(pdf_target, opts, on_result)
end

---@internal
--- A line, and the URL underneath it, for every answer that is not a page.
---@param target Hover.Target
---@param note string
---@param pending? boolean
---@return Hover.Content
local function say(target, note, pending)
  local content = require("hover.preview.url").offline(target)
  table.insert(content.lines, 1, note)
  if pending then
    content.pending = true
  end
  return content
end

--- Drop the session's downloads and anything in flight. The files on disk are
--- left alone -- they are the cache, and `sweep` owns their lifetime.
---@return nil
function M.reset()
  _pdfs, _running = {}, {}
  _swept = false
end

--- Show a link that answered with a PDF as its first page.
---
--- Contract matches `preview.media.pdf` and `preview.office.preview`: the
--- returned content is what to show *now* -- final, or marked `pending` when
--- something is on its way -- and `on_result` receives the real thing when it
--- lands.
---@param target Hover.Target
---@param response table The response whose headers said `application/pdf`.
---@param opts Hover.PreviewOpts
---@param on_result fun(content: Hover.Content): nil
---@return Hover.Content
function M.preview(target, response, opts, on_result)
  local url = target.url or target.raw
  local key = key_for(url, response)

  -- Already downloaded, and still on disk: straight into the PDF previewer,
  -- which may itself answer at once (page already rasterized) or go away and
  -- render. This is what makes paging, resizing and zooming a web PDF cost no
  -- second download.
  local pdf = _pdfs[key]
  if not pdf then
    local candidate = output_path(url, key)
    if uv.fs_stat(candidate) then
      -- **Checked here and not only after a download, because the file this
      -- finds was written by a *previous* session.** A download that never
      -- finished -- Neovim killed, the machine asleep, the network gone --
      -- leaves curl's partial output at exactly this path, and nothing else
      -- ever revisits it. Unchecked it would be served from the cache for
      -- `cache_days` as a file `pdftoppm` cannot open, and the reader would
      -- see a broken renderer rather than an interrupted download.
      --
      -- The in-session entry below is not re-read: it was checked when it was
      -- written or when it was adopted here, and `preview` runs again on every
      -- page turn.
      if looks_complete(candidate) then
        pdf = candidate
        _pdfs[key] = candidate
      else
        pcall(os.remove, candidate)
      end
    end
  end
  if pdf and uv.fs_stat(pdf) then
    return page_of(target, pdf, opts, on_result)
  end
  if pdf then
    _pdfs[key] = nil
  end

  -- Refused before it is started, not after it has arrived. The number the
  -- reader has to change is named, because "too large" without it is a dead
  -- end.
  local cap = opts.url_pdf_max_bytes or 25000000
  local length = declared_length(response)
  if length and length > cap then
    local fmt = require("lib.lua.strings.format")
    return say(
      target,
      ("PDF, %s -- larger than links.pdf.max_bytes (%s)"):format(
        fmt.format_bytes(length),
        fmt.format_bytes(cap)
      )
    )
  end

  -- A download for this exact document is already running. Without this, every
  -- `CursorHold` while it runs would start another: a `pending` result is
  -- never cached, so the request arrives here again each time.
  if _running[key] then
    return say(target, "downloading the document…", true)
  end

  if vim.fn.executable("curl") ~= 1 then
    return say(target, "(curl is not on PATH, so the document cannot be downloaded)")
  end

  sweep(opts.url_pdf_cache_days)

  local out = output_path(url, key)
  _running[key] = true

  -- **`-o`, and no `text = true` anywhere near it.** The bytes go from curl to
  -- the file without passing through Lua, which is the entire reason this is a
  -- second request -- see the module header.
  local ok_spawn = pcall(vim.system, {
    "curl",
    "-sSL",
    "--max-filesize",
    tostring(cap),
    "--max-time",
    tostring(math.max(1, math.floor((opts.url_pdf_timeout_ms or 30000) / 1000))),
    "-H",
    "Accept: application/pdf",
    "-o",
    out,
    url,
  }, { text = false }, function()
    -- curl's exit lands in a fast event context, where reading a file and
    -- opening a window are both out of bounds.
    vim.schedule(function()
      _running[key] = nil

      if not uv.fs_stat(out) then
        on_result(say(target, "(the document did not download)"))
        return
      end
      if not looks_complete(out) then
        -- Left on disk it would be served from the cache for a week as a file
        -- that cannot be opened.
        pcall(os.remove, out)
        on_result(say(target, "(the download is not a complete PDF -- truncated, or not one)"))
        return
      end

      _pdfs[key] = out
      local content = page_of(target, out, opts, on_result)
      -- `page_of` answers at once when the page was already rasterized and
      -- hands back a placeholder otherwise. Either is worth showing: by now
      -- the reader has waited through a download.
      on_result(content)
    end)
  end)

  if not ok_spawn then
    _running[key] = nil
    return say(target, "(curl would not start)")
  end

  return say(target, "downloading the document…", true)
end

return M
