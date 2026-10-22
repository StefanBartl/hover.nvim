---@module 'hover.preview.url'
---@brief URL hover preview: the parsed URL when the web hover is on, the
---server's answer when fetching is on too.
---@description
--- **Both levels are off by default, for two different reasons.**
---
--- `hover.url.hover` is off because dev documentation is *made* of links. A
--- hover that opens on every one of them turns reading a README into a
--- flickering slideshow, and the float lands over the text being read.
--- `:Hover links web on` is the reader saying "for the next while, links are
--- what I am interested in".
---
--- `hover.url.fetch` is off on top of that because fetching is a disclosure:
--- every link the cursor rests on becomes a request from this machine to that
--- host, and a document with fifty links becomes a request storm while
--- scrolling. With it on, the response's **status line comes first** — a
--- `404` or a `500` is the single most useful thing a hover can say about a
--- link — followed by `<title>`, `<meta name="description">`, the content
--- type, and — for an HTML page — **what the page actually says**.
---
--- **That last part is not a third switch, and deliberately so.** The body is
--- already downloaded: the title and the description are read out of it
--- either way. Turning it into prose costs no request, no round trip and no
--- second disclosure, so a switch for it would be a switch over something
--- already paid for. It is trimmed to whatever room the float has left, which
--- means `:Hover zen` over a link shows a screenful of the page rather than
--- twenty lines of it. See `M.page_text`.
---
--- Fetching goes through `lib.nvim.net.curl`, and results are cached by the
--- hover for the session: a URL is not re-fetched every time the cursor
--- passes it, which also means a server that has since recovered still shows
--- its old status until the cache is dropped (`:Hover links web off` / `on`
--- does that -- for every link but the ones kept on disk, below).
---
--- **The last raw answer is kept here as well, and for a different reason.**
--- That cache holds finished *content*, keyed by what a target is rather than
--- by how large it is being shown -- so `resize`, `zen` and `scroll` all
--- bypass it on purpose and rebuild, and for a URL that used to mean a fresh
--- request to that host on every keypress. One entry, dropped along with the
--- content cache, so the off/on gesture still retires a stale status. See
--- `_last`.
---
--- **A link the reader named in `links.cache.patterns` outlives the session.**
--- Its answer is written to disk (`hover.linkcache`), shown from there on the
--- next hover, and refreshed in the background once it is older than
--- `max_age_days`. Off by default, and without a pattern it does nothing.
--- The off/on gesture does not retire such a page -- the refresh does, and
--- `:Hover links cache clear` does at once.

local M = {}

---@internal
--- Split a URL into its parts without a URL library: enough for a display
--- line, not a spec-complete parser.
---@param url string
---@return table
local function split_url(url)
  local scheme, rest = url:match("^(%a[%w+.-]*):/?/?(.*)$")
  if not scheme then
    -- No scheme at all: `classify` only produces that for a `www.` host, so
    -- everything before the first `/` is the host.
    local host, path = url:match("^([^/]*)(.*)$")
    return { host = host, path = (path ~= "" and path or nil) }
  end

  -- mailto: and other non-hierarchical schemes have no host/path split.
  if scheme == "mailto" then
    return { scheme = scheme, host = rest }
  end

  local hostport, path = rest:match("^([^/]*)(.*)$")
  local path_part, query = (path or ""):match("^([^?]*)%??(.*)$")
  return {
    scheme = scheme,
    host = hostport,
    path = (path_part ~= "" and path_part or nil),
    query = (query ~= "" and query or nil),
  }
end

---@internal
--- Percent-decode for display. Reuses lib.nvim's decoder rather than a local
--- gsub so `+`-vs-`%20` handling matches everywhere else in the ecosystem.
---@param s string
---@return string
local function decode(s)
  local ok, enc = pcall(require, "lib.lua.strings.encoding")
  if ok and enc and enc.url_decode then
    local decoded_ok, decoded = pcall(enc.url_decode, s)
    if decoded_ok then
      return decoded
    end
  end
  return s
end

---@internal
--- Pull `<title>` and `<meta name="description">` out of an HTML body.
--- Deliberately pattern-based: a hover does not justify a real HTML parser,
--- and a miss degrades to "no title found" rather than being wrong.
---@param body string
---@return string|nil title
---@return string|nil description
local function extract_meta(body)
  local title = body:match("<title[^>]*>(.-)</title>")
  if title then
    title = decode(vim.trim(title:gsub("%s+", " ")))
    if title == "" then
      title = nil
    end
  end

  local description = body:match("<meta[^>]-name=[\"']description[\"'][^>]-content=[\"'](.-)[\"']")
    or body:match("<meta[^>]-content=[\"'](.-)[\"'][^>]-name=[\"']description[\"']")
  if description then
    description = decode(vim.trim(description:gsub("%s+", " ")))
    if description == "" then
      description = nil
    end
  end

  return title, description
