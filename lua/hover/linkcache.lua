---@module 'hover.linkcache'
---@brief The fetched text of a link, kept on disk across sessions, for the
---links the reader named.
---@description
--- `hover.cache` and the last answer `preview/url.lua` keeps both die with the
--- session. For a page that changes once a month and is hovered ten times a
--- day -- product documentation, mostly -- that is one request per hover per
--- restart, for an answer that was already known.
---
--- **Off, and empty, by default, and the two are separate on purpose.**
--- `links.cache.persist` is "may anything be written at all", `patterns` is
--- "which links". A page written here sits in the cache directory as plain
--- text, so the links have to be named: without a pattern nothing is stored,
--- whatever `persist` says. There is no host in the defaults -- what is worth
--- keeping is the reader's call, not this plugin's.
---
--- **The patterns are the globs `links.pins` uses** (`hover.pins.matches`):
--- `*` is the only wildcard, a glob without `/` is about the host alone, case,
--- scheme and `#fragment` are ignored. One matcher, one rule to remember, and
--- the one that is linear in the URL.
---
--- **Stale while revalidate.** An entry older than `max_age_days` is still
--- shown, at once, and one request goes out behind it. The answer is written
--- here and to `preview/url.lua`'s last answer, so the *next* hover shows it;
--- the float on screen is not rebuilt under the reader. When the entry carries
--- an `ETag` or a `Last-Modified`, the request is conditional, and a `304`
--- costs no page -- it only moves the entry's clock. `stale_ok = false` turns
--- the background request into a foreground one: the old entry is not shown,
--- the reader waits for the answer.
---
--- **Only a 2xx is written.** `hover.cache` names the reason in its header: a
--- kept 500 keeps saying 500 after the server recovered. A refusal, a 4xx or
--- a 5xx is shown and forgotten with the session, as before.
---
--- **Never for a link with a credential.** A page fetched through
--- `links.auth` is private content, and this cache is plain files.
---
--- **A link gone dead is not kept alive.** A refresh answered with 404, 410
--- or 451 deletes the entry and its answer is what the next hover shows -- a
--- deleted page must not keep saying 200. Every other answer that is not a
--- page leaves the old entry standing: a refused connection, a 5xx, and any
--- other 4xx (a 401 or 403 is as often a bot challenge or a lapsed sign-on as
--- a removal). That is the outage the cache is there to ride out.
---
--- **A clear stays a clear.** A refresh that was out when
--- `:Hover links cache clear` ran writes nothing back (`generation`).
---
--- **Never for a URL with credentials in it** (`https://user:pw@host/`): the
--- URL is the file's name and content. A token in the *query* is kept as part
--- of the URL, so a pattern should not name links that carry one.
---
--- **Only a body the preview reads is kept** (`keeps_body`): HTML, XHTML and
--- XML proper, and an untyped answer that starts like markup. Anything else --
--- JSON, an archive, a picture, an office document -- keeps its status and
--- headers and an empty body.
---
--- **A page that keeps refusing goes.** A refresh answered with an error other
--- than 404/410/451 keeps the page -- but not forever: once the server last
--- confirmed it more than four times `max_age_days` ago, the error is the
--- answer and the page is deleted (a page moved behind a sign-on for good would
--- otherwise say 200 for ever, every hover touching the file past the sweep).
---
--- The files are swept once per session by last use, not by age: a hit
--- touches the file, so an entry the reader keeps using is kept. One nobody
--- hovered for four times `max_age_days` goes; until then a stale entry is
--- still shown at once and refreshed behind it.
---
---@see hover.preview.url

local M = {}

local uv = vim.uv or vim.loop

---@type table<string, boolean> URLs with a revalidation in flight (fragment taken off).
local _refreshing = {}
---@type boolean Whether this session has already swept the directory.
local _swept = false
---@type integer Bumped by `clear`: a refresh that started before it must not write its answer back.
local _generation = 0
---@type string|nil The last write that failed, for `:checkhealth hover`.
local _last_error = nil

