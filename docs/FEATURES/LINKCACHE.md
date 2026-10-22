# A fetched page kept across sessions

Why a page you hover ten times a day is kept on disk only once you name it,
why a kept page is shown at once even when it is old, why a dead link is the
one answer that throws a kept page away, and what is never written at all. For
*how* to set it, see [configuration.md](../configuration.md); this page is the
reasoning underneath.

## What it is

`links.cache` keeps the fetched text of the links you name on disk, so a
restart does not ask every host again:

```lua
links = {
  fetch = true,
  cache = {
    persist = true,
    patterns = { "docs.tricentis.com/*", "learn.microsoft.com/*" },
  },
}
```

A kept page is shown at once, from `stdpath("cache")/hover.nvim/links`. Once it
is older than `max_age_days` (7) it is **still** shown, and one request goes out
behind it. `:Hover links cache` says how many pages are kept and where;
`:Hover links cache clear` deletes them.

## Why it exists

Without it a fetched answer lives for the session: in `hover.cache`, the
preview LRU, and in the one raw response `preview/url.lua` keeps so a resize
costs no second request. A restart drops both. For product documentation,
which changes once a month and is hovered all day, that is one request per
hover per restart for an answer that was already known. It was asked for in
exactly those words: the same Tricentis and Microsoft pages, again and again.

## Why both halves are needed

`persist` is off, and `patterns` is empty, and **either alone keeps nothing**.
They answer two different questions. `persist` is "may anything be written to
disk at all"; `patterns` is "which links". A kept page sits in the cache
directory as plain text, so the links have to be named on purpose: there is no
host in the defaults, because what is worth keeping is the reader's call, not
this plugin's. `:checkhealth hover` names half a configuration, since from the
outside it looks exactly like a cache that does not work.

The patterns are the globs of [PINS.md](PINS.md), one matcher for both
features: `*` is the only wildcard and crosses `/`, a glob without `/` is about
the host alone, and scheme, case, `#fragment` and an unnamed port are ignored.
One glob or a list.

## Stale while revalidate

The choice was between showing an old page and making the reader wait for a
new one. A documentation page that is a week old is almost always still right,
and a hover that sits on "rendering…" for a round trip is the thing the cache
exists to remove. So the old page comes first:

- **Fresh** (younger than `max_age_days`): shown, no request.
- **Stale**: shown at once, and **one** background request goes out. A claim
  per URL keeps a second hover from sending a second one while the first is
  still out.
- **Conditional when it can be.** When the server gave an `ETag` or a
  `Last-Modified`, the request carries `If-None-Match` / `If-Modified-Since`,
  and an unchanged page costs a `304` and nothing else. The entry's clock
  moves; its content does not.
- **The float on screen is not rebuilt.** A float that changes under the
  reader while they read is worse than one that is a week old. The answer goes
  to disk and to the last-response slot, so the **next** hover shows it, and a
  resize of this one does too.

What is built from a stale page is marked `transient` and kept out of
`hover.cache`. Without that, the session's copy of the old page would answer
the next hover, and the refresh would have arrived for nothing.

`stale_ok = false` turns the background request into a foreground one: the
reader waits and sees the answer. Even then, when the request brings nothing
usable back (no answer, a 5xx, a 4xx other than 404/410/451, a curl that does
not start), the old page is shown, still `transient`. An
outage is the one time an old page beats an error.

## Why a dead link throws the page away

A refresh can come back with three kinds of answer, and they mean different
things:

| Refresh answer | What happens | Why |
| --- | --- | --- |
| `304` | clock moves, page stays, the validators it brings replace the kept ones | the server said so (RFC 9111, 4.3.4) |
| `2xx` | the new page is written | it is the new page |
| `404`, `410`, `451` | **the page is deleted**, the error is shown | the link is gone, and a deleted page must not keep saying `HTTP 200` |
| no answer, `5xx`, any other `4xx` | the old page stays | "later", or "not you", rather than "gone": the outage is what the page is kept for |

The first version kept the old page for every non-2xx answer. A review
reproduced the consequence: a deleted documentation page showed its old title
under `HTTP 200` forever, because every hover touched the file and the sweep
never got to it. "Is this link still there?" is the question a link hover is
asked, and the cache had made the answer wrong.

The second version deleted on every 4xx but 408 and 429, and a second review
pointed at the other side: Cloudflare and similar front ends answer curl with
a 403 challenge, and a lapsed single sign-on answers 401. Both would have
thrown a good page away for exactly the outage it is kept for. So only the
three statuses that mean "gone" delete.

A page refused with an HTTP error does not stay forever either: once the server
last confirmed it more than four times `max_age_days` ago, the error is the
answer and the page goes. No answer at all (offline) never deletes.

A request that is still out when `:Hover links cache clear` runs, a refresh or a
first fetch, writes nothing back: the cache counts its clears, and a refresh writes only when the
count is the one it started with.

## What is never written

- **Anything but a 2xx.** The header of `hover.cache` names the failure: a kept
  `500` keeps saying `500` after the server recovered. Errors are shown and
  forgotten with the session, as they were before.
- **A page fetched with a [`links.auth`](AUTH.md) credential.** That is private
  content, and this cache is plain files.
- **A URL with `user:pw@` in it.** The URL is part of the file's name and is in
  the file. A pin's glob ignores neither, so a pattern like `*.example.com/*`
  would otherwise have matched it. A token in the *query* is part of the URL
  and is kept with it, so do not name links that carry one.
- **A PDF.** [WEBPDF.md](WEBPDF.md) explains why the fetched body of a PDF is
  corrupted (`text = true`) and why the document is downloaded again to a file
  of its own. That file has its own cache.
- **Most of an HTML body.** Comments, `<script>`, `<style>`, `<noscript>` and
  `<template>` are removed first (`preview.url.slim`). Nothing the preview shows
  is in them, and on a modern documentation page they are most of the bytes. A
  body is kept only where the preview reads one: HTML, XHTML, XML proper (a media
  type ending in `/xml` or `+xml`: RSS, Atom, SVG) and an untyped answer that
  starts like markup. Not `xml` anywhere in the name -- the office formats
  (`application/vnd.openxmlformats-…`) are ZIP archives -- and not an untyped
  PDF or picture. Those keep status and headers only.
  The downloaded size is kept with it, so the size line reads the same from
  disk as it did from the network.
- **Any header but four**: `content-type`, `content-length`, `etag`,
  `last-modified`. A `Set-Cookie` has no business in a file.

## Why the sweep is by last use

The files are swept once per session, like the other caches here. A hit
touches the file, so the sweep sees **last use**, not age: a page in daily use
is never removed for being old, which is what stale-while-revalidate is for.
A page nobody hovered for **four times** `max_age_days` is deleted. The factor
is there so a page used once a fortnight is still refreshed conditionally,
for the price of a `304`, rather than fetched again from nothing.

## What the switches do not reach

`:Hover links web off` / `on` drops what the **session** holds, as it always
did. It no longer re-asks a kept page, because a kept page exists precisely to
outlive the session's stores. The refresh retires a stale page;
`:Hover links cache clear` retires all of them at once. It is a route of its
own rather than a switch, for the same reason.

## What no CI covers

The specs stub `lib.nvim.net.curl` and drive every row of the table above,
including that a stale hit sends exactly one request and that a `304` only
moves the clock. Not covered: a real server's `ETag` behaviour, and two Neovim
instances writing the same entry. The second heals itself (a half-written file
reads as a miss), but the temp-file name it goes through is shared, which is a
[lib.nvim](https://github.com/StefanBartl/lib.nvim) matter.
