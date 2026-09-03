> **Active development.** This repository is in its development phase — breaking changes are to be expected at any time. Pin a commit or tag if you depend on it.

# hover.nvim

```
 _
| |__   _____   _____ _ __
| '_ \ / _ \ \ / / _ \ '__|
| | | | (_) \ V /  __/ |
|_| |_|\___/ \_/ \___|_|
```

[![Neovim](https://img.shields.io/badge/Neovim-0.10%2B-57A143?logo=neovim&logoColor=white)](https://neovim.io)
[![Lua](https://img.shields.io/badge/Lua-5.1%2FLuaJIT-2C2D72?logo=lua&logoColor=white)](https://www.lua.org)
![Status](https://img.shields.io/badge/status-active%20development-blue)
![Platform](https://img.shields.io/badge/platform-Linux%20%7C%20macOS%20%7C%20Windows-lightgrey)
[![CI](https://github.com/StefanBartl/hover.nvim/actions/workflows/ci.yml/badge.svg)](https://github.com/StefanBartl/hover.nvim/actions/workflows/ci.yml)

> Requires [StefanBartl/lib.nvim](https://github.com/StefanBartl/lib.nvim) — a hard
> dependency, not an optional one. `:Hover` is built on its
> `bindings.usercmd.composer`, and the debounce, notifier, LRU and autocmd helpers all
> come from there.

> Pairs with [markdown.nvim](https://github.com/StefanBartl/markdown.nvim), a sister
> plugin from the same author: it registers the link scanner and the `#heading` section
> previews, which is the single biggest upgrade this plugin can receive.

Rest the cursor on something that points at a file — a markdown link, or a path written
as plain text — and a small float shows what it points at.

```
See ./docs/architecture.md#modules for details.
    └──────── hover here ────────┘

┌ architecture.md ──────────────────┐
│ ## Modules                        │
│                                   │
│ Every module owns one directory   │
│ with an `init.lua` …              │
└───────────────────────────────────┘
```

---

## Table of contents

- [Capabilities](#capabilities)
- [What it previews](#what-it-previews)
- [Quickstart](#quickstart)
- [Integrations](#integrations)
- [What is opt-in, and why](#what-is-opt-in-and-why)
- [Modes](#modes)
- [The `:Hover` command](#the-hover-command)
- [Bare paths](#bare-paths)
- [Where a bare path is looked for](#where-a-bare-path-is-looked-for)
- [Waving one hover away](#waving-one-hover-away)
- [Resizing the hover](#resizing-the-hover)
- [Zooming into a picture, or a page](#zooming-into-a-picture-or-a-page)
- [Scrolling a preview](#scrolling-a-preview)
- [Configuration](#configuration)
- [Contributing from your own config](#contributing-from-your-own-config)
- [Contributing from a plugin](#contributing-from-a-plugin)
- [Two things that must not be changed casually](#two-things-that-must-not-be-changed-casually)
- [Health](#health)
- [Modules](#modules)
- [Documentation](#documentation)

---

## Capabilities

| Capability | What it does | Details |
| --- | --- | --- |
| `require("hover").enable()` | Installs the trigger, attaches the buffers that are already open, registers `:Hover`. Idempotent | [Quickstart](#quickstart) |
| Preview on cursor rest | A float over whatever the cursor points at — a link, or a path written as plain text, in any filetype | [What it previews](#what-it-previews) |
| `:Hover show` / `show({ force = true })` | One preview, here and now, ignoring every volume switch | [The `:Hover` command](#the-hover-command) |
| `:Hover mode [auto\|manual\|off]` | The switch above every other switch. `manual` keeps every preview and gives up only the automatic trigger | [Modes](#modes) |
| Nine runtime switches | `links`, `links web`, `links web fetch`, `paths`, `paths missing`, `paths code`, `positions`, `images`, `office` — declared once, feeding routes, completion, `status` and `:checkhealth` alike | [The `:Hover` command](#the-hover-command) |
| `:Hover status` | The mode and every switch, in one message | [The `:Hover` command](#the-hover-command) |
| `:Hover why` | Why nothing hovered at the cursor: which of the seven gates refused, named, with the command that opens it | [The `:Hover` command](#the-hover-command) |
| Bare-path resolution | A path in prose, a code comment or a `:messages` dump is a target too — truncated ones included | [Bare paths](#bare-paths) |
| `hover.scroll(1)` / `scroll(-1)` | Page through a file's head or a PDF's pages without leaving the document | [Scrolling a preview](#scrolling-a-preview) |
| `hover.resize(1)` / `resize(-1)` | make the float bigger or smaller: a picture is drawn larger, a text preview shows more lines | [Resizing the hover](#resizing-the-hover) |
| `:Hover zoom` / `hover.zoom(1)` | magnify a *detail* of a picture or a PDF page, and `h`/`j`/`k`/`l` to move around in it | [Zooming into a picture, or a page](#zooming-into-a-picture-or-a-page) |
| `hover.dismiss()` | Wave one float away and keep it away, until the cursor reaches another target | [Waving one hover away](#waving-one-hover-away) |
| `hover.pin()` | Keep one float on screen while the cursor goes elsewhere — for comparing rather than reading. One float, so the trigger opens nothing while it is up | [The `:Hover` command](#the-hover-command) |
| `hover.registry.register()` | Another plugin contributes a *source* or a *preview*; hover.nvim never says its name | [Contributing from a plugin](#contributing-from-a-plugin) |
| `:checkhealth hover` | One check per soft dependency, asking for the entry point actually called rather than for the module | [Bindings](docs/BINDINGS.md) |
| `vim.g.hover_disable` | Forces `mode = "off"` from a plugin spec, outranking anything a host configures | [Modes](#modes) |

---

## What it previews

| Target | Float shows |
|---|---|
| a text file | its first lines, syntax-highlighted |
| a markdown file with `#heading` | that section (needs markdown.nvim) |
| a directory | its entries |
| an image | the picture (needs a drawing provider), else format, dimensions, size |
| a PDF | page 1, rendered (needs pdfport.nvim), else size and why not |
| an office document | a badge, or its first page once `:Hover office on` |
| a file with no text in it | a badge naming the format, not a screen of bytes |
| an http(s) link | host, path and decoded query; plus status code and title with fetching on |
| a git object id | what that commit did (`git show --stat`) — only on `:Hover show`, never on the timer |
| a target that does not exist | that — often the most useful answer of all |

Half of that list is somebody else's work. Every plugin that contributes to it is
optional and **none of them is required** — see [Integrations](#integrations) for what
each one brings, and what its row degrades to when it is absent.

---

## Quickstart

```lua
{
  "StefanBartl/hover.nvim",
  lazy = false,
  priority = 900,
  dependencies = { "StefanBartl/lib.nvim" },
  config = function()
    require("hover").enable()
  end,
}
```

`enable()` installs the `FileType` trigger, attaches to buffers that are already open,
registers `:Hover`, and is idempotent — call it from two plugins and you still get one
autocmd.

**Put it somewhere that is not lazy-loaded.** A path in a `.txt` or a code comment is a
target too, so a spec that only loads on markdown would leave the feature silently dead
in every other filetype — which reads as "it randomly doesn't work" rather than as a
configuration choice. `:Hover` itself is registered from `plugin/hover.lua` regardless,
so `:Hover mode auto` is reachable even from a session where nothing turned it on.

`enable(opts)` also takes the configuration table, so switching it on and configuring it
is one call. **`opts = {}` is not a substitute** — lazy.nvim turns that into a `setup()`
call, which configures the hover and never switches it on, leaving a plugin that is
loaded, configured and completely inert.

See [docs/installation.md](docs/installation.md) for packer.nvim, vim-plug, mini.deps, a
local checkout, and how to check that it worked.

---

## Integrations

hover.nvim draws one float and knows almost nothing. Nearly everything interesting in it
— reading a markdown link, resolving a truncated path, turning a `.png` into pixels,
turning page 3 of a PDF into a `.png` — is somebody else's job, done by a sibling plugin
that may or may not be installed.

[lib.nvim] is the one **hard** dependency. Everything else here is **soft**: reached
through a `pcall`, optional in both directions, and worth exactly one row of the table
below. With none of them installed the hover still gives file heads, directory listings,
image and PDF metadata, a badge for files that hold no text, URL details once the web
hover is switched on, and the "this target does not exist" answer.

### Worth installing alongside it

The last column of the table below says what you lose without each plugin, which is the
honest way to read a soft dependency. But it undersells the point, so here it is
plainly: **hover.nvim is a frame, and these are the pictures.** Four of them are worth
installing for the hover alone.

- **[markdown.nvim]** — the single biggest upgrade this plugin can receive. Without it
  only bare paths start a hover; with it, `[text](target)`, an `<img src>`, a whole
  captioned `<figure>`, and `file.md#heading` opening on *that section*.
- **[images.nvim]** — turns "1920×1080, 340 KB" into the actual picture, and is what
  makes a rasterized PDF page visible at all. The only provider that draws on native
  Windows Neovim in WezTerm.
- **[pdfport.nvim]** — page 1 of a PDF as an image, every further page scrollable, and
  after `:Hover office on` a `.docx`/`.xlsx`/`.pptx` too.
- **[gopath.nvim]** — the reason a truncated `…nvim/init.lua` in `:messages` still
  resolves.

The rest each answer one question the file in front of you cannot: what replaced this
deprecated call, what is this module, how many of this token are there, is this image
pulled, what is in that repository's README.

### What each plugin brings

| Plugin | What it is on its own | What it adds to the hover | Without it |
| --- | --- | --- | --- |
| [lib.nvim] — **required** | A reusable Lua/Neovim helper library with no third-party dependencies, shared by every plugin in this ecosystem | The `:Hover` verb and its `<Tab>` completion (`bindings.usercmd.composer`), the debounce behind `delay_ms`, the notifier every switch announcement goes through, the LRU under the preview cache, the autocmd helpers, and `image_preview.detect()` — which drawing provider is installed | hover.nvim does not load. This is the one dependency with no fallback |
| [markdown.nvim] | A self-contained Markdown toolkit: headings/TOC/folding, GFM tables, links and references, a cursor-action dispatcher | The link scanner — `[text](target)`, an `<img src>`/`<a href>`, or a whole captioned `<figure>` under the cursor becomes a target — and the `#heading` section preview, so `file.md#modules` opens on *that section* instead of the file's head. The single biggest upgrade this plugin can receive | Only bare paths start a hover, and `file.md#frag` shows the file's first lines |
| [images.nvim] | Shows images in the terminal over OSC 1337 — `:Image`, galleries, clipboard paste, zen view. The only provider that draws on native Windows Neovim in WezTerm | The picture itself, drawn into the float: pixel size where the header parser cannot read the format (WebP, SVG), the letterboxing fit, the `draw_inset` the anchor keeps free on every side, the deferred draw, and the terminal clear when the float closes. Also what makes a rasterized PDF page visible at all | An image target shows format, dimensions and size as text — and so does a PDF page |
| [pdfport.nvim] | PDFs in both directions: seven extraction backends, plus nine producers for creating, merging and rasterizing | `render_page()` — page 1 of a PDF as a PNG, and every further page scrolled to. And, once `:Hover office on`, `create()` runs LibreOffice headless so a `.docx`/`.xlsx`/`.pptx` becomes a page too | A PDF shows its size and why there is no page; an office document shows a badge naming the format |
| [gopath.nvim] | Multi-phase navigation from the cursor: LSP → Treesitter → whole-line extraction → suffix search → fuzzy alternate | `resolve_at_cursor()`, asked *before* Vim's own `<cfile>`: a truncated `...nvim/init.lua`, a `:line:col` suffix, a file findable only through `&path`/`rtp`. That is the "a path in `:messages` should hover too" case | Ordinary relative and absolute paths still resolve; truncated ones do not |
| [snacks.nvim] / [image.nvim] | Image providers speaking the Kitty graphics protocol | Recognised as providers, but neither can draw into an arbitrary existing window, so a picture still falls back to text. images.nvim wins whenever several are installed | Nothing changes |
| [reposcope.nvim] | Search, preview and clone repositories from GitHub / GitLab / Codeberg, keeping every README it fetched in a cache keyed `owner/repo` | Cursor on `owner/repo` — in a `lazy.nvim` spec, a dependency list, a note — and the head of that repository's README is in the float, out of the cache reposcope already keeps | `owner/repo` is just text |
| [migrate.nvim] | Finds and rewrites deprecated Neovim API calls, with a rule set that knows what replaced what | A deprecated call on the line under the cursor names itself, and says what replaced it, before you run anything | You find out when the migration runs, or when it breaks |
| [documentation.nvim] | Generates a module map of a Lua codebase — what each module is, what it exports, who requires it | Cursor on `require("lib.nvim.notify")` and the float says what that module *is*, read out of the `module_map.json` this plugin already writes | A module path is a string |
| [spotlight.nvim] | Persistent highlighting of tokens across a buffer | The colours say *where*; the hover says **how many**, and whether there is another one below the fold | You scroll to find out |
| [sandbox.nvim] | One plugin for Docker, Podman and nerdctl: containers, images, volumes, compose | On `:Hover show` over `nginx:1.27-alpine` in a `Dockerfile`: pulled or not, how big, which containers run from it. Request-only — an engine call costs 300–750 ms and must not ride the automatic trigger | An image reference is just text |

### The two doors

There are exactly two ways a plugin and the hover reach each other, and they are not
interchangeable.

| Door | How it works | Who arrives through it |
| --- | --- | --- |
| **Registry** (inbound) | The plugin calls `hover.registry.register(name, …)` and hands over a *source* ("what is under the cursor?"), a *preview* ("how do I render a target of this type?"), or a *position* ("is there anything to say about this **place**?"). hover.nvim never says its name, and the next contributor needs no change here | markdown.nvim, migrate.nvim, reposcope.nvim, documentation.nvim, spotlight.nvim, sandbox.nvim |
| **Named soft dependency** (outbound) | hover.nvim `pcall(require, …)`s the plugin by name from inside its own preview code, guarded so a missing plugin is a `nil` rather than an error | images.nvim, pdfport.nvim, gopath.nvim |

Door 1 is the better shape; door 2 is the honest one. A *capability* can be registered —
"here is a function that previews an anchor" says everything the framework needs to know.
A *renderer* cannot, because the hover has to negotiate with it: measure a picture,
subtract the drawing inset, hand back a geometry, defer a draw by one tick, clear the
terminal on close. That is a conversation with one specific API, not a callback, and
pretending otherwise would put an images.nvim-shaped interface into a library that would
then have exactly one implementor.

The practical consequence is worth knowing before opening an issue: **a plugin can be
listed here and still not be the cause of the bug you are looking at.** Door-2 plugins
are named inside hover.nvim's own source, so their names turn up in comments, module docs
and stack traces belonging to code they never ran.

[docs/INTEGRATIONS.md](docs/INTEGRATIONS.md) is the long version — every entry point, and
a table reading each symptom back to the plugin that owns it.

[lib.nvim]: https://github.com/StefanBartl/lib.nvim
[markdown.nvim]: https://github.com/StefanBartl/markdown.nvim
[images.nvim]: https://github.com/StefanBartl/images.nvim
[pdfport.nvim]: https://github.com/StefanBartl/pdfport.nvim
[gopath.nvim]: https://github.com/StefanBartl/gopath.nvim
[reposcope.nvim]: https://github.com/StefanBartl/reposcope.nvim
[migrate.nvim]: https://github.com/StefanBartl/migrate.nvim
[documentation.nvim]: https://github.com/StefanBartl/documentation.nvim
[spotlight.nvim]: https://github.com/StefanBartl/spotlight.nvim
[sandbox.nvim]: https://github.com/StefanBartl/sandbox.nvim
[snacks.nvim]: https://github.com/folke/snacks.nvim
[image.nvim]: https://github.com/3rd/image.nvim

---

## What is opt-in, and why

A float that opens unasked is welcome only when **both** of these hold:

1. **The target was explicit.** Link syntax is the author stating "this points
   somewhere". A bare path in prose is this plugin guessing.
2. **The preview says something the line does not.** A file's first lines cannot be read
   off the link text. A URL's host and path can — they *are* the link text.

Cost breaks the tie where an answer is expensive to produce. Run every preview class
through that and the defaults fall out:

| Class | Explicit | Adds | Costs | Default |
|---|---|---|---|---|
| link → local file, image, PDF | yes | a lot | nothing | **on** |
| bare path that resolves | no | a lot | nothing | **on** |
| directory listing | — | some | nothing | **on** |
| picture drawn into the float | — | a lot | terminal state | **on** |
| link → http(s), offline | yes | little (it restates the link) | nothing | **off** |
| link → http(s), fetched | yes | a lot | a request to that host, per link | **off** |
| office document rendered | — | a lot | a LibreOffice start, per document | **off** |
| a bare path reported as **broken** | no | negative when wrong | nothing | **on**, narrowly |

Two of these deserve their own note.

**Web links are off because documentation is made of links.** Turn them on permanently
and reading a README becomes a slideshow: every second cursor rest opens a float, and the
float lands over the paragraph being read. Counted in this ecosystem's own docs, one file
had 104 links of which 2 were http — so the switch that exists silences 2 and the other
102 are the volume. Which is why `links` has a switch of its own, and why `mode` sits
above all of them.

**Fetching is off a second time, on top of `links web`,** for a reason volume does not
cover: it is a disclosure. Every link the cursor rests on becomes a request from this
machine to that host. `:Hover links web on` alone never touches the network.

## Modes

The switch above every other switch. Three positions:

| Mode | What opens a float |
|---|---|
| `auto` | the trigger, as configured. The feature as intended. |
| `manual` | nothing, by itself. `:Hover show`, `keymaps.show` and `show({ force = true })` still answer **in full** — web links included. |
| `off` | nothing at all. |

`manual` is the answer to "I am reading a document made of links right now" without
deciding class by class which noise is acceptable — every preview stays available, only
unprompted. Bind a key for it:

```lua
require("hover").setup({
  mode = "manual",
  keymaps = { show = "<leader>k" },
})
```

No key is claimed by default: a plugin that other plugins depend on has no business
taking one on their behalf. `:checkhealth hover` warns when `manual` is configured with
no key bound, because that combination looks exactly like a broken plugin from the
outside.

The state also lives in `vim.g.hover_disable`, which is where you say it from a plugin
spec before anything loads — one setting rather than two that can disagree:

```lua
{ "StefanBartl/hover.nvim", init = function() vim.g.hover_disable = true end }
```

That outranks anything a plugin configures: a host enabling its hover cannot override you
switching the feature off — **including its keymaps**. An explicit request
(`:Hover show`, `keymaps.show`, a host's own key calling `show({ force = true })`) opens
every volume switch but not this one, because a veto a keypress can defeat is not a veto.
The mode for "silent by itself, still answering when asked" is `manual`.

## The `:Hover` command

Every route completes with `<Tab>`, and the state argument may be omitted — which
toggles.

| Command | Does |
|---|---|
| `:Hover show` | one hover, here, now, ignoring every volume switch |
| `:Hover status` | the mode and every switch — as a chooser where picking a line toggles it, or as one message where lib.nvim has no UI kit |
| `:Hover why` | why nothing hovered *here* — which of the gates refused, and what to type about it |
| `:Hover pin` | keep this float on screen while the cursor goes elsewhere; again releases it |
| `:Hover resize [bigger\|smaller]` | make the hover on screen bigger or smaller. Omitted, bigger |
| `:Hover zoom [in\|out\|reset]` | magnify a detail of the picture on screen. Omitted, in |
| `:Hover nav {left\|right\|up\|down}` | move the magnified view |
| `:Hover next` | step to the next plugin with something to say about this place |
| `:Hover mode [auto\|manual\|off]` | set the mode; omitted, it reports the current one |
| `:Hover toggle` | off if it is on, back to `auto` if it is off |
| `:Hover links [on\|off\|toggle]` | whether link syntax hovers at all |
| `:Hover links web [on\|off\|toggle]` | whether http(s) links hover. Implies `links on` |
| `:Hover links web fetch [on\|off\|toggle]` | fetch for status code and title. Implies `links web on` |
| `:Hover paths [on\|off\|toggle]` | whether a path written in prose hovers |
| `:Hover paths missing [on\|off\|toggle]` | whether a path resolving to nothing is marked broken |
| `:Hover paths code [on\|off\|toggle]` | whether a path hovers inside executable code, not just comments and strings. Implies `paths on` |
| `:Hover positions [on\|off\|toggle]` | whether a plugin may say something about a position that points at nothing |
| `:Hover images [on\|off\|toggle]` | whether pictures are drawn, or described |
| `:Hover office [on\|off\|toggle]` | whether office documents render through a PDF |

**Implication runs upward only.** `fetch` turns on `web`, which turns on `links`.
Switching `links` *off* silences web links without clearing their flag — so turning
`links` back on restores what you had rather than quietly demoting it.

**`links off` is about how a target was found, not what it is.** If the same text is also
a resolvable bare path, `paths` decides it. `:Hover status` shows both.

Every switch is announced when it changes, because "off" is otherwise invisible: nothing
on screen tells a switched-off preview apart from a line that simply has no target on it,
and a switch whose state you cannot see gets reported as a broken feature a week later.

## Bare paths

A path in prose, a code comment, or a `:messages` dump is a target too:

```
./assets/diagram.png                → the picture
../docs/BINDINGS.md                 → its first lines, markdown-highlighted
...AppData/Local/nvim/init.lua:42   → the file, found despite the truncation
```

Two rules keep this from firing constantly:

- **It must look like a path** — a separator, an extension, or a `...` truncation, *and*
  at least one alphanumeric character somewhere. `helper` is a word; `helper.lua` is a
  path; `/` and `--%` are punctuation out of a table.
- **A missing path is reported only when it cannot have been anything else.** That one
  gets a red marker; everything else stays silent.

The second rule has been wrong twice, in two different directions, and the current
version is deliberately narrow as a result:

| Evidence | Example | But not |
| --- | --- | --- |
| a truncation | `...nvim/init.lua` | |
| a drive or UNC prefix | `C:\Users\x`, `\\server\share` | |
| an extension on the **last** component | `docs/gone.md`, `./src/app.ts` | `github.com/user/repo` |

Everything else stays silent. That includes text that really is a path — `~/notes`,
`/etc/hosts`, `lua/lib/nvim` — and it is a deliberate loss, because this is the only
preview class whose value goes *negative* when it is wrong. The cases it exists to
prevent, each of which used to open a confident "no such file" float over ordinary prose:

```
and/or  input/output  Actual/Insgesamt  sortiert/      -- a separator is not evidence
2026/09/01  TODO/FIXME/DONE  read/write/execute        -- nor is a component count
github.com/user/repo                                    -- nor an extension mid-path
./components/Button  ../lib/utils                       -- every JS/TS import
```

None of this touches a target that **exists** — `docs/` and `and/or` both hover normally
the moment something of that name is on disk. The rules only decide whether *absence* is
worth asserting. `:Hover paths missing off` turns the class off entirely.

## Where a bare path is looked for

The rules above are about the *text*. There is a second question, about the
*position*, and it is the one that removes the rest of the noise in a source
file: **a path is written in a comment or inside a string, never in the middle
of an expression.**

That matters because the remaining false positives are not textually different
from a path. `vim.api.nvim_buf_get_lines` has dots and components; `alpha /
beta` has a separator and two parts, exactly like `docs/BINDINGS.md`. No rule
about the characters can separate them, because there is nothing to separate —
only where they sit differs.

So in a buffer Treesitter can parse, a position it identifies as executable
code is not searched at all:

```lua
-- see ./docs/BINDINGS.md          hovers  (a comment)
local p = "./docs/BINDINGS.md"  -- hovers  (a string)
local x = vim.api.nvim_get_mode -- silent  (an expression)
local r = alpha / beta          -- silent  (an expression)
```

**The rule is inverted from the obvious one, deliberately.** "Allow only in a
comment or a string" sounds equivalent and is not: it assumes prose buffers
have no parser, and markdown, gitcommit and rst all do. Under that rule a path
in an ordinary markdown paragraph would stop hovering — which is most of what
this feature exists for. The question asked instead is whether the position is
*positively identifiable as code*, and everything else is allowed:

| At the cursor | Answer |
| --- | --- |
| no parser for this buffer — `.txt`, a log, a `:messages` dump | looked for |
| a parser, but nothing captured here — an ordinary markdown paragraph | looked for |
| a comment, a string, any markup capture | looked for |
| only code captures — a variable, an operator, a keyword | skipped |
| a capture family this plugin has never heard of | looked for |

Three of those five are permissive, and the two that are not need positive
evidence. A grammar nobody anticipated, a parser that fails to load, a query
that throws — each falls through to "look anyway", because a feature that
silently stops working in one language is much worse than an occasional extra
float.

`:Hover paths code on` turns the position check off entirely and goes back to
letting the text decide alone. `:Hover show` ignores it regardless: asking
about this exact spot is already the answer to "is this worth asking about".

It costs nothing where it does not run. The token check comes first and
rejects the overwhelming majority of cursor positions — 530 of 531 in this
plugin's own largest source file — so the parse behind this section happens
only for text that already looks like a path.

## Waving one hover away

Sometimes the float is over the thing you are trying to read, and you have to stay on the
path. `q` or `<Esc>` takes it away and *keeps* it away for as long as the cursor stays on
that target.

**Closing alone would not do**, which is why this is a dismissal and not a close. Under
the `CursorHold` trigger the event fires again after any keystroke followed by
`'updatetime'` of quiet — cursor movement or not — so a key bound to `hide()` makes the
float vanish and then brings it straight back, while you are still standing where you
wanted it gone.

The dismissal ends by itself: the next target the cursor resolves, another path or none
at all, clears it. That is the whole difference between this and the mode switch — this
one is "not now", that one is "not for a while".

The keys are bound globally only while a hover is on screen, and handed back the moment
it closes; a key that was already mapped is *restored*, not deleted. Unlike the scroll
keys they are bound for **every** hover, because anything can be waved away — including a
picture, which has nothing to scroll. The price is that `q` records no macro for as long
as one float is up.

```lua
require("hover").setup({
  dismiss_keys = { "<C-c>" },   -- a string or a list; replaces the default
  -- dismiss_keys = {},         -- bind nothing, and call hover.dismiss() yourself
})
```

`hover.dismiss()` is public and returns `false` when no hover was open, so it is safe to
bind unconditionally.

## Scrolling a preview

A file's head and a PDF's first page are often not the part you want. While a scrollable
hover is open:

| Key | Does |
| --- | --- |
| `<M-PageDown>` or `<C-Down>` | next screenful of lines, or next PDF page |
| `<M-PageUp>` or `<C-Up>` | back |

Both pairs are bound, because a key that is not on the keyboard cannot be pressed: laptop
and 60% layouts often reach PageUp/PageDown only through an Fn chord, and nothing at
runtime can tell whether *this* keyboard has them. The arrows are on every keyboard there
is. Ctrl rather than Alt on them, because `<M-Up>`/`<M-Down>` are a widespread "move this
line" binding.

The float stays a **preview**: not focusable, not editable, nothing to select or yank.
The keys are bound **only when there is something to scroll** — an image, or a file that
already fits, leaves them alone entirely.

Scrolling does not re-resolve the cursor: the hover keeps showing what it was showing,
even if the cursor has since moved off the target. The title shows where you are —
`notes.md  ↓20` for text, `p3` for a PDF.

```lua
require("hover").setup({
  scroll_keys = { down = "<C-n>", up = "<C-p>" },   -- a string or a list
})
```

A configured list *replaces* the default rather than extending it, so `{ down = { "<C-n>" } }`
binds `<C-n>` and nothing else. An empty list binds nothing at all. Or call the API from
your own mapping, which works whether or not a hover happens to be open:

```lua
vim.keymap.set("n", "<C-d>", function() require("hover").scroll(1) end)
```

## Resizing the hover

While a hover is open, one step multiplies the box the previewer is given — `max_width`
and `max_lines` — by 1.25. **Two honest answers to one operation:** a picture is drawn
larger, a text preview shows *more lines*.

| Key | Does | Bound for |
| --- | --- | --- |
| `+` | one step larger | **a hover with a picture only** |
| `-` | one step smaller | as above |
| `<M-ScrollWheelUp>` | one step larger | **any** hover — but only while the pointer is over the float |
| `<M-ScrollWheelDown>` | one step smaller | as above |
| `:Hover resize [bigger\|smaller]` | the same step from the command line; omitted, bigger | any hover, no key at all |

**`+` and `-` are bound only over a picture, and that is a decision about what a key
costs.** They are real motions in normal mode; displacing them is worth it over an image
and not over every float that happens to be up. The wheel and `:Hover resize` cost nobody
a key and therefore apply to **any** hover — which is also the keyboard way to resize a
text preview.

One key per direction rather than two. The scroll pairs are doubled because a key that is
not on the keyboard cannot be pressed; `+` and `-` are on every keyboard, so that argument
does not carry. `=` was considered as the unshifted `+` of a US layout and left alone — it
is the indent operator, and borrowing an operator buys convenience nobody asked for.

**The wheel obeys a different rule than the keys, and it is the rule you already
have for a wheel.** `+` acts on the one float there is, wherever the pointer happens
to be. A wheel *points*, so `<M-ScrollWheelUp>` acts on what it is aimed at: it resizes
only while the pointer sits on the float, its border ring included. Pointing elsewhere
does nothing, which is the honest answer rather than a missing one.

The ring counts as inside for a reason worth knowing: the float is anchored one row
below the cursor, so its top border sits on the cursor's own row — and under
`trigger = { "mouse" }`, where the pointer *is* the cursor, that is exactly where the
pointer already is. You do not have to move it onto the picture first.

Alt rather than Ctrl, because `<C-ScrollWheel>` is the terminal emulator's own zoom
nearly everywhere — and this is not that. The wheel also needs `'mouse'` to include your
mode: with it empty no wheel event reaches Neovim at all, and the mapping is inert rather
than broken. `:checkhealth hover` says so, because from the outside those look identical.

**Why this is `resize` and not `zoom`.** For a picture the two coincide: ask for a bigger
box and the picture is drawn larger. For text they come apart — the font size belongs to
the terminal emulator and Neovim cannot change it, so a bigger box shows *more lines*, not
larger ones. Only one of the two answers is magnification, and calling both of them zoom
would be wrong about the other. A real zoom — a cropped detail you can move around — is a
separate feature; see [the roadmap](docs/ROADMAP.md). The whole reasoning, including the
two measurements behind the pointer gate, is in
[docs/FEATURES/RESIZE.md](docs/FEATURES/RESIZE.md).

**`zoom_keys` is no longer the old spelling of this.** It briefly was, between the rename
and the arrival of a real zoom, and it now configures
[that](#zooming-into-a-picture-or-a-page) instead. A configuration still using the old shape
(`zoom_keys.larger` / `.smaller`) is **reported on startup and ignored** rather than
quietly rebound — those entries belong in `resize_keys`. `hover.zoom(delta)` is not an
alias for `hover.resize(delta)` either, and has not been since the real zoom landed.

**The ceiling is your terminal, and the plugin finds it rather than carrying a number.** A
step multiplies the box the picture is fitted into by 1.25; the letterboxing and the clamp
against the screen still happen exactly where they did. A step that changes nothing is
stepped back off, so holding `+` does not run the level off somewhere you have to press it
back from. The comparison is against the float's *clamped* size — twenty lines shown for
twenty-five asked is a refusal, and a step that missed it would run the level away. Measured against a real Neovim, a 1200×675 image at the default `80×20`:

| Terminal | Steps in | Picture goes from | to |
| --- | --- | --- | --- |
| 210×55 | five | 71×20 cells | 181×51 |
| 80×24 | **none** | 71×20 | 71×20 — 20 rows is already `lines - 4` |

A PDF page is not re-rasterized, so making one bigger costs nothing and is
correspondingly unsharp. A sharp version would be a second render at a higher DPI, and the page cache is
keyed on path, mtime and page number — without one.

```lua
require("hover").setup({
  resize_keys = {
    larger = { "+", "<C-=>" },      -- a string or a list
    smaller = "-",
    wheel_larger = { "<M-ScrollWheelUp>" },
    wheel_smaller = {},             -- an empty list binds nothing
  },
})
```

`hover.resize(delta)` is public, like `scroll`, and returns `false` when there is no hover
to resize — which today includes a *position* preview, whose content came from another
plugin and cannot be asked again at a larger size.

## Zooming into a picture, or a page

**Resize and zoom are different operations, and the difference is the framing.**
`resize` changes the box and letterboxes the *whole* picture into it — you see the same
picture, larger. A zoom keeps the box and narrows the view, so you see a *smaller part* of
the source, larger. Only the second one is magnification.

**A picture and a PDF page are the same gesture on different machinery.** A picture is
cropped — the file already holds every pixel it ever will. A page is **re-rendered at a
higher DPI**, because what is on screen for a PDF is a rasterization in this plugin's
cache rather than the file itself, and cutting that up would give you bigger, not sharper.

| Way in | Does | Available | Option |
| --- | --- | --- | --- |
| `<M-z>` | one step of magnification | when the picture **can** be zoomed | `zoom_keys.into` |
| `<M-Z>` | one step back out | as above | `zoom_keys.out` |
| `<M-R>` | back to the whole picture or page | as above | `zoom_keys.reset` |
| `:Hover zoom [in\|out\|reset]` | the same three, from the command line; omitted, in | over a picture or a PDF page | — |
| `h` `j` `k` `l` | move the magnified view left, down, up, right | **only while zoomed in** | `nav_keys.*` |
| `:Hover nav {left\|right\|up\|down}` | the same move, from the command line | only while zoomed in | — |

**Why the zoom keys are Alt chords, and why moving has four plain ones.** A zoom step
writes a cropped file and costs about a quarter of a second (measured below), so it is a
deliberate press rather than a dial. For a while there was no key at all, because the only
candidates on the table were `+` and `-` — real motions, and displacing a motion for an
operation that slow is a bad trade. `<M-z>` displaces nothing, so the trade that failed
for `+` succeeds here. All three are bound whenever the picture *can* be zoomed rather
than only while it is: `out` and `reset` simply decline at level 0, and a pair that
appears only after a successful press would be worse than one that is always there.

Moving around, once you are in, is the part you do repeatedly — and `h`/`j`/`k`/`l` are
worth borrowing for a reason the other borrowed keys do not have: the thing they would
otherwise do is *move the cursor*, and the hover dismisses itself on `CursorMoved`.
Unbound, `h` at a magnified picture takes the picture away. Nobody means that. They are
the narrowest borrow here, handed back the moment the hover is not zoomed.

`hover.zoom(delta)` and `hover.nav(dx, dy)` are public if you want keys of your own.

**What one step is.** The visible rectangle is divided by 1.5 and centred on where you
were looking, so going deeper keeps looking at the same place. A move step is a quarter of
what is currently visible, so four of them cross the view once. Stepping back out to a
view you have already seen is instant — the crop is cached for the session.

**The cost, measured before this was built.** On Windows, 2026-09-02:

| Operation | Cost |
| --- | --- |
| `magick` process start alone | 71 ms |
| crop + fit, 1920×1080 screenshot | **258 ms** |
| crop + fit, dense image of the same size | 502 ms |
| crop + fit, 4K source | ~900 ms |
| *for comparison:* one rasterized PDF page | 1150 ms |

No format or compression setting brought it under ~150 ms, and batching several crops into
one process saved only the process start. That number is what decided the shape: a zoom
step is not a dial you hold down, and it runs behind the same placeholder machinery as a
PDF page — which it is in fact faster than.

**The ceiling is the picture, not the terminal** — the opposite of `resize`, where only the
terminal knows where the room ends. Zoom stops when the rectangle would fall below 32
source pixels, and it says so rather than spending a `magick` run to find out.

**A PDF page is sharper, not merely larger** — and it was parked for a year's worth of
reasoning on a number that turned out to measure the wrong thing. Re-rendering a *whole*
page at a higher DPI costs 3.3 s, which is why this stayed on the roadmap. But a zoom does
not show a whole page: asking pdftoppm for just the window you are looking at keeps the
pixel count constant, so the cost stops growing with the depth. Measured on 2026-09-03,
dense A4 text page:

| Level | DPI | Whole page | The window actually shown |
| --- | --- | --- | --- |
| 1 | 324 | 304 ms | 140 ms |
| 2 | 486 | 606 ms | 118 ms |
| 4 | 1094 | 2653 ms | 119 ms |

And it is sharpness rather than size: the same window re-rendered at 486 DPI carries about
four times the edge detail of the same window cropped out of the plain render and scaled up.
`scripts/pdfzoom_probe.lua` prints that comparison for any PDF of yours.

A page stops at 2400 DPI — about eleven times the base, five steps. A picture stops when
its own pixels run out; a vector page never does, so the limit is chosen rather than found.

**What each half needs.** A picture: images.nvim carrying `images.convert.crop`, and
ImageMagick on `PATH`. A page: pdfport.nvim new enough to rasterize a window of one
(`pdfport.can_render_page_crop`), and the pdftoppm it uses. Without them `:Hover zoom` says
so instead of doing nothing.

## When two plugins answer

A *position* preview says something about the **place** the cursor is in rather
than about a target it points at, and more than one plugin can have something
to say about one place. On a dotted name two routinely do: documentation.nvim
answers *what this module is*, insights.nvim *who imports it*. Both are true
and they are different sentences.

Until now the first registered one won and the rest were invisible — decided by
plugin load order, which is nobody's decision. So the answers are a **ring**:

| | |
| --- | --- |
| `<M-n>` | the next plugin with something to say here |
| `:Hover next` | the same step, from the command line |

Past the last answer it returns to the first. With only one answer it says so,
because a key that silently does nothing is indistinguishable from a broken one.

**Stepped rather than merged, and that is a decision about content.** Two
answers in one float would mean two titles for one border, two filetypes for
one highlight, two scroll states for one pair of borrowed keys — and a picture
cannot be merged with text at all. Stepping keeps each answer whole.

**Nothing is asked in advance.** There is deliberately no "2 of 3" counter:
knowing how many *would* answer means calling every contribution on every
hover, which is the cost `on_request` exists to avoid. The key is bound on how
many are registered, and stepping is what asks. A contribution that declines is
not a page you step past, and one that declared its answer expensive **is**
reachable this way — stepping is an explicit act, like `:Hover show`.

## Configuration

```lua
require("hover").setup({
  mode = "auto",
  trigger = { "CursorHold" },
  delay_ms = 250,
  links = { enabled = true, web = false, fetch = false },
  paths = { enabled = true, missing = true },
})
```

| Option | Default | Meaning |
| --- | --- | --- |
| `mode` | `"auto"` | `auto` \| `manual` \| `off`. See [Modes](#modes). |
| `trigger` | `{ "CursorHold" }` | `"CursorHold"` follows `'updatetime'` and adds `delay_ms` on top. `"cursor"` is CursorMoved plus this plugin's own debounce — `delay_ms` is then absolute, and nothing fires while the cursor stands still. `"mouse"` also needs `:set mousemoveevent`, which is never set for you. |
| `delay_ms` | `250` | Debounce before the float opens. |
| `placeholder_grace_ms` | `250` | How long an async preview may take before a "rendering…" placeholder is allowed to interrupt. |
| `max_lines` | `20` | Preview line cap, and the float's max height. |
| `max_width` | `80` | Float width cap, in columns. |
| `border` | `"rounded"` | `nvim_open_win` border. |
| `inline_images` | `true` | Draw pictures / PDF pages into the float when a provider can. |
| `filetypes` | `"*"` | `FileType` pattern the hover attaches on. A non-empty `'buftype'` is excluded regardless. |
| `links.enabled` | `true` | Whether link syntax hovers at all. |
| `links.web` | `false` | Whether an http(s) link hovers. Implies `links.enabled`. |
| `links.fetch` | `false` | Fetch for status code and title. Implies `links.web`. |
| `links.timeout_ms` | `2000` | |
| `paths.enabled` | `true` | Whether a path written without link syntax hovers. |
| `paths.missing` | `true` | Whether a bare path resolving to nothing may be marked broken. |
| `positions` | `true` | Whether a registered *position* preview may open a float — a plugin saying something about where the cursor is, when it points at nothing. Costs nothing with none registered. |
| `paths.code` | `false` | Whether a bare path hovers inside executable code. Off: in a parsed buffer, only comments and strings are searched. Prose is untouched — see [Where a bare path is looked for](#where-a-bare-path-is-looked-for). |
| `office.convert` | `false` | Whether a `.docx`/`.xlsx`/`.pptx`/… is converted to a PDF and shown as a page. |
| `office.timeout_ms` | `60000` | LibreOffice's first start is slow, and a timeout that fires on it looks like a broken feature. |
| `scroll_keys.down` | `{ "<M-PageDown>", "<C-Down>" }` | |
| `scroll_keys.up` | `{ "<M-PageUp>", "<C-Up>" }` | |
| `position_keys.next` | `{ "<M-n>" }` | Step to the next plugin answering for this place. Borrowed **only for a position hover**, and only where more than one contribution is registered — see [When two plugins answer](#when-two-plugins-answer) |
| `nav_keys.left` | `{ "h" }` | Move the magnified view. Borrowed **only while a hover is zoomed in** — see [Zooming into a picture](#zooming-into-a-picture). |
| `nav_keys.right` | `{ "l" }` | |
| `nav_keys.up` | `{ "k" }` | |
| `nav_keys.down` | `{ "j" }` | |
| `zoom_keys.into` | `{ "<M-z>" }` | Magnify a detail of the picture. Borrowed whenever the hover on screen **can** be zoomed — see [Zooming into a picture](#zooming-into-a-picture). Alt chords, so no motion is displaced. |
| `zoom_keys.out` | `{ "<M-Z>" }` | |
| `zoom_keys.reset` | `{ "<M-R>" }` | |
| `resize_keys.larger` | `{ "+" }` | Bound only for a hover with a picture in it — see [Resizing the hover](#resizing-the-hover). |
| `resize_keys.smaller` | `{ "-" }` | |
| `resize_keys.wheel_larger` | `{ "<M-ScrollWheelUp>" }` | Bound for **any** hover. The wheel acts on what it points at: these fire only while the pointer is over the float, its border included. Needs `'mouse'` set |
| `resize_keys.wheel_smaller` | `{ "<M-ScrollWheelDown>" }` | |
| `open_keys` | `{ "gf" }` | Open what the float is showing — through [open.nvim](https://github.com/StefanBartl/open.nvim) when installed, else `vim.ui.open`. Borrowed and restored like the others; `{}` binds nothing. |
| `dismiss_keys` | `{ "q", "<Esc>" }` | |
| `keymaps.show` | `false` | A key for `:Hover show`. No key is claimed unless asked for. |

The pre-1.0 spelling of three options is still accepted and normalized on the way in, so
a host that learned them while this plugin lived inside `lib.nvim` keeps working:
`enabled = false` reads as `mode = "off"`, `bare_paths` as `paths.enabled`, and
`url = { hover, fetch, timeout_ms }` as the `links` fields. Nothing downstream ever sees
the old shape.

## Contributing from your own config

You do not need to write a plugin to add one hover. `setup` and `enable` take a
`contribute` table — the same table a plugin hands to the registry — so a function in
your own config is a contributor like any other:

```lua
require("hover").enable({
  contribute = {
    -- "is there anything to say about this place?" Return finished content, or nil
    -- to stay silent, which is the common answer and has to stay the cheap one.
    positions = {
      function(bufnr, row, _col)
        local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
        local ticket = line:match("PROJ%-%d+")
        if not ticket then
          return nil
        end
        return { lines = { ("%s — %s"):format(ticket, ticket_title(ticket)) }, title = "tracker" }
      end,
    },
  },
})
```

`sources` and `previews` work here too, and so does `{ fn = …, on_request = true }` for an
answer that costs a process start — the field takes the whole contribution shape, not a
subset of it.

Two consequences, both deliberate:

- **It registers under the name `user`.** A second `setup` replaces your contribution
  rather than stacking a copy on it, so reloading your config does not make the same
  function fire twice. This is why a *plugin* should call `register` under its own name:
  two callers sharing the `user` slot would silently delete each other.
- **It never lands in the options table.** Functions are not settings, and the merge that
  makes `setup` idempotent would interleave two lists rather than replace one.

`:checkhealth hover` lists it back under `registry: user`, with a count per kind and, in
parentheses, how many of those entries are `on_request`:

```
registry: user -- 1 position preview (1 asked only on `:Hover show`)
```

Worth knowing before you go looking anywhere else, because the two failures behind "my
hover does not appear" are indistinguishable from the outside: a contribution that never
registered is *absent* from that list, and one that registered and returns `nil` is on it.

Everything in the next section applies to what you write here as well — sources win over
positions, nothing a position answers is cached, and being quiet is your job.

## Contributing from a plugin

```lua
require("hover.registry").register("your.nvim", {
  -- "what is under the cursor?" Return a raw target string, or nil.
  -- Tried in registration order, before the built-in bare-path source.
  sources = {
    function(bufnr, row, col)
      return find_target(bufnr, row, col)  -- , { kind = "yours" }
    end,
  },
  -- "how do I preview a target of this type?" Keyed by the type `classify`
  -- produced; returning nil declines and the built-in preview runs.
  previews = {
    anchor = function(target, opts, bufnr) return section_of(target, bufnr) end,
  },
})
```

Re-registering under the same name **replaces** that plugin's contribution, so a
`setup()` that runs twice does not leave two copies of your source firing on every hover.
A source that throws is skipped and the next one still runs.

Target types a preview can claim: `image`, `pdf`, `office`, `markdown`, `file`,
`directory`, `url`, `anchor`, `missing`.

### When the cursor points at nothing

Some things worth saying are not about a *target* at all. That a line uses a
deprecated API, how often this token occurs in the buffer, what the module in
this `require` actually does — none of those is something the cursor points
at, and the framework used to have no way to express them: no target meant no
hover, full stop.

A third kind of contribution answers for the **position**:

```lua
require("hover.registry").register("your.nvim", {
  -- Asked only after every source declined, because a target is the more
  -- specific reading of the same place. Returns finished content — there is
  -- nothing to classify — or nil to decline.
  positions = {
    function(bufnr, row, col)
      local note = something_about(bufnr, row)
      if not note then
        return nil       -- silence is the common answer, and must stay cheap
      end
      return { lines = { note }, title = "your.nvim" }
    end,
  },
})
```

### When your answer is expensive

Both `sources` and `positions` accept a table entry instead of a bare
function, and the table can say so:

```lua
positions = {
  { fn = function(bufnr, row, col) … end, on_request = true },
}
```

An `on_request` contribution is asked **only for an explicit request** —
`:Hover show`, or a key bound to it — and never on the automatic trigger.

That flag exists because how expensive your answer is, is knowledge only you
have. Measured, the population it is for: a git start costs ~41 ms, a
`docker --version` 230 ms, `podman --version` 490 ms — the same whether they
hit or miss. A trigger that fires after every keystroke followed by quiet
cannot pay that, and the only lever before this was `:Hover positions off`,
which silences every registered plugin at once rather than the expensive one.

It also does **not** count as "something that could answer" when the trigger
decides whether to install itself at all. A buffer whose only contribution is
force-only gets no `CursorHold` — one that woke, asked nobody and slept again
would be pure cost.

Three things follow from the shape, and each is load-bearing:

- **Sources win.** On a path inside a deprecated call, the file is what the
  reader pointed at.
- **Nothing is cached.** A target has an identity to key a cache by and a
  position does not; what a position preview answers can depend on the whole
  buffer, so a stale entry would be a *wrong* answer rather than an old one.
  Freshness belongs to the plugin that registered it.
- **It is your job to be quiet.** The framework has no shape heuristic to
  apply here — it cannot know what your answer is about. Answer only where
  there is something worth interrupting a reader for. `:Hover positions off`
  exists for when that judgement turns out wrong, and it is a blunt
  instrument: it silences every registered plugin at once.

## Two things that must not be changed casually

Both were bugs, both took a long time to find, and both are easy to reintroduce with a
change that looks obviously correct.

### The float is positioned `relative = "editor"`, not `"cursor"`

Even though "one line below the cursor" is exactly what is wanted.

`nvim_win_get_position` reports a **wrong column** for a cursor-relative float when the
editor window does not start at column 0 — it adds the window's origin to a cursor
position that already contains it. Measured with a 26-column file tree: a float whose
frame is drawn at column ~59 reports **83**. Neovim draws it correctly; only the
self-report is wrong.

That is fatal here, because this float's geometry *is* the drawing box handed to the
terminal for an image. Everything downstream computes a correct offset from a wrong
origin, and the picture lands beside its own frame by the sidebar's width.

So `float.open` takes the cursor's true grid position from `screenpos()` and opens an
editor-relative float, which reports back exactly what it was given. **Reverting that to
`relative = "cursor"` brings the bug straight back**, and it only shows with a sidebar
open.

### The image is fitted to the drawing box, not to the frame

`canvas_cells` subtracts `draw_inset` before asking `fit_cells`, then adds it back for
the frame. That looks like an off-by-two and is not.

`images.anchor` keeps `draw_inset` cells free on every side, so a float sized to fit the
image exactly is drawn into a box two cells smaller per axis. Two cells off 20 rows is a
bigger relative change than two off 77 columns, so the ratio moves — and
`preserveAspectRatio=1` letterboxes the difference and centres it. Measured: ~2.7 cells
of empty space on the left for a 1200x675 image in a 77x20 frame, which reads as "the
image is shifted right".

### If a placement problem appears again

`images.nvim` ships the measurements as `:Image debug` (`report`, `columns`, `float`).
Two traps, both of which cost days:

- **A consistency check passing proves nothing about the origin.** Sent coordinates
  matching the reported float position held throughout both bugs above. Compare the
  report against reality — `:Image debug float` draws a marker at the reported corner for
  exactly that.
- **A generated test card cannot reveal an aspect-ratio problem**, because
  `images.testcard` builds it to whatever box it is handed. Reproduce with a real image.

## Health

```
:checkhealth hover
```

Four sections, and the reason there are four is that "the hover does nothing" has four
completely different causes that look identical from the outside.

| Section | What it answers |
| --- | --- |
| **hover.nvim** | Is `lib.nvim` there, and is it new enough — the one dependency with no fallback |
| **configuration** | Which mode is set, and every switch with its current state. Two warnings catch the silent cases: `mode: off`, and `manual` mode with no key bound to show anything — both leave a correctly installed plugin doing nothing |
| **optional contributors** | Which sibling plugins are installed, what each absent one is not doing, whether a link source is registered at all, and — read back off the registry — every name that registered, with a count per kind |
| **external tools** | `soffice` and `pdftoppm` on `PATH`, and — the part worth the section — *whether they are even needed*: with office rendering off, a missing `soffice` is information rather than a warning |

When a hover fails to appear for one specific thing rather than for everything,
[`:Hover why`](#the-hover-command) is the sharper tool: it names which gate declined.

---

## Modules

| Module | Job |
| --- | --- |
| `hover` | Orchestration: debounce, generation counter, `show`/`hide`/`scroll`/`dismiss`/`set_mode`/`set` |
| `hover.config` | The effective configuration, legacy normalization, and every predicate derived from it |
| `hover.config.DEFAULTS` | Plugin-side defaults, and why each one is what it is |
| `hover.switches` | Every runtime on/off switch, declared once — routes, completion and `status` all read from it |
| `hover.cache` | The LRU of built previews, and the rule about dropping it |
| `hover.registry` | Plugin sources and previews |
| `hover.classify` | Target string → typed target. Pure, no I/O beyond one `fs_stat` |
| `hover.formats` | What an extension names, and whether it is convertible |
| `hover.bare_path` | Paths with no link syntax; asks gopath.nvim when present |
| `hover.bare_git` | A git object id under the cursor — shape only, no process |
| `hover.scope` | Whether the cursor sits somewhere a path could be written at all |
| `hover.bare_url` | URLs with no link syntax, in any filetype |
| `hover.float` | The window |
| `hover.health` | `:checkhealth hover` |
| `hover.bindings.*` | Keymaps (borrowed and owned), the `:Hover` verb, the trigger autocmds |
| `hover.preview.text` | File heads, directory listings, the missing marker |
| `hover.preview.binary` | Is this text at all, and what to say when it is not |
| `hover.preview.office` | Office documents: the badge, or the converted PDF's page |
| `hover.preview.url` | URL details, optional fetch |
| `hover.preview.git` | `git show --stat` of an object, async |
| `hover.preview.media` | Images and PDF pages, via whatever provider is installed |

---

## Documentation

- [Features](docs/FEATURES/README.md) — **why** each feature has the shape it has: the
  measurements it was built against, the alternatives that were rejected, and the bugs
  that changed the design. Everything else here says *what*; that directory says *why*.
- [Installation](docs/installation.md) — requirements, every plugin manager, and the two
  rules that decide whether the hover works at all: `enable()` rather than `setup()`, and
  not lazy-loading it.
- [Integrations](docs/INTEGRATIONS.md) — who reaches whom, through which door, what
  degrades when a plugin is absent, and a table reading each symptom back to the plugin
  that owns it.
- [Bindings cheatsheet](docs/BINDINGS.md) — every keymap, user command, autocmd,
  highlight group and global variable this plugin installs, and which keys are borrowed
  rather than owned.
- [Roadmap](docs/ROADMAP.md) — what is deliberately not built yet and what would have to
  be settled first: which sibling plugin could contribute a preview and through which
  entry point, which features are missing, which of the things this plugin already does
  it does worse than it could — and what was considered and rejected.
- [Manual evidence](docs/MANUAL-EVIDENCE.md) — the eight things no CI can check
  (a drawn image, a resized one, a rasterized PDF page, a converted office document, and
  a contribution asked only on request), when each was last checked by hand, and on what.
- `:help hover` — the vimdoc: the same ground, offline.

### References

- Neovim: `:help nvim_open_win()`, `:help CursorHold`, `:help 'updatetime'`,
  `:help maparg()` / `:help mapset()` — the four APIs the borrowed-key lifecycle rests
  on.
- [iTerm2 inline images protocol (OSC 1337)](https://iterm2.com/documentation-images.html)
  — how images.nvim draws into the float.