---@class Hover.LinkEntry
---@field url string
---@field status integer
---@field status_text string|nil
---@field headers table<string, string> Only the headers the preview reads, and the validators.
---@field body string
---@field checked_at integer When the server last confirmed this answer, epoch seconds.

---@class Hover.LinkCacheOpts
---@field persist boolean
---@field patterns string[]
---@field max_age_days number
---@field stale_ok boolean

---@internal
--- The headers worth keeping: what `preview/url.lua` shows, and the two the
--- next request is made conditional with. A `Set-Cookie` has no business in
--- a file.
---@type string[]
local KEPT = { "content-type", "content-length", "etag", "last-modified" }

--- Where entries live. Public for `:checkhealth hover` and the specs.
---@return string
function M.dir()
  return vim.fn.stdpath("cache") .. "/hover.nvim/links"
end

---@internal
--- How much longer than `max_age_days` an unused entry survives the sweep.
local SWEEP_FACTOR = 4

---@internal
--- `url` without its `#fragment`: curl never sends it, so `…/d#x` and
--- `…/d#y` are one page and one entry.
---@param url string
---@return string
local function key(url)
  return (url:gsub("#.*$", ""))
end

---@internal
--- The file for `url`: the host, so a file is identifiable, and a digest of
--- the whole URL, so two pages on one host do not collide.
---@param url string
---@return string
local function path_for(url)
  url = key(url)
  local host = (url:match("^https?://([^/?#]+)") or "page"):gsub("[^%w%-_.]", "_")
  return ("%s/%s-%s.json"):format(M.dir(), host, vim.fn.sha256(url):sub(1, 16))
end

---@internal
--- The directory, readable by this account only -- see `private_dir` in
--- `preview/webpdf.lua`, which this repeats for the same reason.
---@return nil
local function private_dir()
  local dir = M.dir()
  vim.fn.mkdir(dir, "p", "0700")
  if vim.fn.has("win32") == 1 then
    return
  end
  local st = uv.fs_stat(dir)
  if st and bit.band(st.mode, 63) ~= 0 then
    pcall(uv.fs_chmod, dir, 448)
  end
end

--- Whether `url` may be kept on disk under `opts`.
---@param url string
---@param opts Hover.LinkCacheOpts|nil
---@return boolean
function M.applies(url, opts)
  if type(opts) ~= "table" or opts.persist ~= true or type(url) ~= "string" then
    return false
  end
  local authority = url:match("^https?://([^/?#]*)")
  -- No scheme to match, or credentials in it: `user:pw@` would be written
  -- into the file's name and into the file.
  if not authority or authority:find("@", 1, true) then
    return false
  end
  local pins = require("hover.pins")
  for _, glob in ipairs(opts.patterns or {}) do
    if pins.matches(url, glob, { ignore_port = true }) then
      return true
    end
  end
  return false
end

--- Whether `entry` is older than `opts.max_age_days`.
---@param entry Hover.LinkEntry
---@param opts Hover.LinkCacheOpts
---@return boolean
function M.stale(entry, opts)
  local days = tonumber(opts.max_age_days) or 0
  return os.time() - (tonumber(entry.checked_at) or 0) > days * 24 * 60 * 60
end

--- The entry for `url`, or nil. A hit is touched, so the sweep sees it as used.
---@param url string
---@return Hover.LinkEntry|nil
function M.read(url)
  local path = path_for(url)
  if not uv.fs_stat(path) then
    return nil
  end
  local entry = require("lib.nvim.fs.json").read(path)
  -- The URL is in the entry so a digest collision, or a file renamed by
  -- hand, answers nothing rather than another page.
  if type(entry) ~= "table" or entry.url ~= key(url) or type(entry.body) ~= "string" then
    return nil
  end
  local now = os.time()
  pcall(uv.fs_utime, path, now, now)
  return entry
end

