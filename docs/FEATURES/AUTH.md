# Authenticating to a host you named

Why a hover may carry a credential at all, why the rules are written so that
most mistakes make it send *nothing* rather than too much, and why the browser
render is the one request that never gets one. For *how* to set it, see
[configuration.md](../configuration.md); this page is the reasoning
underneath.

## What it is

`links.auth` names the hosts a hover may authenticate to, and with what:

```lua
links = {
  fetch = true,
  auth = {
    -- Confluence Cloud: the account email and an API token (HTTP Basic).
    { match = "acme.atlassian.net", user = "me@acme.com", token_env = "CONFLUENCE_TOKEN" },
    -- Data Center: a personal access token (Bearer).
    { match = "wiki.acme.com", token_env = "WIKI_PAT" },
  },
}
```

It reaches the two requests that are a `curl`: the fetch behind `links.fetch`
and the document download behind `links.pdf`. Nothing happens until
`links.fetch` is on — the credential rides requests that were already going
out, and adds none.

## What it does not do

**It does not make a Confluence page appear.** A Confluence Cloud page URL
(`/wiki/spaces/X/pages/123/Title`) answers with a JavaScript application, and
an authenticated request for it is still a JavaScript application — the header
changes who is asking, not what the server sends. What an authenticated
request *can* retrieve is a document: a link whose server answers
`application/pdf` (Confluence's PDF export of a page, an attachment) is
downloaded with the credential and shown as its first page by `links.pdf`. For
a page that has to be seen as it looks, [pins](PINS.md) are still the answer.

## The rules, and what each one prevents

**The token is never in the configuration.** `token_env` is the *name* of an
environment variable. A configuration is committed, pasted into issues and
read aloud; a variable name is none of those things. An unset variable sends
nothing — and does not fall through to the next rule, because "no token for
this host" is not "try another host's".

**The host part of a glob has no wildcard.** This is the rule the others lean
on. `*.atlassian.net` reads as "my Confluence" and means "every Atlassian Cloud
tenant" — including one an attacker owns and writes a link to. A rule that
breaks it is skipped, and `:checkhealth hover` says so. The path part may use
`*` freely (`acme.atlassian.net/wiki/*`). The match is `hover.pins.matches`,
the same glob [pins](PINS.md) use, whole-host and case-insensitive:
`acme.atlassian.net.evil.com` and `acme.atlassian.net@evil.com` match nothing.
**A port is part of the host here**: a rule for `wiki.acme.com` does not cover
`wiki.acme.com:8090`, because a credential for a host is not a credential for
every service listening on it. Name the port to cover it
(`wiki.acme.com:8090`). (A [pin](PINS.md), which sends nothing anywhere,
ignores a port its glob does not name.)

**A path-scoped rule is not crossed by `..`.** curl resolves `.` and `..` — and
`%2e` — in a path *before* it sends, so `/wiki/../other/x` matches a rule for
`acme.atlassian.net/wiki/*` as written and is requested as `/other/x`
(measured against a local server). For a glob with a path part, such a URL is
not covered; a later host-only rule still may be. A host-only rule means the
whole host and is not affected.

**HTTPS only.** A credential is never sent over `http://`, and a redirect may
only go to `https://` (`--proto-redir =https`). curl does not forward a
credential to a *different* host after a redirect on its own — that takes
`--location-trusted`. That can be switched on from outside (a
`location-trusted` line in your own `~/.curlrc`, which curl reads before the
command line — measured: the credential followed the redirect), so
`--no-location-trusted` is passed explicitly, ahead of `-L`.

**The link is not a pattern.** curl expands `[1-100]` and `{a,b}` in a URL into
one request each, and the link is text out of a document: `p[1-100000]` was
~3000 authenticated requests inside the 2 s fetch timeout. `--globoff` is
passed on both requests, whether or not a credential applies.

**A token is a single line.** Surrounding whitespace — the newline a file read
leaves — is trimmed. A control character left *inside* means it is not a token,
and nothing is sent: a CR or LF in a header value splits the request (measured:
the part after it arrives as a header of its own). `:checkhealth hover` reports
such a variable as unset.

**Never on a command line.** Any process on the machine can read another's
argv (`ps`, Process Explorer, WMI). The credential reaches curl through its own
`-K -` config on stdin — the path `lib.nvim.net.curl` already used — and the
download, which builds its own command line, does the same. A spec asserts the
token is in neither argv.

## Why `shot` is excluded

`links.shot` runs the page's own scripts in a browser, and every subresource
those scripts name is fetched from whatever host they name. A credential in
that process is a credential handed to a page — the exact situation a
throwaway browser profile exists to avoid (see [SHOT.md](SHOT.md)). The render
of an authenticated page stays what it was: the login form.

## What is written to disk

A downloaded PDF is cached under `stdpath("cache")/hover.nvim/webpdf` for
`links.pdf.cache_days`, like any other. A document you needed a token for is
therefore on disk for that long. On Linux and macOS the directory is mode
`0700` — `curl -o` creates the file `0644`, so the directory is what keeps other
local accounts out, and one an older version made `0755` is tightened. Windows
has no such bits. Lower `links.pdf.cache_days` (`1` is the shortest sweep) if
that is not acceptable.
`0` is not "keep nothing": the sweep treats a non-positive value as "do not
sweep", so the files stay until deleted by hand.
