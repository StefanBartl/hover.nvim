---@module 'hover.pins'
---@brief A link the reader has decided to show as a file of their own.
---@description
--- `links.pins` maps a URL glob to a local file, and a hovered link that
--- matches is previewed *as that file*: a PDF is paged and magnified, a
--- picture is drawn and cropped, exactly as if the link had pointed at it.
---
--- **The use is the page nothing can render.** A link behind a single
--- sign-on shows the login form, in the text preview and in the screenshot
--- alike -- the hover has no cookies, on purpose (see `hover.preview.shot`).
--- A reader who knows what the page looks like can print it to a PDF or a
--- PNG once, and pin it.
---
--- **A pin is a decision about what a link *is*, so it is made where the
--- link becomes a target.** `apply` runs inside the classification step of
--- `hover`, which is why nothing downstream knows: the preview, the cache,
--- the paging keys and the zoom all see an ordinary `pdf` or `image` target.
--- It is also why a pin needs no switch of its own -- nothing leaves the
--- machine, so there is no disclosure to announce and no cost to gate -- and
--- why it answers with `links.web` off: a pinned link is read from disk, and
--- the web switch is about requests.
---
--- **The match is a glob, not a Lua pattern.** One wildcard, `*`, which
--- matches any run of characters *including* `/` -- a URL has no path
--- hierarchy a reader would want a wildcard to stop at, and a rule with two
--- kinds of star is a rule nobody remembers. Everything else is literal,
--- `?` included, because that is the character a query string starts with.
---
---   * The scheme is ignored on both sides, and so is the `#fragment`.
---   * Case is ignored.
---   * A glob **without a `/`** is matched against the host alone:
---     `*.example.com` is every page on every subdomain, and
---     `example.com` is that host and nothing that merely starts with it.
---   * A glob **with a `/`** is matched against host, path and query:
---     `example.com/wiki/*`, or `example.com/view?id=42` for one page.
---   * **A pin ignores a port its glob does not name**: `example.com` covers
---     `example.com:8090`, which is where an intranet Confluence lives.
---     `matches` itself is strict about it, because `hover.auth` uses the
---     same function and a credential rule for a host is not a rule for
---     every service on that host.
---
--- The first pin that matches wins, in the order they are listed.
---
--- **The matcher does not backtrack.** The literals between the stars are
--- found left to right with a plain `find`, so the cost is linear in the URL.
--- A glob compiled to a Lua pattern was cubic with three stars, and the URL
--- it runs against is text out of a document the reader did not write.
---
---@see hover.classify

local M = {}

local uv = vim.uv or vim.loop
local expand_path = require("lib.nvim.cross.fs.expand_path")

---@internal
--- The parts of a URL a glob is matched against: lowercased, scheme and
--- fragment removed, and a path always present -- `https://example.com` and
--- `https://example.com/` are the same page and must not need two globs.
---@param url string
---@param ignore_port boolean Drop a trailing `:port` from the host.
---@return string host
---@return string full host, path and query
local function split(url, ignore_port)
  local rest = url:lower():gsub("^%a[%w+.-]*://", ""):gsub("#.*$", "")
  local host, tail = rest:match("^([^/?]*)(.*)$")
  if ignore_port then
    -- A trailing port only: never `user@`, never the inside of `[::1]`.
    host = host:gsub(":%d+$", "")
  end
  if tail == "" or tail:sub(1, 1) == "?" then
    tail = "/" .. tail
  end
  return host, host .. tail
end

