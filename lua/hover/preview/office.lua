---@module 'hover.preview.office'
---@brief Office documents: a badge by default, the rendered first page when
---the reader has asked for it.
---@description
--- **Why an office document cannot be previewed the way a text file is.** A
--- `.docx` is a ZIP container of XML parts; a `.xlsx` and a `.pptx` are the
--- same idea with different parts; the legacy `.doc`/`.xls`/`.ppt` are
--- compound binary documents. There is no arrangement of "read the first
--- twenty lines" that produces anything a reader wants to see, on any
--- platform — which is what the hover used to do, and it showed mojibake with
--- the document's name in the border.
---
--- **The two honest answers, and why both exist.**
---
---  * **A badge** (default): "◆ Word document · DOCX · 24 KB", and no
---    pretence of a preview. Costs nothing, needs nothing installed, and is
---    correct on every machine.
---  * **The real first page** (`hover.office.convert`, off by default):
---    `pdfport.nvim` converts the document to a PDF through LibreOffice, and
---    from there it is a PDF hover — the same rasterize-and-draw path, and
---    the same paging keys. That means a LibreOffice start-up per document,
---    which is seconds rather than milliseconds, so it is opt-in and not the
---    default. `:Hover office on` switches it on for the session.
---
--- **Converted PDFs are kept, keyed by file and mtime, and outlive the
--- session.** The expensive part is LibreOffice starting, not the hover, and
--- a reader who looks at a document once will look at it again -- tomorrow as
--- well as in ten minutes. They live in `stdpath("cache")`.
---
--- They used to be deleted at `VimLeavePre`, which made the first document of
--- every session pay a LibreOffice start for nothing. The mtime in the key
--- already makes a kept file safe to serve: an edited document has a
--- different key and converts again. What kept them from surviving was not
--- correctness but the absence of an eviction policy, and a cache that only
--- grows is a bug with a slow fuse.
---
--- So: **age, swept once per session.** Anything older than
--- `office.cache_days` goes when the first conversion of a session runs.
--- Age rather than size, because the size of one converted PDF is bounded by
--- the document it came from -- the risk here is accumulation over months,
--- which age addresses directly and a size cap only indirectly. Setting it to
--- `0` restores the old behaviour of keeping nothing between sessions.

local M = {}

local uv = vim.uv or vim.loop

---@type table<string, string> Converted PDFs, keyed by source path + mtime.
local _pdfs = {}
---@type table<string, boolean> Conversions in flight, keyed the same way.
local _running = {}
---@type boolean Whether this session has already swept the cache directory.
local _swept = false

---@internal
--- Where converted PDFs live. One place, so `sweep` and `output_path` cannot
--- disagree about which directory this plugin owns.
---@return string
local function cache_dir()
  return vim.fn.stdpath("cache") .. "/hover.nvim/office"
end

---@internal
--- Identity of a document for the conversion cache. The mtime is in it so an
--- edited document is converted again rather than answered with last week's
--- page.
---@param path string
---@return string|nil
local function key_for(path)
  local st = uv.fs_stat(path)
  if not st then
    return nil
  end
  return path .. " " .. tostring(st.mtime and st.mtime.sec or 0)
end

---@internal
--- Where the converted PDF goes. Named after the document (so a stray file in
--- the cache directory is identifiable) plus a digest of the cache key (so two
--- documents with the same basename, and two versions of one document, do not
--- collide).
---@param path string
---@param key string
---@return string
local function output_path(path, key)
  local dir = cache_dir()
  vim.fn.mkdir(dir, "p")
  local stem = vim.fn.fnamemodify(path, ":t:r"):gsub("[^%w%-_]", "_")
  local digest = vim.fn.sha256(key):sub(1, 16)
  return ("%s/%s-%s.pdf"):format(dir, stem, digest)
end

---@internal
--- Delete converted PDFs older than `days`, once per session.
---
--- Only ever touches `*.pdf` directly inside this plugin's own cache
--- directory, and only files it could have written. A sweep that could reach
--- further would be a bad trade for saving a LibreOffice start.
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
--- Keep `pdf` for `key`. Nothing is deleted at exit any more -- see the
--- module header for why, and `sweep` for what takes its place.
---@param key string
---@param pdf string
local function remember(key, pdf)
  local previous = _pdfs[key]
  if previous and previous ~= pdf then
    pcall(os.remove, previous)
  end
  _pdfs[key] = pdf
end

---@internal
--- The badge, with whatever this module wants to say underneath it.
---@param target Hover.Target
---@param note string|nil
---@return Hover.Content
local function badge(target, note)
  return require("hover.preview.binary").badge(target, { note = note })
