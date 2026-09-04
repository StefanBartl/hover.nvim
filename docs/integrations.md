# How the hover is wired to the rest of the ecosystem

[`hover.nvim`](../README.md) draws one float and knows almost nothing. Nearly
everything interesting in it — reading a markdown link, resolving a truncated
path, turning a `.png` into pixels, turning page 3 of a PDF into a `.png` — is
somebody else's job, done by a sibling plugin that may or may not be
installed.

This file is the map: **who reaches whom, through which door, and what
degrades when a plugin is absent.** It exists because "the hover is broken" is
almost never a statement about the hover — it is a statement about one of the
plugins, and the first useful question is which one.

## The two doors

There are exactly two ways a plugin and the hover reach each other, and they
are not interchangeable.

**Door 1 — the registry (inbound).** The plugin calls
`hover.registry.register(name, contribution)` and hands over a
*source* ("what is under the cursor?") or a *preview* ("how do I render a
target of this type?"). hover.nvim never says the plugin's name. Adding another
contributor requires no change here at all.

**Door 2 — a named soft dependency (outbound).** hover.nvim itself calls
`pcall(require, "images.info")`, `pcall(require, "pdfport")`,
`pcall(require, "gopath.resolve")` — by name, from inside its own preview
code, guarded so a missing plugin is a `nil` rather than an error.

A `sources` or `positions` entry may also be a table —
`{ fn = …, on_request = true }` — which asks to be consulted only for an
explicit request. That is for a contribution whose answer costs a process
start; see [api.md](api.md#when-your-answer-is-expensive).

Door 1 is the better shape; door 2 is the honest one. A *capability* can be
registered: "here is a function that previews an anchor" says everything the
framework needs to know. A *renderer* cannot, because the hover has to
negotiate with it — measure a picture, subtract the drawing inset, hand back a
geometry, defer a draw by one tick, clear the terminal on close. That is a
conversation with one specific API, not a callback, and pretending otherwise
would put an images.nvim-shaped interface into a library that would then have
exactly one implementor. So the registry carries what generalises, and the
rest is a `pcall` with a fallback underneath it.

Practical consequence, and the reason this file exists: **a plugin can be
listed as a contributor and still not be the cause of a bug you are looking
at.** Door 2 plugins are named inside hover.nvim's own source, so their names
turn up in comments, module docs and stack traces belonging to code they never
ran.

## Door 1 is not only for plugins

Nothing about the registry requires a plugin around it. `hover.registry.register`
is a public module and behaves identically when it is called from an `init.lua`,
and `setup` takes the same contribution table as a `contribute` field:

```lua
require("hover").enable({
  contribute = {
    positions = {
      function(bufnr, row, col)
        return something_about(bufnr, row) -- or nil to stay silent
      end,
    },
  },
})
```

The one difference that matters here is the **name**. A plugin passes its own,
so it owns a slot and re-registering replaces only its own contribution;
everything registered through `contribute` shares the single name `user`. That
is the right trade for a configuration — there is one of it, and reloading it
must replace rather than duplicate — and the wrong one for a plugin, which
would be deleting a contribution that is not its own.

`:checkhealth hover` reads the registry back under *optional contributors*, so
`registry: user -- 1 position preview` is the confirmation that a contribution
arrived — and its absence from that list is the confirmation that it did not.

So the table below lists who *ships* a contribution, not what is able to make
one. See [the registry API](api.md#the-registry) for the whole shape,
including `on_request` for an answer that costs a process start.

## Who is wired to what

| Plugin | Door | Contributes | Without it |
| --- | --- | --- | --- |
| [markdown.nvim](https://github.com/StefanBartl/markdown.nvim) | registry | link / `<figure>` scanning; `#heading` section previews | only bare paths start a hover; `file.md#frag` shows the file's head, not that section |
| [gopath.nvim](https://github.com/StefanBartl/gopath.nvim) | named | resolving truncated paths and `:line:col` suffixes | ordinary relative and absolute paths still resolve; truncated ones do not |
| [open.nvim](https://github.com/StefanBartl/open.nvim) | named | routing `gf` from the float to the right destination -- a browser for a URL, the configured file manager for a path | `vim.ui.open` opens it instead, letting the OS decide |
| [images.nvim](https://github.com/StefanBartl/images.nvim) | named | drawing the picture into the float (OSC 1337) | an image target shows format, dimensions and size as text |
| [pdfport.nvim](https://github.com/StefanBartl/pdfport.nvim) | named | rasterizing a PDF page to PNG, and a *window* of one at a higher DPI for the zoom; converting an office document to a PDF (opt-in) | a PDF shows its size and why it could not be rendered; a `.docx` shows what it is and how big; `:Hover zoom` says a page cannot be magnified |
| [reposcope.nvim](https://github.com/StefanBartl/reposcope.nvim) | registry | `owner/repo` under the cursor, as the path of its cached README | no repository hover |
| [migrate.nvim](https://github.com/StefanBartl/migrate.nvim) | registry | a *position* preview: this line uses a deprecated API, and what replaces it | no deprecation notice in the float |
| [documentation.nvim](https://github.com/StefanBartl/documentation.nvim) | registry | a *position* preview: what the dotted module under the cursor is, out of the generated map | no module summary |
| [spotlight.nvim](https://github.com/StefanBartl/spotlight.nvim) | registry | a *position* preview: how often a spotlighted token occurs in this buffer | no occurrence count |
| [insights.nvim](https://github.com/StefanBartl/insights.nvim) | registry | a *position* preview: which files import the module under the cursor, out of its own remembered scan | no importer list in the float |
| [sandbox.nvim](https://github.com/StefanBartl/sandbox.nvim) | registry | a *position* preview, **request-only**: whether the container image under the cursor is pulled, how big it is, and what runs from it | no image hover |
| [language.nvim](https://github.com/StefanBartl/language.nvim) | registry | a *position* preview, **request-only**: the word under the cursor, translated | no translation in the float; `:Translate <lang> cword` still answers |

All of them are optional and **none is required**. With none installed the
hover still gives file heads, directory listings, image and PDF metadata, a
badge for files that hold no text, URL details once the web hover is switched
on, and the "this target does not exist" answer.

## markdown.nvim — link scanning, and the section behind a `#heading`

Registered from `markdown/hover/init.lua` under the name `"markdown.nvim"`:

| Kind | Key | Implementation |
| --- | --- | --- |
| source | — | `markdown.core.link_scan.from_line` — a link whose span contains the cursor |
| source | — | `markdown.core.html_links.figure_at` — the enclosing `<figure>`, so a `<figcaption>` hovers like the picture it captions |
| preview | `anchor` | `markdown.hover.section.anchor` — an in-page `#heading`, read out of the hovered buffer |
| preview | `markdown` | `markdown.hover.section.file_anchor` — `file.md#heading`; returns `nil` when there is no fragment, and the library's own file preview runs instead |

markdown.nvim also calls `require("hover").enable()` from
`markdown/bindings/autocmds.lua`. That is a convenience, not the intended
switch: markdown.nvim is normally `ft`-lazy, so in a session that never opens
a `.md` file nothing would ever turn the hover on, and a path in a `.txt` or a
code comment would silently do nothing. Call `enable()` from a spec that is
not lazy-loaded — see [installation.md](installation.md).

Registration is keyed by plugin name, so a second `setup()` replaces this
contribution rather than stacking a second link scanner onto every hover.

## gopath.nvim — resolving the paths `<cfile>` cannot

One call, from [`bare_path.lua`](../lua/hover/bare_path.lua):

```lua
require("gopath.resolve").resolve_at_cursor()  --> { kind, path, exists, … }
```

It handles what `<cfile>` cannot: a truncated path (`...nvim/init.lua`,
`…/lua/config/init.lua`), a `:line:col` suffix, a path findable only through
`&path` / `rtp` / a tail search. That is precisely the "a path in `:messages`
should hover too" case, and it is gopath's whole subject matter.

**Which of the two is asked first depends on how the hover was asked**, and
that is a measurement rather than a preference:

- **On an explicit `:Hover show`**, gopath goes first and `<cfile>` second —
  the full pipeline, because the cost is the point of asking.
- **On the automatic trigger**, `<cfile>` goes first, and gopath is consulted
  only when `<cfile>` declined *and* the token is one gopath could plausibly
  help with: it contains `...` or `…`, or it has no slash at all.

The gate exists because a *failing* resolve cost **13.2 ms per trigger** in
exactly the population an automatic hover produces — prose that is not a path
at all. gopath answers everything it can well under 500 µs; only the misses
are expensive, which is why the gate sits on the token rather than on gopath.
What it gives up is stated where it is implemented (`gopath_can_help` in
`bare_path.lua`): a relative path that exists somewhere else in the project —
not beside the buffer, not under the cwd — stops resolving on the timer.
`:Hover show` still finds it.

That number was refined on 2026-09-03 by measuring the same call from gopath's side: it saw one cost where there were two. The larger was a **200 ms LSP timeout** in buffers with no server attached — invisible from here, because the original measurement was taken in a buffer that had one — and it is fixed in gopath (`a7529d1`). What remains is the **tail search**, ~11.5 ms for a token with separators, which is why this gate stays. See [FEATURES/BARE-PATHS.md](FEATURES/BARE-PATHS.md).

Two things the hover does with the answer, both worth knowing when a result
surprises you:

- **A `kind == "url"` result is declined.** gopath opens URLs in a browser;
  the hover has its own URL preview, reached through the link path.
- **`exists` must be true.** A gopath result for something not on disk is
  discarded, and the decision about whether the absence is worth reporting is
  taken afterwards, by the hover's own rules — *not* by gopath.

That second point is the one that misleads. A false "✗ no such file" float
looks like a resolver bug and is not: gopath declined, `<cfile>` declined, and
what put the float on screen was the hover deciding for itself that the text
was unambiguously a path. Those rules live in `bare_path.lua`
(`is_unambiguous_path`) and are documented under
[Bare paths](FEATURES/BARE-PATHS.md). Read them before opening a gopath issue.

## images.nvim — the picture, and the geometry around it

Two entry points, one of them indirect:

```lua
require("lib.nvim.image_preview").detect()  --> "images.nvim" | "snacks" | "image.nvim" | nil
```

`lib.nvim.image_preview` is the provider-agnostic layer. It prefers
images.nvim when several are installed, because snacks.nvim and image.nvim
both speak only the Kitty graphics protocol while images.nvim draws via
OSC 1337.

`hover.preview.media` then talks to images.nvim directly, and only to
images.nvim, because it is the only one that can draw into an arbitrary
existing window:

| Call | For |
| --- | --- |
| `images.info.collect` | pixel size, as a fallback where the header parser cannot read the format (WebP, SVG) |
| `images.scale.fit_cells` | letterboxing the image into the float — the same function `images.zen` and `images.redact` size their windows with |
| `images.config` | the `draw_inset` the anchor keeps free on every side |
| `images.anchor` | the draw itself, deferred by one tick |
| `images.browse.draw_in_window` | fallback for an images.nvim without `images.anchor` |
| `images.terminal.clear` | clearing the drawing when the float closes |

Two invariants here are load-bearing, and both have been bugs already: the
editor-relative float, and the inset subtraction. They are written up in
[architecture.md](architecture.md#two-things-that-must-not-be-changed-casually), and
images.nvim ships the measurements as `:Image debug`. Read both before
touching placement.

## pdfport.nvim — a page at a time

```lua
require("pdfport").render_page(path, page, opts, callback)
```

Asynchronous: it shells out to `pdftoppm`. The hover caches per file *and* per
page, and the document's page count is never known in advance — paging forward
simply stops at the last page, which is how the count is discovered. If a
render takes longer than `placeholder_grace_ms` the float shows "rendering…";
below that it waits quietly, because a placeholder that only flickers is worse
than none.

Without pdfport a `.pdf` target still hovers — as its size, plus the reason
there is no page.

### …and one window of a page, which is what a sharp zoom is

```lua
require("pdfport").can_render_page_crop()   --> is this build new enough?
require("pdfport").render_page(path, page, { dpi = 486, crop = rect }, callback)
```

`:Hover zoom` over a page raises the DPI by the same factor the view narrows
by and asks for **only the window on screen**. That pairing is the whole
feature: raising the DPI alone re-renders the whole page and grows with the
square of it (176 ms to 2 653 ms across four steps), while a window the size of
the plain page costs the same at every DPI. `opts.crop` exists in pdfport for
this, the way `images.convert.crop` exists in images.nvim for the picture half.

`can_render_page_crop` is asked first rather than the option simply passed: an
older build ignores an unknown field in silence, and the page would come back
at a higher DPI letterboxed into the same float — a key that visibly does
nothing. Without it, the zoom keys are not offered for a page at all.

### …and a whole document at a time

```lua
require("pdfport").can_create("office")   --> is there a producer for this?
require("pdfport").create({ inputs = { docx }, output = pdf, from = "office", … })
```

The second crossing to pdfport, and the one that makes an office document
previewable at all: its `soffice` producer runs LibreOffice headless and hands
back a PDF, which then goes straight into the page path above. Off unless
`:Hover office on` — the first conversion of each document is a LibreOffice
start, which is seconds.

Three things worth knowing when this misbehaves, all in
[`preview/office.lua`](../lua/hover/preview/office.lua):

- **`can_create("office")` is asked first**, so "LibreOffice is not installed"
  is a sentence in the float rather than a failed conversion.
- **Converted PDFs are kept**, keyed by path *and* mtime, under
  `stdpath("cache")/hover.nvim/office`, and deleted at `VimLeavePre`. A
  second hover on the same document does not start LibreOffice again.
- **One conversion per document at a time.** The hover's own cache never holds
  a pending result, so without that guard every `CursorHold` during a
  conversion would start another one.

## What arrives through the registry

Everything above is a *named soft dependency*: hover.nvim `pcall`s for it by
name from inside its own preview code. The ones below are the other door —
they call `hover.registry.register` and hover.nvim never says their names.
Adding another needs no change here at all, which is the point of the shape.

Each is documented on its own side, because that is where the code is:

| Plugin | Kind | What it contributes | Its own write-up |
| --- | --- | --- | --- |
| markdown.nvim | source + preview | link and `<figure>` scanning; `#heading` sections | [docs/hover.md](https://github.com/StefanBartl/markdown.nvim/blob/main/docs/hover.md) |
| reposcope.nvim | source | `owner/repo` → the path of its cached README | [docs/hover.md](https://github.com/StefanBartl/reposcope.nvim/blob/main/docs/hover.md) |
| migrate.nvim | position | this line uses a deprecated API, and what replaces it | [docs/hover.md](https://github.com/StefanBartl/migrate.nvim/blob/main/docs/hover.md) |
| documentation.nvim | position | what the dotted module under the cursor is | [docs/hover.md](https://github.com/StefanBartl/documentation.nvim/blob/main/docs/hover.md) |
| spotlight.nvim | position | how often a spotlighted token occurs in this buffer | [docs/hover.md](https://github.com/StefanBartl/spotlight.nvim/blob/main/docs/hover.md) |
| insights.nvim | position | which files import the module under the cursor | [docs/hover.md](https://github.com/StefanBartl/insights.nvim/blob/main/docs/hover.md) |
| sandbox.nvim | position (`on_request`) | is this container image pulled, how big, what runs from it | [docs/FEATURES/HOVER.md](https://github.com/StefanBartl/sandbox.nvim/blob/main/docs/FEATURES/HOVER.md) |
| language.nvim | position (`on_request`) | the word under the cursor, translated | [docs/FEATURES/HOVER.md](https://github.com/StefanBartl/language.nvim/blob/main/docs/FEATURES/HOVER.md) |

Six of those eight are **position** previews, and that is not a coincidence:
until the kind existed, "no target" meant "no hover", and a fact *about* a
line — it is deprecated, this token occurs fourteen times, this module does X,
this word means Y — was not expressible at all. They were all waiting on the
same missing piece. (This sentence said "four of those six" while the table
already held seven rows and five previews: a count next to the list it counts
is a second source, and it drifted the moment insights.nvim arrived.)

**Two of the six are `on_request`, and they are the expensive ones** — a
container engine to wake, a network round trip to make. That flag is what let
either of them be built honestly: without it both would run on the automatic
trigger, which fires after every keystroke followed by quiet.

sandbox.nvim was waiting on a second one. Its answer costs an engine start,
measured at 277–754 ms across two runs, so it could not be built at all until
a contribution could declare its own answer expensive — see
[when your answer is expensive](api.md#when-your-answer-is-expensive).
It is also the one integration no CI can exercise, because answering needs a
running container engine: the row, and the script that fills it, are in
[manual evidence](MANUAL-EVIDENCE.md#a-contribution-asked-only-on-request).

**Each answers only where it has something to say**, and each enforces that
itself rather than relying on a switch here:

- migrate.nvim asks its own migrator, which returns the line unchanged unless
  it genuinely migrates.
- reposcope.nvim answers only for slugs its cache confirms — never for
  arbitrary `owner/repo`-shaped text, which is spelled exactly like `and/or`.
- documentation.nvim answers only for names in the generated map, and says so
  when the map is older than the code.
- spotlight.nvim answers only for tokens that are already spotlighted, because
  a spotlight is the only available signal that this token matters to the
  reader.
- sandbox.nvim declines a name whose last component carries an extension, so
  `init.lua:42` never reaches the engine — the same shape as `nginx:1.27`, and
  the test runs before any process starts rather than after.
- insights.nvim answers only for a module something actually imports, and only
  out of a scan that already happened. A full scan is 631 ms to 1.9 s
  depending on the tree, so a cold index means silence rather than a walk
  started from a cursor movement — and "0 files import this" for every dotted
  name in prose would be the noise the kind was built to avoid.

That distribution of responsibility is deliberate. The framework has no way to
judge whether a contribution is noisy — it cannot know what the answer is
about — so `:Hover positions off` is a blunt instrument that silences all of
them at once. Being quiet is the contributor's job.

## Reading a symptom back to its owner

| Symptom | Owner |
| --- | --- |
| a red ✗ on text that was never a path | `bare_path.is_unambiguous_path` — **hover.nvim**, not gopath |
| a truncated path (`...nvim/init.lua`) does not resolve | gopath.nvim missing, or declining |
| `file.md#heading` shows the file's head instead of the section | markdown.nvim missing |
| a link does not hover, but the bare path in it does | markdown.nvim's source is not registered — usually `setup()` never ran |
| an image shows as text | no provider installed, or one that is not images.nvim on a terminal without Kitty graphics |
| the picture lands beside its own frame | placement — see the two invariants in [architecture.md](architecture.md#two-things-that-must-not-be-changed-casually) |
| a PDF shows its size but no page | pdfport.nvim missing, or `pdftoppm` not on `PATH` |
| a `.docx` shows a badge instead of its first page | `:Hover office on` was never typed — it is opt-in; or pdfport.nvim / `soffice` is missing, which the badge says |
| a link does not hover at all | `:Hover links web on` — off by default, in every filetype, for both markdown links and bare URLs. That makes it hoverable; `:Hover auto url` is the second gate, and what makes the *trigger* open it |
| a link hovers but shows no title or status code | that is `web on` without `web fetch on`; the offline preview never touches the network |
| a fetched link keeps showing an old status | fetch results are cached for the session; `:Hover links web off` then `on` drops the cache |
| nothing hovers anywhere | `enable()` never ran from a non-lazy spec, `:Hover mode off` was typed and forgotten, or `vim.g.hover_disable` is set |
| a path in source code does not hover, but the same text in a comment does | the position gate — **hover.nvim**. `:Hover paths code on` turns it off; see [Where one is looked for](FEATURES/BARE-PATHS.md#where-one-is-looked-for) |
| one path stopped hovering while everything else still works | it was dismissed with `q`/`<Esc>`. It re-arms at the next target the cursor resolves, or immediately via `show({ force = true })` |
| `q` starts no macro, or `<Esc>` does nothing | a hover is on screen and has borrowed that key — **hover.nvim**, and only until the float closes, which hands it back rather than deleting it |

## Direction of dependency

`lib.nvim` is the one **hard** dependency: hover.nvim requires it with no
fallback, for the debounce, the notifier, the LRU, the autocmd helpers and the
command composer. Everything in the table above is **soft** — hover.nvim
depends on none of them, and every crossing is `pcall`-guarded in both
directions, so a missing plugin degrades one row of that table and a *broken*
one is contained: a registry source that throws is skipped, and the next
source still runs.

Installing hover.nvim and lib.nvim alone gives you a working hover. Installing
one of the four upgrades exactly one row from a description into the thing
itself.