---@internal
--- Whether `subject` matches `glob`, where `*` is the only wildcard and
--- matches any run of characters, empty included.
---
--- The first piece anchors the start, the last piece anchors the end, and the
--- pieces between are placed left to right. Taking the leftmost occurrence of
--- each is always safe for a pattern made only of literals and stars, so
--- there is nothing to backtrack over.
---@param subject string
---@param glob string
---@return boolean
local function glob_match(subject, glob)
  if not glob:find("*", 1, true) then
    return subject == glob
  end
  local parts = vim.split(glob, "*", { plain = true })
  local head, tail = parts[1], parts[#parts]
  if #subject < #head + #tail or subject:sub(1, #head) ~= head then
    return false
  end
  if tail ~= "" and subject:sub(-#tail) ~= tail then
    return false
  end
  local pos, limit = #head + 1, #subject - #tail
  for i = 2, #parts - 1 do
    local part = parts[i]
    if part ~= "" then
      local s, e = subject:find(part, pos, true)
      if not s or e > limit then
        return false
      end
      pos = e + 1
    end
  end
  return true
end

--- Whether `url` matches `glob`.
---
--- Public for the spec, and so a reader can ask the same question the hover
--- does before putting a pin in their configuration.
---@param url string
---@param glob string
---@param opts? { ignore_port?: boolean } A pin passes `true`; a credential rule must not.
---@return boolean
function M.matches(url, glob, opts)
  if type(url) ~= "string" or type(glob) ~= "string" or glob == "" then
    return false
  end
  local wanted = glob:lower():gsub("^%a[%w+.-]*://", ""):gsub("#.*$", "")
  if wanted == "" then
    return false
  end
  -- A port is ignored only when the glob does not name one itself, so
  -- `example.com:8090` still means exactly that port.
  -- A colon inside `[...]` is an IPv6 literal, not a port.
  local glob_host = (wanted:match("^([^/?]*)") or ""):gsub("%b[]", "")
  local ignore_port = opts ~= nil and opts.ignore_port == true and not glob_host:find(":", 1, true)
  local host, full = split(url, ignore_port)
  -- A glob that names no path is a statement about the host, and is compared
  -- with the host alone: otherwise `example.com*` would also catch
  -- `example.com.evil.net`, and `example.com` would match nothing at all.
  local subject = wanted:find("/", 1, true) and full or host
  return glob_match(subject, wanted)
end

---@internal
--- Where `show` is on disk. Relative paths are relative to the Neovim
--- configuration, since a pin is configuration and not part of any one
--- document -- resolving it against the file the link was found in would
--- make one pin mean a different file in every directory.
---@param show string
---@return string
local function resolve_show(show)
  local path = expand_path(show)
  if not (path:match("^/") or path:match("^%a:[\\/]") or path:match("^[\\/][\\/]")) then
    path = vim.fn.stdpath("config") .. "/" .. path
  end
  return vim.fs.normalize(path)
end

--- The configured pins, as written, minus the entries that cannot be used.
---
--- An entry needs a `show` and at least one `match`, both strings. A
--- malformed one is skipped rather than raised: the pin list is read on the
--- cursor-hold path, where an error is a stack trace on every pause.
--- `:checkhealth hover` names what was skipped.
---@return { match: string[], show: string }[]
function M.list()
  local links = require("hover.config").get().links
  local raw = type(links) == "table" and links.pins or nil
  local out = {}
  if type(raw) ~= "table" then
    return out
  end
  for _, pin in ipairs(raw) do
    local match = type(pin) == "table" and pin.match or nil
    if type(match) == "string" then
      match = { match }
    end
    if type(match) == "table" and type(pin.show) == "string" and pin.show ~= "" then
      local globs = {}
      for _, glob in ipairs(match) do
        if type(glob) == "string" and glob ~= "" then
          globs[#globs + 1] = glob
        end
      end
      if #globs > 0 then
        out[#out + 1] = { match = globs, show = pin.show }
      end
    end
  end
  return out
end

--- Whether any usable pin is configured.
---
--- The bare-URL source asks this: with `links.web` off it does not look for
--- URLs at all, and a pin on a URL the cursor can never find would do
--- nothing.
---@return boolean
function M.any()
  local config = require("hover.config")
  return config.links_enabled() and #M.list() > 0
end

--- The pin that `url` is covered by.
---@param url string
---@return { glob: string, show: string, path: string }|nil
function M.resolve(url)
  -- Only a URL with an authority has a host for a glob to be about.
  -- `mailto:a@b.example.com` has none, and the scheme is stripped only when
  -- it is followed by `//`, so `*.example.com` would otherwise pin an e-mail
  -- address (and `tel:`, `data:`, `javascript:`) to a file.
  if type(url) ~= "string" or not url:find("^%a[%w+.-]*://") then
    return nil
  end
  for _, pin in ipairs(M.list()) do
    for _, glob in ipairs(pin.match) do
      if M.matches(url, glob, { ignore_port = true }) then
        return { glob = glob, show = pin.show, path = resolve_show(pin.show) }
      end
    end
  end
  return nil
end

--- Whether a URL as written in a document is covered by a pin.
---
--- Asked in the form the classification will see: `http:\\host` is repaired
--- there, and a pin has to agree with it about what the URL is.
---@param raw string
---@return boolean
function M.covers(raw)
  local target = require("hover.classify").classify(raw, nil)
  return target.type == "url" and target.url ~= nil and M.resolve(target.url) ~= nil
end

--- Replace a classified URL with the file it is pinned to.
---
--- `raw` stays the link as written, so two different URLs pinned to one file
--- are still two targets for the dismissal and the "same hover" checks. The
--- original is kept in `pinned.url`, because the one thing a reader looking
--- at a stand-in for a page wants next is the page itself: `M.open` goes
--- there rather than to the file.
---
--- The file is classified with `classify.file`, **not** `classify.classify`:
--- the latter would read `//server/share/x.pdf` as a protocol-relative URL
--- and everything after a `#` in a file name as an anchor.
---@param target Hover.Target
---@return Hover.Target
function M.apply(target)
  if target.type ~= "url" or not target.url then
    return target
  end
  local pin = M.resolve(target.url)
  if not pin then
    return target
  end

  local classify = require("hover.classify")
  local pinned = classify.file(pin.path, target.raw)
  pinned.pinned = { url = target.url, glob = pin.glob, show = pin.show }
  if pinned.type == "missing" then
    -- Not a fall-through to the ordinary link preview. The reader said what
    -- this link shows; quietly showing a login page instead is the exact
    -- thing the pin was written to prevent, and it would hide that the file
    -- moved.
    pinned.reason = ("pinned file not found (links.pins: %s)"):format(pin.glob)
    -- What the file would have been, so the trigger can treat it like that
    -- file: a gone PDF is announced where a PDF would have opened, and a gone
    -- `.md` stays as quiet as a present one.
    local ext = pin.path:match("%.([%w]+)$")
    pinned.pinned.as = classify.kind_for_ext(ext and ext:lower() or nil)
  end
  return pinned
end

--- Whether the file a pin names exists. For the health report.
---@param show string
---@return boolean exists
---@return string path
function M.exists(show)
  local path = resolve_show(show)
  return uv.fs_stat(path) ~= nil, path
end

return M