end

---@internal
--- Hand a converted PDF to the PDF previewer, as if the reader had hovered
--- the PDF itself. Everything past this point — rasterizing, sizing the
--- float, caching the page, paging — is `preview.media`'s, unchanged.
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

--- Preview an office document.
---
--- Contract matches `preview.media.pdf`: the returned content is what to show
--- *now* — final, or marked `pending` when something is on its way — and
--- `on_result` receives the real thing when it lands.
---@param target Hover.Target
---@param opts Hover.PreviewOpts
---@param on_result fun(content: Hover.Content): nil
---@return Hover.Content
function M.preview(target, opts, on_result)
  if opts.office_convert ~= true then
    -- The hint names the command rather than the config key: this float is
    -- being read by someone who just hovered a document and got a badge, and
    -- the next thing they can do about it is one command away.
    return badge(target, "no text preview  ·  :Hover office on")
  end

  local key = key_for(target.path)
  if not key then
    return badge(target, "(file vanished)")
  end

  -- Already converted, and the PDF is still on disk: straight into the PDF
  -- previewer, which may itself answer at once (page already rasterized) or
  -- go away and render.
  local pdf = _pdfs[key]
  -- Not in this session's table, but the file name is a pure function of the
  -- key -- so a conversion from an *earlier* session is findable by looking
  -- where it would be. This is what makes the cache outlive the session, and
  -- it is safe for the same reason the in-session hit is: the key carries the
  -- document's mtime, so an edited document asks for a different file.
  if not pdf then
    local candidate = output_path(target.path, key)
    if uv.fs_stat(candidate) then
      pdf = candidate
      _pdfs[key] = candidate
    end
  end
  if pdf and uv.fs_stat(pdf) then
    return page_of(target, pdf, opts, on_result)
  end
  if pdf then
    -- A temp sweeper took it. Not a cache entry any more, a dangling path.
    _pdfs[key] = nil
  end

  -- Once per session, before the first conversion: retire what has gone
  -- stale. Here rather than at startup, so a session that never hovers an
  -- office document never reads the directory at all.
  sweep(opts.office_cache_days)

  -- A conversion for this exact document is already running. Without this,
  -- every `CursorHold` while LibreOffice starts would start another one:
  -- the hover's own cache never holds a `pending` result, so the request
  -- arrives here again each time.
  if _running[key] then
    return vim.tbl_extend("force", badge(target, "converting to PDF…"), { pending = true })
  end

  local ok_pdfport, pdfport = pcall(require, "pdfport")
  if not ok_pdfport or type(pdfport.create) ~= "function" then
    return badge(target, "(pdfport.nvim not installed — no page preview)")
  end

  local ok_can, can_create = pcall(pdfport.can_create, "office")
  if not ok_can or not can_create then
    return badge(target, "(LibreOffice not on PATH — no page preview)")
  end

  local output = output_path(target.path, key)
  _running[key] = true

  pdfport.create({
    inputs = { target.path },
    output = output,
    -- Explicit rather than guessed from the extension: pdfport's own guesser
    -- knows the four modern formats, and this hover also reaches it with the
    -- legacy ones (`.doc`, `.xls`, `.ppt`) that LibreOffice converts just as
    -- happily.
    from = "office",
    on_conflict = "overwrite",
    opts = { timeout_ms = opts.office_timeout_ms or 60000 },
    __callback = function(result)
      -- The producer's callback lands from a libuv handle, where the autocmd
      -- and window calls downstream are not allowed.
      vim.schedule(function()
        _running[key] = nil

        if type(result) ~= "table" or result.status ~= "ok" or not result.path then
          local err = (type(result) == "table" and result.error) or "unknown error"
          on_result(badge(target, "(conversion failed: " .. err .. ")"))
          return
        end

        remember(key, result.path)
        local content = page_of(target, result.path, opts, on_result)
        -- `page_of` answers immediately when the page was already rasterized,
        -- and hands back a placeholder otherwise. Either is worth showing: by
        -- now the reader has waited through a LibreOffice start and silence
        -- would read as breakage.
        on_result(content)
      end)
    end,
  })

  return vim.tbl_extend("force", badge(target, "converting to PDF…"), { pending = true })
end

--- Drop the conversion cache (and the files). Tests, and anything that wants
--- the next hover to convert again.
---@return nil
function M.reset()
  for _, file in pairs(_pdfs) do
    pcall(os.remove, file)
  end
  _pdfs, _running = {}, {}
end

return M
