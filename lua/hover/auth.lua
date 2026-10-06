---@module 'hover.auth'
---@brief Credentials for the requests a hover makes to a host the reader named.
---@description
--- `links.auth` says which host a hover may authenticate to, and with what:
---
---     { match = "acme.atlassian.net", user = "me@acme.com", token_env = "CONFLUENCE_TOKEN" }
---
--- is HTTP Basic (what Confluence Cloud takes: account email and an API
--- token), and the same without `user` is `Authorization: Bearer` (what a
--- Data Center personal access token takes).
---
--- **Six rules, each of which is a way to leak the token if it were
--- otherwise.**
---
---  * **The token is never in the configuration.** `token_env` names an
---    environment variable. A configuration is read aloud, committed and
---    pasted into issues; a variable name is not a secret.
---  * **The host part of a glob has no wildcard.** `*.atlassian.net` would
---    hand the token to every Atlassian Cloud tenant -- including the one an
---    attacker writes a link to. The path part may use `*` freely; a rule that
---    breaks this is skipped, and `:checkhealth hover` says so.
---  * **HTTPS only.** Never sent over `http://`, and a redirect may only go to
---    `https://` (`--proto-redir =https`). curl does not forward the credential
---    to a *different* host after a redirect unless `--location-trusted` is on,
---    and that can be switched on from outside -- a `location-trusted` line in
---    the reader's own `~/.curlrc` -- so `--no-location-trusted` is passed
---    explicitly, ahead of `-L`.
---  * **A rule is matched against the path curl will send.** curl resolves `.`
---    and `..` (and `%2e`) before it sends, so `/wiki/../other/x` is requested
---    as `/other/x` and is out of a rule for `host/wiki/*`, while `/wiki/./x`
---    is requested as `/wiki/x` and is in it. A same-host redirect that
---    *starts* inside a path scope may still land outside it: the scope says
---    which URLs are asked for, not where the host sends them on.
---  * **A token is a single line.** Surrounding whitespace -- the newline a
---    file read leaves -- is trimmed; a control character left inside means it
---    is not a token, and nothing is sent. A CR or LF in a header value splits
---    the request.
---  * **Never in argv.** A process's command line is readable by every other
---    process on the machine. The credential goes through curl's `-K -`
---    config on stdin, the way `lib.nvim.net.curl` already sends one.
---
--- It covers what is a `curl` request: the fetch behind `links.fetch`, and
--- the document download behind `links.pdf`. It does **not** cover
--- `links.shot`, and that is deliberate: a browser running a page's own
--- scripts is exactly where a credential must not go. See
--- `docs/FEATURES/AUTH.md`.
---
---@see hover.preview.url
---@see hover.preview.webpdf

local M = {}

---@internal
--- Whether the host part of `glob` is a literal. The scheme is ignored, as it
--- is by `hover.pins.matches`, which decides what a glob matches.
---@param glob string
---@return boolean
local function literal_host(glob)
  local rest = glob:lower():gsub("^%a[%w+.-]*://", "")
  local host = rest:match("^([^/?#]*)")
  return host ~= nil and host ~= "" and not host:find("*", 1, true)
end

