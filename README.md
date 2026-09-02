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
- [Scrolling a preview](#scrolling-a-preview)
- [Configuration](#configuration)
- [Contributing from a plugin](#contributing-from-a-plugin)
- [Two things that must not be changed casually](#two-things-that-must-not-be-changed-casually)
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

### What each plugin brings

| Plugin | What it is on its own | What it adds to the hover | Without it |
| --- | --- | --- | --- |
| [lib.nvim] — **required** | A reusable Lua/Neovim helper library with no third-party dependencies, shared by every plugin in this ecosystem | The `:Hover` verb and its `<Tab>` completion (`bindings.usercmd.composer`), the debounce behind `delay_ms`, the notifier every switch announcement goes through, the LRU under the preview cache, the autocmd helpers, and `image_preview.detect()` — which drawing provider is installed | hover.nvim does not load. This is the one dependency with no fallback |
| [markdown.nvim] | A self-contained Markdown toolkit: headings/TOC/folding, GFM tables, links and references, a cursor-action dispatcher | The link scanner — `[text](target)`, an `<img src>`/`<a href>`, or a whole captioned `<figure>` under the cursor becomes a target — and the `#heading` section preview, so `file.md#modules` opens on *that section* instead of the file's head. The single biggest upgrade this plugin can receive | Only bare paths start a hover, and `file.md#frag` shows the file's first lines |
| [images.nvim] | Shows images in the terminal over OSC 1337 — `:Image`, galleries, clipboard paste, zen view. The only provider that draws on native Windows Neovim in WezTerm | The picture itself, drawn into the float: pixel size where the header parser cannot read the format (WebP, SVG), the letterboxing fit, the `draw_inset` the anchor keeps free on every side, the deferred draw, and the terminal clear when the float closes. Also what makes a rasterized PDF page visible at all | An image target shows format, dimensions and size as text — and so does a PDF page |
| [pdfport.nvim] | PDFs in both directions: seven extraction backends, plus nine producers for creating, merging and rasterizing | `render_page()` — page 1 of a PDF as a PNG, and every further page scrolled to. And, once `:Hover office on`, `create()` runs LibreOffice headless so a `.docx`/`.xlsx`/`.pptx` becomes a page too | A PDF shows its size and why there is no page; an office document shows a badge naming the format |
| [gopath.nvim] | Multi-phase navigation from the cursor: LSP → Treesitter → whole-line extraction → suffix search → fuzzy alternate | `resolve_at_cursor()`, asked *before* Vim's own `<cfile>`: a truncated `...nvim/init.lua`, a `:line:col` suffix, a file findable only through `&path`/`rtp`. That is the "a path in `:messages` should hover too" case | Ordinary relative and absolute paths still resolve; truncated ones do not |
| [snacks.nvim] / [image.nvim] | Image providers speaking the Kitty graphics protocol | Recognised as providers, but neither can draw into an arbitrary existing window, so a picture still falls back to text. images.nvim wins whenever several are installed | Nothing changes |
| [reposcope.nvim] — *planned* | Search, preview and clone repositories from GitHub / GitLab / Codeberg, keeping every README it fetched in a cache keyed `owner/repo` | Nothing yet. The natural feature — cursor on `owner/repo`, that README's head in the float — needs no change here at all: it is a registry source plus a preview | No repository hover. Two questions have to be settled first — see [the roadmap](docs/ROADMAP.md) |

### The two doors

There are exactly two ways a plugin and the hover reach each other, and they are not
interchangeable.

| Door | How it works | Who arrives through it |
| --- | --- | --- |
| **Registry** (inbound) | The plugin calls `hover.registry.register(name, …)` and hands over a *source* ("what is under the cursor?") or a *preview* ("how do I render a target of this type?"). hover.nvim never says its name, and a sixth contributor needs no change here | markdown.nvim |
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
switching the feature off.

## The `:Hover` command

Every route completes with `<Tab>`, and the state argument may be omitted — which
toggles.

| Command | Does |
|---|---|
| `:Hover show` | one hover, here, now, ignoring every volume switch |
| `:Hover status` | the mode and every switch — as a chooser where picking a line toggles it, or as one message where lib.nvim has no UI kit |
| `:Hover why` | why nothing hovered *here* — which of the gates refused, and what to type about it |
| `:Hover pin` | keep this float on screen while the cursor goes elsewhere; again releases it |
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
| `positions` | `true` | Whether a registered *position* preview may open a float â€” a plugin saying something about where the cursor is, when it points at nothing. Costs nothing with none registered. |
| `paths.code` | `false` | Whether a bare path hovers inside executable code. Off: in a parsed buffer, only comments and strings are searched. Prose is untouched — see [Where a bare path is looked for](#where-a-bare-path-is-looked-for). |
| `office.convert` | `false` | Whether a `.docx`/`.xlsx`/`.pptx`/… is converted to a PDF and shown as a page. |
| `office.timeout_ms` | `60000` | LibreOffice's first start is slow, and a timeout that fires on it looks like a broken feature. |
| `scroll_keys.down` | `{ "<M-PageDown>", "<C-Down>" }` | |
| `scroll_keys.up` | `{ "<M-PageUp>", "<C-Up>" }` | |
| `dismiss_keys` | `{ "q", "<Esc>" }` | |
| `keymaps.show` | `false` | A key for `:Hover show`. No key is claimed unless asked for. |

The pre-1.0 spelling of three options is still accepted and normalized on the way in, so
a host that learned them while this plugin lived inside `lib.nvim` keeps working:
`enabled = false` reads as `mode = "off"`, `bare_paths` as `paths.enabled`, and
`url = { hover, fetch, timeout_ms }` as the `links` fields. Nothing downstream ever sees
the old shape.

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
this `require` actually does â€” none of those is something the cursor points
at, and the framework used to have no way to express them: no target meant no
hover, full stop.

A third kind of contribution answers for the **position**:

```lua
require("hover.registry").register("your.nvim", {
  -- Asked only after every source declined, because a target is the more
  -- specific reading of the same place. Returns finished content â€” there is
  -- nothing to classify â€” or nil to decline.
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

Three things follow from the shape, and each is load-bearing:

- **Sources win.** On a path inside a deprecated call, the file is what the
  reader pointed at.
- **Nothing is cached.** A target has an identity to key a cache by and a
  position does not; what a position preview answers can depend on the whole
  buffer, so a stale entry would be a *wrong* answer rather than an old one.
  Freshness belongs to the plugin that registered it.
- **It is your job to be quiet.** The framework has no shape heuristic to
  apply here â€” it cannot know what your answer is about. Answer only where
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
- [Manual evidence](docs/MANUAL-EVIDENCE.md) — the three things no CI can check
  (a drawn image, a rasterized PDF page, a converted office document), when each was
  last checked by hand, and on what.
- `:help hover` — the vimdoc: the same ground, offline.

### References

- Neovim: `:help nvim_open_win()`, `:help CursorHold`, `:help 'updatetime'`,
  `:help maparg()` / `:help mapset()` — the four APIs the borrowed-key lifecycle rests
  on.
- [iTerm2 inline images protocol (OSC 1337)](https://iterm2.com/documentation-images.html)
  — how images.nvim draws into the float.