end

---@internal
--- Named character references a documentation page actually produces, and
--- nothing else.
---
--- Deliberately a short list rather than the full HTML5 set of two and a half
--- thousand: the numeric forms below cover everything exotic, an unknown name
--- is left standing as written rather than turned into a question mark, and a
--- hover does not justify shipping a table it would read once.
---@type table<string, string>
local ENTITIES = {
  amp = "&",
  lt = "<",
  gt = ">",
  quot = '"',
  apos = "'",
  nbsp = " ",
  ensp = " ",
  emsp = " ",
  thinsp = " ",
  shy = "",
  hellip = "…",
  mdash = "—",
  ndash = "–",
  minus = "-",
  lsquo = "‘",
  rsquo = "’",
  ldquo = "“",
  rdquo = "”",
  laquo = "«",
  raquo = "»",
  bull = "•",
  middot = "·",
  times = "×",
  divide = "÷",
  deg = "°",
  copy = "©",
  reg = "®",
  trade = "™",
  euro = "€",
  pound = "£",
  yen = "¥",
  cent = "¢",
  sect = "§",
  para = "¶",
  dagger = "†",
  larr = "←",
  rarr = "→",
  uarr = "↑",
  darr = "↓",
  harr = "↔",
  ne = "≠",
  le = "≤",
  ge = "≥",
  plusmn = "±",
  frac12 = "½",
  frac14 = "¼",
  sup2 = "²",
  sup3 = "³",
}

---@internal
--- Character references resolved, in one pass.
---
--- **One `gsub` per form, and the named one last, because a pass does not
--- rescan what it wrote.** Decoding `&amp;` first would turn `&amp;lt;` --
--- which is how a page writes a *literal* `&lt;` -- into `&lt;` and then into
--- `<`, inventing markup that was never there.
---
--- `nr2char`'s second argument is `true` rather than the `1` a Vimscript
--- caller would write. Both work -- `vim.fn` hands a Lua boolean over as
--- `v:true` and the function only tests truthiness -- but the Lua meta
--- declares it `boolean?`, so `1` is a type error for an identical result.
--- Checked against an emoji, an ASCII character and a Latin-1 one: same
--- output either way.
---@param s string
---@return string
local function unescape(s)
  s = s:gsub("&#[xX](%x+);", function(hex)
    local cp = tonumber(hex, 16)
    return cp and vim.fn.nr2char(cp, true) or ""
  end)
  s = s:gsub("&#(%d+);", function(dec)
    local cp = tonumber(dec)
    return cp and vim.fn.nr2char(cp, true) or ""
  end)
  return (
    s:gsub("&(%a[%w]*);", function(name)
      return ENTITIES[name] or ("&" .. name .. ";")
    end)
  )
end

---@internal
--- Elements dropped with everything inside them. Not "not interesting" --
--- actively misleading: a nav block reads as a list of unrelated page
--- headings, and a `<script>` body is source code the reader did not ask to
--- see.
---@type string[]
local DROP = {
  "script",
  "style",
  "noscript",
  "template",
  "svg",
  "nav",
  "header",
  "footer",
  "aside",
  "form",
  "button",
  "select",
  "iframe",
  "figure",
}

---@internal
--- Elements whose boundary is a line break. Everything else collapses into
--- the run of text around it, which is what an inline element is.
---@type string[]
local BLOCK = {
  "p",
  "div",
  "section",
  "article",
  "main",
  "h1",
  "h2",
  "h3",
  "h4",
  "h5",
  "h6",
  "ul",
  "ol",
  "dl",
  "dt",
  "dd",
  "table",
  "tr",
  "blockquote",
  "pre",
  "figcaption",
  "hr",
}

---@internal
--- Where a list item opens and closes, carried through the flattening as two
--- characters no HTML document contains, each wrapped in its own line break
--- so it always lands alone on a split line.
---
--- **Sentinels rather than writing the bullet in directly**, which is what an
--- earlier version of this did and got wrong: `<li><p>text</p></li>` puts a
--- `</p>` between the marker and any text, and a bullet written in place of
--- `<li>` then sits alone on its own line with the paragraph one line below
--- it -- not attached to anything. Worse, an empty `<li></li>` (common in
--- menus rendered without JS) produced a bullet with nothing after it at all.
--- With both ends marked, "did this item ever get any text" is a fact carried
--- through the flattening rather than a guess made after it: closing without
--- having seen a line of content means no bullet is ever emitted for it.
local LI_OPEN, LI_CLOSE = "\1", "\2"