--- The configured rules, minus the entries that cannot be used safely.
---
--- A rule needs `match` (a glob or a list of them, every one with a literal
--- host) and `token_env` (a variable *name*). `user` is optional: with it the
--- credential is Basic, without it Bearer. A malformed rule is skipped rather
--- than raised -- this is read on the cursor-hold path -- and
--- `:checkhealth hover` names what was skipped.
---@return { match: string[], user: string|nil, token_env: string }[]
function M.list()
  local links = require("hover.config").get().links
  local raw = type(links) == "table" and links.auth or nil
  local out = {}
  if type(raw) ~= "table" then
    return out
  end
  for _, rule in ipairs(raw) do
    local match = type(rule) == "table" and rule.match or nil
    if type(match) == "string" then
      match = { match }
    end
    local env = type(rule) == "table" and rule.token_env or nil
    local user = type(rule) == "table" and rule.user or nil
    if
      type(match) == "table"
      and type(env) == "string"
      and env:match("^[%a_][%w_]*$")
      and (user == nil or (type(user) == "string" and user ~= ""))
    then
      local globs = {}
      for _, glob in ipairs(match) do
        if type(glob) == "string" and literal_host(glob) then
          globs[#globs + 1] = glob
        end
      end
      -- All or nothing: a rule with one bad glob among good ones is a rule the
      -- reader wrote carelessly, and a half-applied credential rule is the
      -- worse way to find out.
      if #globs == #match and #globs > 0 then
        out[#out + 1] = { match = globs, user = user, token_env = env }
      end
    end
  end
  return out
end

---@internal
--- The value of the variable `env`, as a credential: trimmed, or nil when it is
--- unset, empty, or still holds a control character after the trim.
---@param env string
---@return string|nil
local function read_token(env)
  local value = (vim.uv or vim.loop).os_getenv(env)
  if value == nil then
    return nil
  end
  value = value:match("^%s*(.-)%s*$")
  if value == "" or value:find("%c") then
    return nil
  end
  return value
end

---@internal
--- `url` with its path as curl will send it: `.` and `..` segments resolved
--- (RFC 3986), a `%2e` read as `.` -- both measured against curl 8.18 -- and
--- the query and fragment left alone.
---
--- The rules are matched against *this*, because the question a rule asks is
--- "is this request in my scope", and the request is the resolved one:
--- `/wiki/../other/x` is requested as `/other/x` and is out of a `/wiki/*`
--- rule, `/wiki/./x` is requested as `/wiki/x` and is in it. Skipping a rule
--- for any dot segment instead handed an in-scope request to the next, broader
--- rule, and past a rule whose unset variable meant "send nothing".
---@param url string
---@return string
local function curl_path(url)
  local origin, path, rest = url:match("^(%a[%w+.-]*://[^/?#]*)([^?#]*)(.*)$")
  if not origin then
    return url
  end
  local out = {}
  local segments = vim.split(path, "/", { plain = true })
  for i, segment in ipairs(segments) do
    local dots = segment:gsub("%%2[eE]", ".")
    local last = i == #segments
    if dots == "." then
      if last then
        out[#out + 1] = ""
      end
    elseif dots == ".." then
      -- Never above the root, which is the empty first segment.
      if #out > 1 then
        out[#out] = nil
      end
      if last then
        out[#out + 1] = ""
      end
    else
      out[#out + 1] = segment
    end
  end
  return origin .. table.concat(out, "/") .. rest
end

--- The credential for `url`, or nil.
---
--- The first rule that matches decides, even when its variable is unset: a
--- missing token means "no credential for this host", not "try the next
--- rule's".
---@param url string
---@return { user: string|nil, token: string }|nil
function M.for_url(url)
  if type(url) ~= "string" or not url:lower():match("^https://") then
    return nil
  end
  local pins = require("hover.pins")
  local resolved = curl_path(url)
  for _, rule in ipairs(M.list()) do
    for _, glob in ipairs(rule.match) do
      if pins.matches(resolved, glob) then
        local token = read_token(rule.token_env)
        if token == nil then
          return nil
        end
        return { user = rule.user, token = token }
      end
    end
  end
  return nil
end

--- Add the credential for `url`, when there is one, to the options of a
--- `lib.nvim.net.curl` request.
---
--- `lib.nvim.net.curl` sends `auth` and `bearer_token` through `-K -` on
--- stdin and never through argv. Redirects are limited to https.
---@param url string
---@param request table `fetch_raw` options, mutated
---@return boolean applied
function M.apply(url, request)
  local credential = M.for_url(url)
  if not credential then
    return false
  end
  if credential.user then
    request.auth = { user = credential.user, pass = credential.token }
  else
    request.bearer_token = credential.token
  end
  request.raw_args = request.raw_args or {}
  -- First, and ahead of `-L`: `--no-location-trusted` also clears
  -- follow-location, so one that came later would stop redirects altogether.
  -- It is here because a `location-trusted` line in the reader's `~/.curlrc`
  -- is read before this command line and would otherwise forward the
  -- credential across hosts.
  table.insert(request.raw_args, 1, "--no-location-trusted")
  vim.list_extend(request.raw_args, { "--proto-redir", "=https" })
  return true
end

--- The credential for `url` as a curl config, for a caller that builds its own
--- `curl` command line: `-K -` and this on stdin.
---@param url string
---@return string|nil config
function M.stdin(url)
  local credential = M.for_url(url)
  if not credential then
    return nil
  end
  local quote = require("lib.nvim.net.curl").config_quote
  if credential.user then
    return "user = " .. quote(credential.user .. ":" .. credential.token) .. "\n"
  end
  return "header = " .. quote("Authorization: Bearer " .. credential.token) .. "\n"
end

--- Whether the variable a rule names is set. For the health report, which
--- must say so without ever printing the value.
---@param env string
---@return boolean
function M.token_set(env)
  return read_token(env) ~= nil
end

return M
