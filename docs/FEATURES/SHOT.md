# Rendering a link, instead of reading it

Why a hovered link can be shown as a picture of the page, why that is a
different *category* from fetching rather than a louder setting of it, why it
needs a second switch where everything else needs one, and the protections
that are not optional. For *how* to use it, see [commands.md](../commands.md)
and [configuration.md](../configuration.md); this page is the reasoning
underneath.

## What it is

`:Hover links web shot` turns the URL preview from text into a picture: a
headless Chromium lays the page out at 1280×900, screenshots it, and the PNG
goes into the existing image pipeline — the same canvas sizing, the same
drawing, the same `>` crop and `h`/`j`/`k`/`l` panning a photograph gets. By
the time anything is on screen it is a picture, and nothing downstream knows
where it came from.

Off, the link is previewed as text: the status line, the title, the
description, and [the page's own prose](../configuration.md#the-twelve-switches).
Both exist because they answer different questions — *what does it say* against
*what does it look like*.

## Why it is not a setting of `fetch`

This is the distinction the whole design hangs on, and it is not a matter of
degree.

| | `links.fetch` | `links.shot` |
| --- | --- | --- |
| what runs | nothing | the page's own JavaScript |
| what is requested | one `curl` GET, 2 MB cap | the page **and every subresource it names** — fonts, frames, analytics, from whatever hosts they are on |
| what the host learns | one request | a browsing session |

So `shot` implies **`web`** and never `fetch`. A reader who turned fetching on
to ask "is this link still alive" must not thereby have turned on a browser,
and no arrangement of the switch table may allow it. The announcement says what
happens out loud for the same reason — this repository's rule is that a
disclosure is named where it is switched on, not in a document nobody has open
at that moment.

## Why the trigger gets a switch of its own

`links.shot.enabled` says a link *may* be rendered. `links.shot.eager` says the
**automatic trigger** may do it, rather than only `:Hover show`.

That is not belt and braces. Rendering a link you asked about is a decision;
rendering every link the cursor passes is a browser start per link, and
documentation is made of links. Measured 2026-09-04 on the machine this was
built on:

| | |
| --- | --- |
| browser start alone, `about:blank`, no network | **710, 715, 735 ms** (three runs) |
| a real documentation page | **3.9 s – 19.6 s** — the same URL, on different runs |

A page of fifty links, scrolled through, is fifty of those.

**`auto_hover.url` cannot say this**, which is the whole reason a second switch
exists rather than reusing the axis built for exactly this question. That axis
is keyed by *target type*, and the text preview and the screenshot are the same
type — so "text automatically, a picture only when asked" has no spelling on
it. `links.shot.eager` is that sentence.

## The protections, and why each one is not optional

**A throwaway profile.** Without `--user-data-dir` pointing somewhere
disposable, a headless Chrome can open the reader's *real* profile. Their
cookies would go to the hovered host, and whatever they are logged into would
be rendered into the picture. That flag is the difference between "render this
page" and "render this page as me", and it is the single most consequential
line in the module.

**No `--no-sandbox`.** It is the usual cure for a browser that will not start
in a container, and it is exactly wrong here: the page is untrusted by
construction, and the sandbox is what stands between it and the machine. A
setup that needs the flag can name a wrapper script through
`links.shot.command` — a decision the reader makes, not one the plugin makes
for them.

**One process at a time.** A request for another page kills the render still
running. A killed browser is cheaper than a second concurrent one, and the
generation counter already discards the answer.

**A second delay before the trigger commits.** `delay_ms` is 250 ms, which is
the right wait for a preview that costs nothing and the wrong one for 0.7 s of
process start plus up to twenty seconds of page. So the automatic path waits
`links.shot.delay_ms` (1000) of stillness *before anything is spawned*, and
moving on cancels it having spent nothing. An explicit request never waits —
that decision is already made, and making someone wait a second to confirm it
would be an apology for the wrong thing.

**Nothing is started for a picture that cannot be drawn.** With no image
provider, or `inline_images` off, the render would be twenty seconds spent on a
file the reader will never see. The check therefore comes *before* the browser
rather than after it, and the float says which of the two it was.

## Why 900 pixels tall and not the whole page

A full-page capture was the obvious default and is the wrong one, because what
decides whether a picture can be read is the **fit factor** — it is letterboxed
into the float, not cropped to it. On a 210×55 terminal a zen float is roughly
1850×970 px:

| capture | fits at | 16 px body text becomes |
| --- | --- | --- |
| 1280×900 | ~1.0 | 16 px — readable |
| 1280×4000 | 0.24 | 4 px — not |

So the default is the viewport: what the page looks like above the fold, at the
size it was designed for. Raise `links.shot.height` for a whole-page capture
and read it with `>` — the zoom *crops*, so a tall picture is exactly what it
is for.

This is also why [zen](ZEN.md) was built first. Without it the same arithmetic
against a default 80×20 float gives a fit factor of 0.38 and 6 px text, and the
feature would be one you had to zoom into shape after every open.

## Finding the browser

Any Chromium-based one answers — chrome, chromium, brave, msedge, searched in
that order, PATH first and then the usual install locations.

**The path search is not a convenience.** Measured on the Windows machine this
was built on: Chrome is installed at
`C:\Program Files\Google\Chrome\Application\chrome.exe` and `chrome` is on no
PATH at all, because the installer does not extend it. A PATH-only search
reports "no browser" on a machine with a browser plainly on it — the same false
alarm `soffice` already carries a note about in
[install.json](../install.json). `:checkhealth hover` therefore asks the
previewer rather than `PATH`, and names the binary it would actually run.
`links.shot.command` names one outright.

## The cache, and the one thing it gets wrong on purpose

Rendered pages live in `stdpath("cache")/hover.nvim/shots`, keyed by URL **and
geometry** — a capture at another size is a different picture, not a scaled
one, because the page lays itself out against the viewport. They outlive the
session, and `links.shot.cache_days` sweeps what has gone stale, once per
session, before the first render.

`preview/office.lua` keys its converted PDFs by path *and mtime*, so an edited
document converts again. **A URL has no mtime this side of a request**, so a
page that has since changed answers with the old picture until `cache_days`
expires or the switch is thrown. That is a real trade rather than an oversight:
the alternative is a conditional request per hover, which is the cost this
whole module is arranged around.