---@internal
--- How much of a page `page_text` carries into the *unsafe* half of its own
--- pipeline, in bytes -- the whitespace, list and block-break passes, the tag
--- strip, the entity decode. Roughly forty `gsub` calls live past this point,
--- and a 2 MB page (curl's own `--max-filesize`) run through all of them on
--- every keystroke of a hover is a stutter the reader would feel, on
--- Neovim's single main loop.
---
--- **Applied after `DROP` runs, not before, and that ordering is the point.**
--- Clamping the raw body first would mean a cut that lands inside a
--- `<script>` whose `</script>` is beyond the cut leaves that script's own
--- source sitting in the slice with no closing tag left for `DROP`'s match to
--- find -- so it would survive every later pass as plain text, which is
--- exactly the content this module exists to keep out. `DROP` runs against
--- the *full* body first and always finishes what it starts; only what is
--- left afterward -- ordinary markup, already past its most dangerous
--- content -- is ever clamped.
---
--- 512 KiB and not smaller: readable content sits at the top of a
--- well-formed document, well inside this, and past it the extraction is a
--- *degradation* -- "a miss degrades to less text, not to wrong text",
--- `M.page_text`'s own rule -- rather than a failure.
local SCAN_LIMIT = 512 * 1024

---@internal
--- `body`, cut to at most `limit` bytes and pulled back to the last complete
--- tag boundary if the cut landed inside one.
---
--- **The pullback is not cosmetic.** A slice that ends mid-`<a href="…`, with
--- no `>` in it, would leave that fragment sitting in the output once the
--- generic tag strip fails to find a close for it -- a stray `<a href="` a
--- reader cannot make sense of. Cutting back to the last `>` means every tag
--- in the slice is either whole or entirely absent, never half of one. Called
--- only after `DROP` has already run (see `SCAN_LIMIT`), so what a cut here
--- can ever land inside is ordinary content markup, not a `<script>` or
--- `<style>` body.
---@param body string
---@param limit integer
---@return string
local function clamp(body, limit)
  if #body <= limit then
    return body
  end
  local slice = body:sub(1, limit)
  local unterminated = slice:find("<[^>]*$")
  return unterminated and slice:sub(1, unterminated - 1) or slice
end

---@internal
--- Break `line` at `width` display columns, on word boundaries.
---
--- The float sets `wrap` and `linebreak`, so a long line *looks* right
--- already -- and the height would be wrong, because `float.measure` counts
--- entries in the list rather than the rows they occupy on screen. A
--- paragraph handed over as one string would be one row of float showing four
--- rows of text.
---
--- A single word wider than the box is handed over whole rather than cut:
--- cutting by columns means cutting inside a multi-byte character, and the
--- float wraps it correctly by itself. Only the *count* has to be right, and
--- one over-long word costs one row of accuracy.
---@param line string
---@param width integer
---@return string[]
local function wrap(line, width)
  local width_of = require("lib.lua.strings.width").display_width
  if width_of(line) <= width then
    return { line }
  end

  local out, current = {}, ""
  for word in line:gmatch("%S+") do
    local candidate = current == "" and word or (current .. " " .. word)
    if width_of(candidate) <= width then
      current = candidate
    else
      if current ~= "" then
        out[#out + 1] = current
      end
      current = word
    end
  end
  if current ~= "" then
    out[#out + 1] = current
  end
  return out
end

--- What the page actually says, as lines.
---
--- **Free, and that is why it is not a switch.** The body was already
--- downloaded -- `fetch` reads it for `<title>` and `<meta description>`
--- either way -- so this costs no request, no round trip and no second
--- disclosure. It is what `links.fetch` was paying for and then throwing
--- away.
---
--- **Pattern-based, deliberately, and the same argument `extract_meta` makes
--- one function up.** A hover does not justify an HTML parser, and the
--- failure mode is right: a page this reads badly produces prose with some
--- navigation in it, not an error. The reader still has the status line, the
--- title and the URL above it.
---
--- **The order is four decisions, and each one is silently reversible.**
--- Comments go first *and before the extract*, or a commented-out `</main>`
--- ends it at a boundary the author did not write. The dropped elements go
--- before the block breaks, because a `<nav>` that has already had its `</p>`s
--- turned into newlines is no longer one string to remove -- and, not
--- incidentally, before the clamp: see `SCAN_LIMIT` for why `DROP` always
--- finishes what it starts, on the full body, before anything is cut for
--- size. Source whitespace collapses before any break is inserted, or an
--- indented paragraph arrives as five lines. And entities go *last*, so a
--- decoded `&lt;` cannot be mistaken for a tag by the strip that follows.
---@param body string
---@param opts { max_width?: integer, max_lines?: integer }
---@return string[]
function M.page_text(body, opts)
  opts = opts or {}
  local max_width = opts.max_width or 80
  local max_lines = opts.max_lines or 20
  if max_lines < 1 then
    return {}
  end

  -- **Comments first, and before the extract rather than after it.** A
  -- commented-out `</main>` is ordinary in generated HTML, and it ends the
  -- match below at a boundary the author did not write -- so the extract would
  -- be the first paragraph of the page and nothing else, silently.
  local html = (body:gsub("<!%-%-.-%-%->", " "))

  -- `<main>` and `<article>` are the author saying which part of the page is
  -- the page. Where neither is marked up, `<body>` at least drops the head.
  html = html:match("<main[^>]*>(.-)</main%s*>")
    or html:match("<article[^>]*>(.-)</article%s*>")
    or html:match("<body[^>]*>(.-)</body%s*>")
    or html

  -- `%f[%W]` is the frontier: the tag name has to end where it is written, or
  -- `nav` would take `<navbar>` and `header` would take `<header-nav>` with it.
  for _, tag in ipairs(DROP) do
    html = html:gsub("<" .. tag .. "%f[%W][^>]*>.-</" .. tag .. "%s*>", " ")
    html = html:gsub("<" .. tag .. "%f[%W][^>]*/>", " ")
  end

  -- Every pass above ran against the full body, and finished: nothing that
  -- reaches here still has an unmatched `<script>`, `<style>` or any other
  -- `DROP` element in it, so cutting for size from this point on can never
  -- expose one mid-content. See `SCAN_LIMIT` and `clamp`.
  html = clamp(html, SCAN_LIMIT)

  -- **Every run of source whitespace becomes one space, before any break is
  -- inserted.** A newline in HTML is whitespace and nothing more -- an author
  -- who indents a paragraph over five lines wrote one paragraph -- so a
  -- newline that survives to the split below is indistinguishable from a break
  -- this function put there, and one paragraph arrives as five. `<pre>` loses
  -- its own line structure to this, which is the price: a hover is not a
  -- source viewer, and the alternative is that every ordinary page reads as
  -- ragged fragments.
  html = html:gsub("%s+", " ")

  -- A list is the one structure worth keeping, because losing it turns a list
  -- of options into a sentence that reads as nonsense. The marker goes in as
  -- a sentinel, not the bullet itself -- see `LI_OPEN`.
  html = html:gsub("<li%f[%W][^>]*>", "\n" .. LI_OPEN .. "\n")
  html = html:gsub("</li%s*>", "\n" .. LI_CLOSE .. "\n")
  html = html:gsub("<br%s*/?>", "\n")
  for _, tag in ipairs(BLOCK) do
    html = html:gsub("<" .. tag .. "%f[%W][^>]*>", "\n")
    html = html:gsub("</" .. tag .. "%s*>", "\n")
  end

  html = unescape((html:gsub("<[^>]*>", " ")))

  local out, in_item = {}, false
  for _, raw in ipairs(vim.split(html, "\n", { plain = true })) do
    -- One space for any run of whitespace: HTML's own rule, and what keeps a
    -- source file's indentation from arriving as a ragged left margin.
    local line = vim.trim((raw:gsub("%s+", " ")))
    if line == LI_OPEN then
      in_item = true
    elseif line == LI_CLOSE then
      -- Closed without ever seeing a line of text: no bullet was emitted for
      -- it, so there is nothing to undo -- `in_item` just stops applying to
      -- whatever line comes next, which was never part of this item.
      in_item = false
    elseif line ~= "" then
      if in_item then
        line = "• " .. line
        in_item = false
      end
      for _, piece in ipairs(wrap(line, max_width)) do
        out[#out + 1] = piece
        if #out >= max_lines then
          return out
        end
      end
    end
  end
  return out
end

---@internal
--- Elements `slim` removes before a body is written to disk: the ones
--- `page_text` drops anyway and that carry most of a page's bytes.
---
--- Not the whole of `DROP`: `<nav>` or `<header>` can hold the `<title>`
--- `extract_meta` reads, and `<svg>` has `<title>` elements of its own. A
--- kept body should read as the downloaded one did -- see `M.slim` for where
--- it may not.
---@type string[]
local SLIM = { "script", "style", "noscript", "template" }

--- `body` without what no preview of it ever shows: comments, scripts,
--- styles. What `hover.linkcache` keeps, so a 2 MB page of which 1.8 MB is
--- bundled JavaScript costs 200 KB on disk.
---
--- Comments go first, for the reason `page_text` gives: a commented-out
--- `</script>` would end a match early. **The self-closing form goes before
--- the pair**, or `<script src="a.js"/>` in the head would match up to the
--- next `</script>` and take the `<title>` between them along.
---
--- Not byte-for-byte the same reading in every case, and it does not try to
--- be: `extract_meta` reads the raw body, so a commented-out `<title>` wins
--- there and not here. The kept reading is the cleaner of the two.
---@param body string
---@return string
function M.slim(body)
  local out = (body:gsub("<!%-%-.-%-%->", " "))
  for _, tag in ipairs(SLIM) do
    out = out:gsub("<" .. tag .. "%f[%W][^>]-/>", " ")
    out = out:gsub("<" .. tag .. "%f[%W][^>]*>.-</" .. tag .. "%s*>", " ")
  end
  return out
end

---@internal
--- The reason phrase for a status code the server did not name itself. Only
--- the ones a link in a document actually produces — this is a hover, not an
--- HTTP reference.
---@type table<integer, string>
local STATUS_TEXT = {
  [200] = "OK",
  [201] = "Created",
  [204] = "No Content",
  [301] = "Moved Permanently",
  [302] = "Found",
  [304] = "Not Modified",
  [307] = "Temporary Redirect",
  [308] = "Permanent Redirect",
  [400] = "Bad Request",
  [401] = "Unauthorized",
  [403] = "Forbidden",
  [404] = "Not Found",
  [408] = "Request Timeout",
  [410] = "Gone",
  [418] = "I'm a teapot",
  [429] = "Too Many Requests",
  [500] = "Internal Server Error",
  [502] = "Bad Gateway",
  [503] = "Service Unavailable",
  [504] = "Gateway Timeout",
}

---@internal
--- Content type without its parameters, and the body size in bytes if the
--- server declared one — the two header facts that say what a link *is* when
--- there is no title to read (a PDF, a tarball, a JSON API).
---@param headers table<string, string>|nil
---@param body string|nil
---@return string|nil
local function type_line(headers, body)
  headers = headers or {}
  local ctype = headers["content-type"]
  if ctype then
    ctype = vim.trim(ctype:match("^([^;]+)") or ctype)
  end

  local length = tonumber(headers["content-length"]) or (body and #body or nil)
  local size
  if length then
    local ok, fmt = pcall(require, "lib.lua.strings.format")
    size = (ok and fmt and fmt.format_bytes) and fmt.format_bytes(length)
      or (tostring(length) .. " B")
  end

  if ctype and size then
    return ("%s · %s"):format(ctype, size)
  end
  return ctype or size
end

--- The always-available, offline preview: the URL taken apart.
---@param target Hover.Target
---@return Hover.Content
function M.offline(target)
  local parts = split_url(target.url or target.raw)
  local lines = {}

  if parts.host and parts.host ~= "" then
    lines[#lines + 1] = parts.host
  end
  if parts.path and parts.path ~= "/" then
    lines[#lines + 1] = decode(parts.path)
  end
  if parts.query then
    lines[#lines + 1] = "? " .. decode(parts.query)
  end
  if #lines == 0 then
    lines[#lines + 1] = target.raw
  end

  return { lines = lines, title = parts.scheme or "url" }
end

---@internal
--- One curl answer, turned into the float's content.
---
--- **Split out of the request so that a re-render can reach it without making
--- a second one.** The float is rebuilt from scratch on every `F`, `+`, `-`
--- and scroll -- `hover.cache` is keyed by what a target *is*, not by how
--- large it is being shown, so those bypass it deliberately -- and for a URL
--- that meant a fresh HTTP request to that host per keypress. Which is the
--- one thing this whole module is arranged to keep rare: fetching is called a
--- disclosure four paragraphs up, and zen turned "press a key at a link" into
--- the gesture that pays off.
---@param target Hover.Target
---@param opts Hover.PreviewOpts
---@param ok boolean
---@param response table|string|nil
---@return Hover.Content
local function content_for(target, opts, ok, response)
  local offline = M.offline(target)

  if not ok or type(response) ~= "table" then
    -- No status line at all: DNS failure, refused connection, TLS error, or
    -- the timeout. Distinguished from an HTTP error, because "the server said
    -- 500" and "there was no server" are different problems and the reader is
    -- about to act on one of them.
    local lines = { "✗ no answer" }
    local reason = type(response) == "string" and vim.trim(response:gsub("%s+", " ")) or nil
    lines[#lines + 1] = (reason and reason ~= "") and reason
      or ("unreachable, or slower than " .. tostring(opts.url_timeout_ms or 2000) .. " ms")
    for _, line in ipairs(offline.lines) do
      lines[#lines + 1] = line
    end
    return { lines = lines, title = offline.title, highlight = "HoverError" }
  end

  local status = tonumber(response.status) or 0
  local phrase = response.status_text
  if not phrase or phrase == "" then
    phrase = STATUS_TEXT[status] or ""
  end

  -- The status first, and on its own line. It is the answer to the question a
  -- reader hovers a link to ask -- "is this still there?" -- and burying it
  -- under a page title is what made the earlier version of this preview only
  -- decorative.
  local lines = { vim.trim(("HTTP %d %s"):format(status, phrase)) }

  local title, description = extract_meta(response.body or "")
  if title then
    lines[#lines + 1] = title
  end
  if description then
    lines[#lines + 1] = description
  end

  local ctype = type_line(response.headers, response.body)
  if ctype then
    lines[#lines + 1] = ctype
  end

  -- **What the page says, between the header block and the URL.**
  --
  -- Placed here rather than appended, and the reason is the float's height: it
  -- is `min(#lines, max_lines)`, so anything past the budget is not scrolled
  -- to, it is simply absent. Last would mean the URL parts push the text off a
  -- small float; below the text they are always the last thing in the box, and
  -- the *budget* is what the text is trimmed to.
  --
  -- Only `text/html`: a JSON API or a tarball has no prose in it, and running
  -- the tag stripper over one would produce a line of punctuation with the
  -- reader's cursor on it.
  local body = response.body
  if body and body ~= "" and (ctype or ""):find("text/html", 1, true) then
    -- One blank above, one below, and room for the URL that follows. Reads the
    -- box `opts` carries rather than the configured one, so a hover put full
    -- screen shows a screenful of the page and not twenty lines of it.
    local budget = (opts.max_lines or 20) - #lines - #offline.lines - 2
    local text = M.page_text(body, { max_width = opts.max_width or 80, max_lines = budget })
    if #text > 0 then
      lines[#lines + 1] = ""
      for _, line in ipairs(text) do
        lines[#lines + 1] = line
      end
    end
  end

  lines[#lines + 1] = ""
  for _, line in ipairs(offline.lines) do
    lines[#lines + 1] = line
  end

  return {
    lines = lines,
    title = title and "page" or offline.title,
    -- 4xx/5xx marked, so a dead link is recognizable without reading the
    -- number. 3xx is not an error: curl followed it, and what is shown is
    -- the destination's own status.
    highlight = (status >= 400 or status == 0) and "HoverError" or nil,
  }
end

---@internal
--- The last answer, and the URL it came from.
---
--- **One entry, and that is the whole eviction policy.** The case this exists
--- for is the float that is *open* being rebuilt at another size, so a second
--- entry would buy nothing and every entry costs up to the 2 MB
--- `--max-filesize` allows. Hovering another link drops it.
---
--- Dropped with `hover.cache`, which is what `:Hover links web off` / `on`
--- already does -- so the documented way to retire a stale status still
--- retires it. Without that hook this cache would outlive the gesture written
--- to defeat it.
--- `stale` marks an answer read from disk whose refresh is still out: what is
--- built from it is `transient` (see `transient`).
---@type { url: string, ok: boolean, response: table|string|nil, stale?: boolean }|nil
local _last = nil

---@type boolean Whether the drop above has been registered this session.
local _hooked = false

---@internal
--- Register the drop, once, on first use. Not at load: requiring this module
--- to look at it -- which the specs and the documentation checks do -- must
--- register nothing.
---@return nil
local function hook_reset()
  if _hooked then
    return
  end
  _hooked = true
  require("hover.cache").on_reset(function()
    _last = nil
  end)
end

---@internal
--- Hand one answer to whichever previewer it belongs to.
---
--- **Written once and called from both paths**, which is the point: the kept
--- response and a fresh one have to reach the same decision, and a document
--- answered as text on the second render would be the shape of every
--- hand-kept-copy bug in this repository.
---
--- A PDF goes to `preview.webpdf`, which may answer now or later; `on_result`
--- is handed straight through, so the placeholder and the page both arrive by
--- the same route `preview.office` uses.
---@param target Hover.Target
---@param opts Hover.PreviewOpts
---@param ok boolean
---@param response table|string|nil
---@param callback fun(content: Hover.Content)
---@return nil
local function answer(target, opts, ok, response, callback)
  if ok and opts.url_pdf and type(response) == "table" then
    local webpdf = require("hover.preview.webpdf")
    if webpdf.is_pdf(response) then
      callback(webpdf.preview(target, response, opts, callback))
      return
    end
  end
  callback(content_for(target, opts, ok, response))
end

---@internal
--- The request for `url`, and whether a credential went into it.
---@param url string
---@param opts Hover.PreviewOpts
---@return table request
---@return boolean authed
local function request_for(url, opts)
  local request = {
    method = "GET",
    timeout_ms = opts.url_timeout_ms or 2000,
    -- Follow redirects and ask for HTML; without an Accept header some hosts
    -- answer with an API representation that has no <title> at all.
    --
    -- `--globoff`: without it curl expands `[1-100]` and `{a,b}` in the URL
    -- into one request each, and the link is text out of a document. A hover
    -- on `p[1-100000]` was thousands of requests -- with a credential, each
    -- one authenticated.
    -- `--proto`/`--proto-redir`: a page may redirect to `ftp://`, `gopher://`
    -- or `file://`; only http(s) is followed.
    raw_args = {
      "-L",
      "--globoff",
      "--proto",
      "=http,https",
      "--proto-redir",
      "=http,https",
      "--max-filesize",
      "2000000",
    },
    headers = { Accept = "text/html,application/xhtml+xml" },
  }
  -- A host the reader named in `links.auth` gets its credential, over stdin
  -- and https only. See `hover.auth`.
  local authed = require("hover.auth").apply(url, request)
  return request, authed == true
end

---@internal
--- A kept entry in the shape curl answers with, so it takes the same road.
---@param entry Hover.LinkEntry
---@return table
local function response_of(entry)
  return {
    status = entry.status,
    status_text = entry.status_text,
    headers = vim.deepcopy(entry.headers or {}),
    body = entry.body,
  }
end

---@internal
--- `callback`, with the content marked `transient` on its way through.
---
--- A stale entry is shown while its refresh is out; `hover.cache` must not
--- keep what it built from it, or the next hover would answer from the
--- session's copy of the old page rather than ask again and find the new one.
---@param callback fun(content: Hover.Content)
---@return fun(content: Hover.Content)
local function transient(callback)
  return function(content)
    if type(content) == "table" then
      content.transient = true
    end
    callback(content)
  end
end

---@internal
--- Write a fresh answer to disk, when it is one worth keeping. A PDF is not:
--- `preview.webpdf` downloads it again to a file of its own, and its body as
--- curl handed it over is text-mangled (see `links.pdf` in `DEFAULTS.lua`).
---
--- **Never raises.** It runs inside curl's callback, ahead of the answer: a
--- cache directory that cannot be made (`E739`) or a body that cannot be
--- encoded must cost the cache, not the hover -- the float would otherwise
--- wait on its placeholder forever.
---@param url string
---@param response table|string|nil
---@return boolean written
local function remember(url, response)
  if type(response) ~= "table" or require("hover.preview.webpdf").is_pdf(response) then
    return false
  end
  local ok, written = pcall(function()
    return require("hover.linkcache").write(url, response, M.slim(response.body or ""))
  end)
  return ok and written == true
end

---@internal
--- Statuses that say "not now" rather than "not here": the old entry is the
--- better answer while they last.
---@type table<integer, boolean>
local TRANSIENT_STATUS = { [408] = true, [429] = true }

---@internal
--- What a revalidation came back with, as the response to show from now on,
--- or nil to keep showing the entry.
---
---   * 304: the entry, its clock moved.
---   * 2xx: the fresh answer -- written when it is one this cache keeps, and
---     the entry deleted when it is not (the page became a PDF, the write
---     failed), so a stale copy is not asked about on every hover.
---   * 4xx other than 408/429: the link is gone. The entry is deleted and the
---     404 is the answer -- a dead page must not keep saying 200.
---   * no answer, 5xx, 408, 429: nil. The outage is what the entry is for.
---
--- Never raises, for the reason `remember` gives.
---@param url string
---@param entry Hover.LinkEntry
---@param ok boolean
---@param response table|string|nil
---@return table|nil
local function settle(url, entry, ok, response)
  if not ok or type(response) ~= "table" then
    return nil
  end
  local store = require("hover.linkcache")
  local status = tonumber(response.status) or 0
  if status == 304 then
    pcall(store.confirm, url, entry)
    return response_of(entry)
  end
  if status >= 200 and status < 300 then
    if not remember(url, response) then
      store.remove(url)
    end
    return response
  end
  if status >= 400 and status < 500 and not TRANSIENT_STATUS[status] then
    store.remove(url)
    return response
  end
  return nil
end

---@internal
--- One background request for a stale entry, conditional when it can be.
---
--- The float on screen is left alone; the answer goes to disk and to `_last`,
--- so the next hover -- or a resize of this one -- shows it.
---@param curl table
---@param url string
---@param request table
---@param entry Hover.LinkEntry
---@return nil
local function refresh(curl, url, request, entry)
  local store = require("hover.linkcache")
  if not store.claim(url) then
    return
  end
  local conditional = vim.deepcopy(request)
  conditional.headers = vim.tbl_extend("force", conditional.headers or {}, store.validators(entry))
  local started = pcall(curl.fetch_raw, url, conditional, function(ok, response)
    store.release(url)
    local kept = settle(url, entry, ok, response)
    if kept and _last and _last.url == url then
      _last = { url = url, ok = true, response = kept }
    end
  end)
  -- A request that never started has no callback to release its claim.
  if not started then
    store.release(url)
  end
end

--- Fetch page metadata. Only called when `hover.url.fetch` is on.
---
--- The callback always receives content, never nil: a failed request is an
--- answer worth showing ("✗ no answer", and the URL that was tried), and a
--- nil would collapse into "no hover at all", which is indistinguishable from
--- the feature being off.
---
--- **The last answer is kept, and a repeat of it costs no request.** See
--- `_last`: a re-render is not a re-hover, and a keypress at a link is not a
--- second consent to tell that link's host about it.
---@param target Hover.Target
---@param opts Hover.PreviewOpts
---@param callback fun(content: Hover.Content)
---@return nil # The answer arrives through `callback`, never as a return value.
function M.fetch(target, opts, callback)
  local url = target.url or target.raw

  -- Only http(s) is fetchable; mailto:/file: and friends stay offline.
  if not url:match("^https?://") then
    callback(M.offline(target))
    return
  end

  -- The same link, answered again: `F` at a full-screen float, a resize step,
  -- a re-render after a switch that did not touch this preview. The body in
  -- hand is the answer, and `content_for` rebuilds against the *new* box, so
  -- the page text grows without a second request.
  if _last and _last.url == url then
    answer(target, opts, _last.ok, _last.response, _last.stale and transient(callback) or callback)
    return
  end

  local ok_curl, curl = pcall(require, "lib.nvim.net.curl")
  if not ok_curl then
    local content = M.offline(target)
    content.lines[#content.lines + 1] = "(lib.nvim.net.curl unavailable)"
    callback(content)
    return
  end

  hook_reset()

  local request, authed = request_for(url, opts)
  local store = require("hover.linkcache")
  local policy = opts.url_cache
  local keep = not authed and store.applies(url, policy)

  if keep then
    pcall(store.sweep, policy.max_age_days)
    local entry = store.read(url)
    if entry then
      local stale = store.stale(entry, policy)
      if not stale or policy.stale_ok ~= false then
        local response = response_of(entry)
        _last = { url = url, ok = true, response = response, stale = stale }
        if stale then
          refresh(curl, url, request, entry)
        end
        answer(target, opts, true, response, stale and transient(callback) or callback)
        return
      end
      -- Too old to show, and the reader said so (`stale_ok = false`): the
      -- same conditional request, in the foreground. Only when it brings
      -- nothing usable back -- no answer, a 5xx -- is the old entry shown
      -- after all, marked `transient`: an outage is the one time an old page
      -- beats an error.
      request.headers = vim.tbl_extend("force", request.headers, store.validators(entry))
      curl.fetch_raw(url, request, function(ok, response)
        local kept = settle(url, entry, ok, response)
        if kept then
          _last = { url = url, ok = true, response = kept }
          answer(target, opts, true, kept, callback)
          return
        end
        local old = response_of(entry)
        _last = { url = url, ok = true, response = old, stale = true }
        answer(target, opts, true, old, transient(callback))
      end)
      return
    end
  end

  curl.fetch_raw(url, request, function(ok, response)
    if keep and ok then
      remember(url, response)
    end
    -- Kept whether or not it worked. A host that does not answer costs the
    -- full timeout, and paying it again per keypress is the worse half of
    -- this: the float would go back to "rendering…" on every press.
    _last = { url = url, ok = ok, response = response }
    answer(target, opts, ok, response, callback)
  end)
end

--- Forget the last answer, so the next hover asks again. For the test suite,
--- and for anything that wants a fresh status without waiting for a switch.
---@return nil
function M.reset()
  _last = nil
end

return M
