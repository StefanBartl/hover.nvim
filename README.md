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

> **Alpha stage — active development.** This repository is in its development phase — breaking changes
> are to be expected at any time. Pin a commit or tag if you depend on it.

---

## Where it sits in the collection

hover.nvim draws one float and knows almost nothing. Nearly everything interesting in it
is somebody else's job, done by a sibling plugin that may or may not be installed — every
one of them optional, reached through a `pcall` or through the registry.

- **[markdown.nvim]** — the single biggest upgrade this plugin can receive: without it
  only bare paths start a hover, with it `[text](target)`, an `<img src>`, and
  `file.md#heading` opening on *that section*.
- **[images.nvim]** — turns "1920×1080, 340 KB" into the actual picture, and is what
  makes a rasterized PDF page visible at all.
- **[pdfport.nvim]** — page 1 of a PDF as an image, every further page scrollable, and
  `.docx`/`.xlsx`/`.pptx` too once `:Hover office on`.

[lib.nvim] is the one **hard** dependency, not a recommendation: `:Hover` is built on its
usercmd composer, and the debounce, notifier, LRU and autocmd helpers come from there.
Further plugins register into the hover through the same public door, and none of them is
named in its source — [docs/integrations.md](docs/integrations.md) is who reaches whom,
and what degrades when each one is absent.

---

## Installation

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

**Two rules decide whether this works at all**, and both are visible in that spec:

1. **`enable()` is the switch, not `setup()`.** `setup()` configures and returns;
   `enable()` installs the trigger, attaches the buffers already open, and applies the
   keymaps. lazy.nvim's `opts = {}` calls only `setup()`, which leaves the plugin loaded,
   configured and completely inert. `enable(opts)` takes the same table, so turning it on
   and configuring it stays one call.
2. **Do not lazy-load it.** A path in a `.txt`, a code comment or a `:messages` dump is a
   target too, so an `ft = "markdown"` gate leaves the feature silently dead everywhere
   else — which reads as "it randomly doesn't work" rather than as a configuration
   choice. The cost is bounded on purpose: `plugin/hover.lua` requires one module and
   registers one command, and nothing else runs until `enable()` is called.

packer.nvim, vim-plug, mini.deps, a local checkout, and how to check that it worked are
in [docs/installation.md](docs/installation.md).

---

## Quickstart

Nothing else is required. Rest the cursor on a path and a float appears:

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
| a git object id | what that commit did (`git show --stat`) — only on `:Hover show` |
| a target that does not exist | that — often the most useful answer of all |

**Pictures and PDF pages open by themselves; everything else waits to be asked.** That is
the default, and it is not a limitation to work around — a picture is the only thing this
plugin shows that cannot be read off the line the cursor is on. `:Hover show` answers for
every type regardless, and `:Hover auto file` adds a type to what opens unprompted.

Six routes carry most of the daily use:

| Command | Does |
| --- | --- |
| `:Hover show` | one hover, here, now, ignoring every volume switch |
| `:Hover why` | why nothing hovered *here* — which gate refused, and what to type about it |
| `:Hover status` | the mode and every switch, as a chooser where picking a line toggles it |
| `:Hover mode manual` | nothing opens by itself any more; every preview still answers when asked |
| `:Hover auto [<type>]` | which target types open by themselves |
| `:Hover links web on` | let http(s) links hover too — off by default, because documentation is made of links |

Every route completes with `<Tab>` and the state argument may be omitted, which toggles.
The full list is in [docs/commands.md](docs/commands.md), the keys in
[docs/BINDINGS.md](docs/BINDINGS.md).

No key is claimed by default — a plugin that other plugins depend on has no business
taking one on their behalf. `keymaps = { show = "<leader>k" }` is the one worth setting,
and `:checkhealth hover` says so when `mode = "manual"` is configured without it.

---

## What it does, and why it does it that way

Each of these is a page of its own, because the interesting half is not the feature but
the decision behind it — nearly every one was made against a measurement that
contradicted the intuition it was meant to confirm.

| | |
| --- | --- |
| [Staying quiet](docs/FEATURES/QUIET.md) | Why so little is on by default: the noise diagnosis this started from, the three axes the opt-in model is built on, and the three modes |
| [Bare paths](docs/FEATURES/BARE-PATHS.md) | The one preview class whose value turns *negative* when it is wrong: how a path with no link syntax is recognised, where it is looked for, and the three measurements that shaped both |
| [Contributions](docs/FEATURES/CONTRIBUTIONS.md) | The registry: what another plugin or your own config can add, what `on_request` is for, and the bug only a live wiring could find |
| [Resizing](docs/FEATURES/RESIZE.md) | One operation with two honest answers, and why the ceiling is found by stepping into it rather than carried as a number |
| [Zooming](docs/FEATURES/ZOOM.md) | Same box, a narrower view: why a picture is cropped and a PDF page re-rendered at a higher DPI instead |

[docs/FEATURES/README.md](docs/FEATURES/README.md) is the index, with a sentence on each.

---

## Documentation

Start at [docs/README.md](docs/README.md), which says what is where and which question
each page answers. The pages a reader reaches for first:

- [Installation](docs/installation.md) — every plugin manager, the two rules above in
  full, and `:checkhealth hover`.
- [Configuration](docs/configuration.md) — every option, its default, and what it means.
- [Commands](docs/commands.md) — every `:Hover` route and its arguments.
- [API](docs/api.md) — every Lua function to call, and the registry contract a plugin or
  your own config contributes a hover through.
- [Bindings](docs/BINDINGS.md) — every keymap, autocmd, highlight group and global
  variable this plugin installs, and which keys are *borrowed* rather than owned.
- [Workflow](docs/WORKFLOW.md) — how the pieces combine once several of them exist: the
  quiet ladder, resize against zoom against scroll, and what to reach for when a hover
  does not appear.
- [Integrations](docs/integrations.md) — who reaches whom, through which door, and a
  table reading each symptom back to the plugin that owns it.
- [Architecture](docs/architecture.md) — the module map, and the two invariants that must
  not be changed casually.
- [Health](docs/health.md) — what `:checkhealth hover` asks, section by section, and the
  warnings that catch a plugin which is installed correctly and doing nothing.
- `:help hover` — the same ground, offline.

`:DocMap` builds a browsable map of this repository under `docs/map/`; it is generated
and gitignored, so it is not in the checkout.

---

## License

MIT. See [LICENSE](LICENSE).

[lib.nvim]: https://github.com/StefanBartl/lib.nvim
[markdown.nvim]: https://github.com/StefanBartl/markdown.nvim
[images.nvim]: https://github.com/StefanBartl/images.nvim
[pdfport.nvim]: https://github.com/StefanBartl/pdfport.nvim