--- Write a response for `url`, if it is one worth keeping. Returns whether
--- anything was written.
---@param url string
---@param response table|string|nil
---@param body string The body as it is to be kept (see `preview.url.slim`).
---@return boolean
function M.write(url, response, body)
  if type(response) ~= "table" then
    return false
  end
  local status = tonumber(response.status) or 0
  if status < 200 or status >= 300 then
    return false
  end
  local headers = {}
  for _, name in ipairs(KEPT) do
    local value = type(response.headers) == "table" and response.headers[name] or nil
    if type(value) == "string" then
      headers[name] = value
    end
  end
  -- The size line reads `content-length`, and falls back to the body's own
  -- length -- which a kept body no longer has (`slim`, or no body at all).
  -- The downloaded length is what the first session showed.
  if not headers["content-length"] and type(response.body) == "string" then
    headers["content-length"] = tostring(#response.body)
  end
  if not M.keeps_body(headers["content-type"], body) then
    body = ""
  end
  private_dir()
  local ok, err = require("lib.nvim.fs.json").write(path_for(url), {
    url = key(url),
    status = status,
    status_text = response.status_text,
    headers = headers,
    body = body,
    checked_at = os.time(),
  })
  if ok ~= true then
    M.note_error(err or "write failed")
  else
    -- A write that works again is the answer to the one that failed.
    _last_error = nil
  end
  return ok == true
end

--- Whether a body of `content_type` is kept, rather than status and headers only.
---
--- Kept where the preview reads anything out of it: HTML and XHTML (the page
--- text, the title) and XML proper -- a media type ending in `/xml` or `+xml`
--- (RSS, Atom, SVG: a `<title>`). Not `xml` anywhere in the name: the office
--- formats (`application/vnd.openxmlformats-...`) are ZIP archives. An answer
--- that names no type at all (a static host, a bucket) is kept only when it
--- starts like markup and has no NUL byte: an untyped PDF or image must not be
--- stored as megabytes of text-mangled bytes.
---@param content_type string|nil
---@param body string|nil
---@return boolean
function M.keeps_body(content_type, body)
  local mt = (content_type or ""):lower():match("^%s*([^;%s]*)") or ""
  if mt ~= "" then
    return mt:find("html", 1, true) ~= nil or mt:match("[/+]xml$") ~= nil
  end
  if type(body) ~= "string" or body == "" then
    return false
  end
  local head = body:sub(1, 1024)
  return not head:find("%z") and head:match("^%s*<") ~= nil
end

--- Remember a failed write, for `:checkhealth hover`: the cache swallows them
--- (a hover must not fail over its cache), so this is where they are seen.
---@param err any
---@return nil
function M.note_error(err)
  _last_error = ("%s (%s)"):format(tostring(err), os.date("%Y-%m-%d %H:%M"))
end

--- The last write that failed this session, or nil.
---@return string|nil
function M.last_error()
  return _last_error
end

--- The current generation; `clear` moves it on. A request takes it when it
--- starts (a refresh and a first fetch alike) and writes only while it is
--- still the same.
---@return integer
function M.generation()
  return _generation
end

--- Delete the entry for `url`, if there is one: the link is gone, or its
--- answer is no longer one this cache keeps.
---@param url string
---@return nil
function M.remove(url)
  pcall(os.remove, path_for(url))
end

--- Move an entry's clock without touching its content: the server said 304.
---
--- The validators a 304 carries replace the kept ones (RFC 9111, 4.3.4): a
--- server that rotates its `ETag` would otherwise be asked with a stale one,
--- and every later refresh would cost a full page instead of a 304.
---@param url string
---@param entry Hover.LinkEntry
---@param response? table The 304.
---@return nil
function M.confirm(url, entry, response)
  entry.checked_at = os.time()
  local fresh = type(response) == "table" and type(response.headers) == "table" and response.headers
    or {}
  entry.headers = type(entry.headers) == "table" and entry.headers or {}
  for _, name in ipairs({ "etag", "last-modified" }) do
    if type(fresh[name]) == "string" then
      entry.headers[name] = fresh[name]
    end
  end
  private_dir()
  local ok, err = require("lib.nvim.fs.json").write(path_for(url), entry)
  if ok ~= true then
    M.note_error(err or "write failed")
  else
    _last_error = nil
  end
end

--- The request headers that make a refresh of `entry` conditional. Empty when
--- the server gave no validator, which makes the refresh a plain one.
---@param entry Hover.LinkEntry
---@return table<string, string>
function M.validators(entry)
  local out = {}
  local headers = type(entry.headers) == "table" and entry.headers or {}
  if type(headers.etag) == "string" then
    out["If-None-Match"] = headers.etag
  end
  if type(headers["last-modified"]) == "string" then
    out["If-Modified-Since"] = headers["last-modified"]
  end
  return out
end

--- Claim the one revalidation `url` may have in flight. False when another
--- one already has it.
---@param url string
---@return boolean
function M.claim(url)
  -- By the page, not the link: `…/d#a` and `…/d#b` are one entry and one refresh.
  url = key(url)
  if _refreshing[url] then
    return false
  end
  _refreshing[url] = true
  return true
end

--- Let go of the claim `claim` took.
---@param url string
---@return nil
function M.release(url)
  _refreshing[key(url)] = nil
end

---@internal
--- The files in this module's directory that end in `suffix`, as full paths.
---
--- The directory is checked first: `readdir` on one that does not exist yet
--- is not an error `pcall` catches, it prints E484 -- and a session that never
--- kept a page has no directory.
---@param suffix string
---@return string[]
local function files(suffix)
  local dir = M.dir()
  if not uv.fs_stat(dir) then
    return {}
  end
  local ok, entries = pcall(vim.fn.readdir, dir)
  if not ok or type(entries) ~= "table" then
    return {}
  end
  local out = {}
  for _, name in ipairs(entries) do
    if type(name) == "string" and name:sub(-#suffix) == suffix then
      out[#out + 1] = dir .. "/" .. name
    end
  end
  return out
end

--- Delete entries nobody hovered for `days`, once per session, and only
--- `*.json` files in this module's own directory.
---@param days number
---@return nil
function M.sweep(days)
  if _swept then
    return
  end
  _swept = true
  if type(days) ~= "number" or days <= 0 then
    return
  end
  local cutoff = os.time() - SWEEP_FACTOR * days * 24 * 60 * 60
  for _, file in ipairs(files(".json.tmp")) do
    -- A write a crash or a second instance left half done.
    local st = uv.fs_stat(file)
    if st and st.mtime and st.mtime.sec < os.time() - 60 * 60 then
      pcall(os.remove, file)
    end
  end
  for _, file in ipairs(files(".json")) do
    local st = uv.fs_stat(file)
    if st and st.mtime and st.mtime.sec < cutoff then
      pcall(os.remove, file)
    end
  end
end

--- How many entries are on disk, and their size in bytes.
---@return integer count
---@return integer bytes
function M.stats()
  local count, bytes = 0, 0
  for _, file in ipairs(files(".json")) do
    local st = uv.fs_stat(file)
    count = count + 1
    bytes = bytes + (st and st.size or 0)
  end
  return count, bytes
end

--- Delete every entry on disk, and any write a crash left half done.
--- `:Hover links cache clear`; the switches do not reach this, they drop what
--- the session holds.
---@return integer removed The entries deleted.
function M.clear()
  -- A refresh still out would otherwise write the entry it started from back.
  _generation = _generation + 1
  for _, file in ipairs(files(".json.tmp")) do
    pcall(os.remove, file)
  end
  local removed = 0
  for _, file in ipairs(files(".json")) do
    if os.remove(file) then
      removed = removed + 1
    end
  end
  return removed
end

--- Forget the session's state: the claims and the sweep. Files stay.
---@return nil
function M.reset()
  _refreshing = {}
  _swept = false
  _last_error = nil
end

return M
