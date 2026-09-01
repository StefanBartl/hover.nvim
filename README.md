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

> **On the name.** [lewis6991/hover.nvim](https://github.com/lewis6991/hover.nvim) is an
> unrelated and well-known plugin for LSP-style hover providers. The repository names do
> not collide, but the Lua module root does: both ship `lua/hover/`, so installing both
> leaves whichever is earlier on `'runtimepath'` shadowing the other. Pick one.

## Table of contents

- [What it previews](#what-it-previews)
- [Quickstart](#quickstart)
- [What is opt-in, and why](#what-is-opt-in-and-why)
- [Modes](#modes)
- [The `:Hover` command](#the-hover-command)
- [Bare paths](#bare-paths)
- [Waving one hover away](#waving-one-hover-away)
- [Scrolling a preview](#scrolling-a-preview)
- [Configuration](#configuration)
- [Contributing from a plugin](#contributing-from-a-plugin)
- [Two things that must not be changed casually](#two-things-that-must-not-be-changed-casually)
- [Modules](#modules)
- [Literature and references](#literature-and-references)

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
| a target that does not exist | that — often the most useful answer of all |

Every contributor below is optional, and **none of them is required**:

| Plugin | Contributes | Without it |
| --- | --- | --- |
| **markdown.nvim** | finding a link / `<figure>` in a line; `#heading` section previews | only bare paths start a hover; `file.md#frag` shows the file's head |
| **images.nvim** | draws the picture into the float (OSC 1337) | an image target shows format, dimensions and size as text |
| **pdfport.nvim** | rasterizes page 1 of a PDF; converts an office document to a PDF | a PDF shows its size and why it could not be rendered |
| **gopath.nvim** | resolves truncated paths (`...nvim/init.lua:42`) and `:line:col` suffixes | ordinary relative and absolute paths still resolve; truncated ones do not |

The long version — every entry point, and a table reading each symptom back to the plugin
that owns it — is [docs/INTEGRATIONS.md](docs/INTEGRATIONS.md).

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
is one call.

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
| `:Hover status` | the mode and every switch, in one message |
| `:Hover mode [auto\|manual\|off]` | set the mode; omitted, it reports the current one |
| `:Hover toggle` | off if it is on, back to `auto` if it is off |
| `:Hover links [on\|off\|toggle]` | whether link syntax hovers at all |
| `:Hover links web [on\|off\|toggle]` | whether http(s) links hover. Implies `links on` |
| `:Hover links web fetch [on\|off\|toggle]` | fetch for status code and title. Implies `links web on` |
| `:Hover paths [on\|off\|toggle]` | whether a path written in prose hovers |
| `:Hover paths missing [on\|off\|toggle]` | whether a path resolving to nothing is marked broken |
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
| `hover.bare_url` | URLs with no link syntax, in any filetype |
| `hover.float` | The window |
| `hover.health` | `:checkhealth hover` |
| `hover.bindings.*` | Keymaps (borrowed and owned), the `:Hover` verb, the trigger autocmds |
| `hover.preview.text` | File heads, directory listings, the missing marker |
| `hover.preview.binary` | Is this text at all, and what to say when it is not |
| `hover.preview.office` | Office documents: the badge, or the converted PDF's page |
| `hover.preview.url` | URL details, optional fetch |
| `hover.preview.media` | Images and PDF pages, via whatever provider is installed |

## Literature and references

- [`docs/INTEGRATIONS.md`](docs/INTEGRATIONS.md) — who reaches whom, through which door,
  and what degrades when a plugin is absent.
- [`docs/BINDINGS.md`](docs/BINDINGS.md) — every keymap, user command and autocmd this
  plugin installs.
- [`docs/ROADMAP.md`](docs/ROADMAP.md) — what is deliberately not built yet.
- `:help hover` — the vimdoc, same content, offline.
- Neovim, `:help nvim_open_win()`, `:help CursorHold`, `:help 'updatetime'`,
  `:help maparg()` / `:help mapset()` — the four APIs the borrowed-key lifecycle rests on.
- [iTerm2 inline images protocol (OSC 1337)](https://iterm2.com/documentation-images.html)
  — how images.nvim draws into the float.
