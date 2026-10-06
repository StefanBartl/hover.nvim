# A link shown as a file of your own

Why the answer to a page nothing can render is a rule you write rather than a
better renderer, why the match is a glob with exactly one wildcard, and why it
is the only link feature here with no switch. For *how* to set it, see
[configuration.md](../configuration.md); this page is the reasoning
underneath.

## What it is

`links.pins` maps a URL glob to a file, and a hovered link that matches is
previewed **as that file**:

```lua
links = {
  pins = {
    { match = "confluence.example.com/display/TEAM/*", show = "~/shots/team.pdf" },
    { match = { "wiki.example.com/a", "wiki.example.com/b" }, show = "~/shots/wiki.png" },
  },
}
```

A PDF is paged and magnified, a picture is drawn and cropped, exactly as if
the link had pointed at it. `<CR>` on the float still opens the **real URL**,
because the one thing a stand-in cannot do is be the page.

## Why it exists

A link behind single sign-on shows the login form — in the text preview *and*
in the screenshot. The hover has no cookies, and that is deliberate: the
browser `shot` starts is given a throwaway profile, because without one it
would render the reader's logged-in pages (see [SHOT.md](SHOT.md)). So no
amount of better rendering fixes it; the hover is, correctly, anonymous.

A reader who knows what the page looks like can print it to a PDF or a PNG
once and say so. That is the whole feature.

## Where it is decided

**Inside the classification**, once, where a found string becomes a target. A
matching URL comes out as a `pdf` or `image` target that carries
`pinned = { url, glob, show }`, and from there nothing knows: the preview, the
cache, the paging keys and the zoom all see an ordinary local file. That is
why there is no renderer in `hover.pins` and why it needed no change to any
previewer.

`:Hover why` says when a pin is what a hover is showing.

## Why it has no switch

Every other link feature here is a switch because it costs something: a
request, a browser, a disclosure. A pin reads a file from disk. There is
nothing to announce and nothing to gate — and for the same reason it answers
with `links.web` **off**. The web switch is about requests, and a pinned link
makes none.

The consequence is in the bare-URL source, which does not look for URLs at all
while `web` is off. With a pin configured it does, because a pin on a URL the
cursor can never find would do nothing. An *unpinned* URL found that way is
still refused one step later, so `web = false` keeps meaning what it meant.

## Why the match is a glob, and a small one

A Lua pattern was the obvious choice in a Lua plugin and the wrong one for
this reader: `-` and `.` are magic, and a URL is made of both. A glob with one
wildcard has nothing to remember.

- **`*` matches anything, `/` included.** A URL has no hierarchy a reader
  wants a wildcard to stop at, and two kinds of star is a rule nobody
  remembers.
- **`?` is literal.** It is where a query string starts.
- **Scheme, `#fragment` and case are ignored**, on both sides.
- **A glob without a `/` is a host**, compared whole. `example.com` matches
  that host and *not* `example.com.evil.net`; `*.example.com` is every
  subdomain. A glob with a `/` is compared against host, path and query:
  `example.com/wiki/*`, or `example.com/view?id=42` for one page.

The first pin that matches wins, in the order written. A configured list
**replaces** the default rather than merging into it: merged by index, a
shorter list given to a second `setup()` would leave the first call's
remaining rules in force.

`require("hover.pins").matches(url, glob)` answers the same question the hover
does, for trying a glob before putting it in a configuration.

## What `show` means

`~` and environment variables are expanded. A **relative** path is relative to
the Neovim configuration — not to the document the link is in, which would make
one pin mean a different file in every directory.

The extension decides the preview, so what a pin can show is what a link can:
`.pdf`, an image, an office document, a video, markdown. Only `pdf` and `image`
open by themselves (`auto_hover`); the rest open on `:Hover show`, as they do
for a link that points at them.

## When the file is gone

The float says `pinned file not found (links.pins: <glob>)`. It does **not**
fall back to the link's own preview, and that is the point of the rule: the
page a pin exists for is the one whose own preview is a login form, and quietly
showing it would hide that the file moved. `:checkhealth hover` lists every
pin whose file does not exist, so it is learned there rather than by hovering
each link in turn.
