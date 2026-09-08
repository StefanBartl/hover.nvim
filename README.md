> **Beta stage — active development.** This repository is past its first shape and in
> active use, but the surface is not frozen: breaking changes are still possible. Pin a
> commit or tag if you depend on it.

# hover.nvim

```
 _
| |__   _____   _____ _ __
| '_ \ / _ \ \ / / _ \ '__|
| | | | (_) \ V /  __/ |
|_| |_|\___/ \_/ \___|_|
                  .nvim
```

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Neovim](https://img.shields.io/badge/Neovim-0.10%2B-57A143?logo=neovim&logoColor=white)](https://neovim.io)
[![Lua](https://img.shields.io/badge/Lua-5.1%2FLuaJIT-2C2D72?logo=lua&logoColor=white)](https://www.lua.org)
![Status](https://img.shields.io/badge/status-beta-orange)
![Platform](https://img.shields.io/badge/platform-Linux%20%7C%20macOS%20%7C%20Windows-lightgrey)
[![CI](https://github.com/StefanBartl/hover.nvim/actions/workflows/ci.yml/badge.svg)](https://github.com/StefanBartl/hover.nvim/actions/workflows/ci.yml)

Rest the cursor on something that points at a file — a markdown link, or a path
written as plain text — and a small float shows what it points at.

---

## Table of contents

- [Documentation](#documentation)
- [What it does](#what-it-does)
- [Around it](#around-it)
- [Requirements](#requirements)
- [Installation](#installation)
- [Quickstart](#quickstart)
- [What you get with the defaults](#what-you-get-with-the-defaults)
- [Why it does it that way](#why-it-does-it-that-way)
- [Health check](#health-check)
- [Contributing](#contributing)
- [Feedback](#feedback)
- [License](#license)

---

## Documentation

Start at [docs/README.md](docs/README.md), which says what is where and which
question each page answers. The pages a reader reaches for first:

- [Installation](docs/installation.md) — every plugin manager, the two rules below in full, and `:checkhealth hover`.
- [Configuration](docs/configuration.md) — every option, its default, and what it means.
- [Commands](docs/commands.md) — every `:Hover` route and its arguments.
- [Lua API](docs/api.md) — every function to call, and the registry contract a plugin or your own config contributes a hover through.
- [Bindings](docs/BINDINGS.md) — every keymap, autocmd, highlight group and global variable this plugin installs, and which keys are *borrowed* rather than owned.
- [Features](docs/FEATURES/README.md) — one page per decision, with the measurement behind each.
- [Workflow](docs/WORKFLOW.md) — the quiet ladder, resize against zoom against scroll, and what to reach for when a hover does not appear.
- [Integrations](docs/integrations.md) — who reaches whom, through which door, and a table reading each symptom back to the plugin that owns it.
- [Architecture](docs/architecture.md) — the module map, and the two invariants that must not be changed casually.
- [Health](docs/health.md) — what `:checkhealth hover` asks, section by section.
- [Contributing](docs/CONTRIBUTING.md) — ground rules, project layout, and how to add a preview type.

`:help hover` is the same ground, offline. `:DocMap` builds a browsable map of
this repository under `docs/map/`; it is generated and gitignored, so it is not
in the checkout.

---

## What it does

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

A reference in prose is a promise that something exists somewhere else.
Following it costs a jump, a look, and a jump back — enough friction that most of
the time you do not, and read on with a guess instead. hover.nvim answers the
reference in place.

What it can answer depends on the target:

| Target | Float shows |
| --- | --- |
| A text file | Its first lines, syntax-highlighted |
| A markdown file with `#heading` | That section (needs markdown.nvim) |
| A directory | Its entries |
| An image | The picture (needs a drawing provider), else format, dimensions, size |
| A PDF | Page 1, rendered (needs pdfport.nvim), else size and why not |
| An office document | A badge, or its first page once `:Hover office on` |
| A video | A still from it (needs media.nvim + ffmpeg), and the paging keys step through the file |
| A file with no text in it | A badge naming the format, not a screen of bytes |
| An `http(s)` link | Host, path and decoded query; plus status code and title with fetching on |
| A git object id | What that commit did (`git show --stat`) — only on `:Hover show` |
| A target that does not exist | That — often the most useful answer of all |

**Pictures and PDF pages open by themselves; everything else waits to be asked.**
That is the default, and it is not a limitation to work around: a picture is the
only thing this plugin shows that cannot be read off the line the cursor is
already on. `:Hover show` answers for every type regardless, and
`:Hover auto <type>` adds a type to what opens unprompted.

hover.nvim itself draws one float and knows almost nothing. Nearly everything
interesting in it is somebody else's job, done by a sibling plugin that may or
may not be installed — every one optional, reached through a `pcall` or through
the registry, and none of them named in its source.

---

## Around it

> **[markdown.nvim]** — the single biggest upgrade this plugin can receive.
> Without it only bare paths start a hover; with it `[text](target)`, an
> `<img src>`, and `file.md#heading` opening on *that section*.
>
> **[images.nvim]** — turns "1920×1080, 340 KB" into the actual picture, and is
> what makes a rasterized PDF page visible at all.
>
> **[pdfport.nvim]** — page 1 of a PDF as an image, every further page
> scrollable, and `.docx`/`.xlsx`/`.pptx` too once `:Hover office on`.
>
> **[media.nvim]** — a `.mp4` shown as a frame out of itself rather than as a
> size in bytes, with the paging keys as a scrub. It does not play video, and
> [nothing in a terminal Neovim can](docs/FEATURES/VIDEO.md).
>
> **[gopath.nvim]** — the same reference, followed rather than previewed. hover
> calls its `resolve_at_cursor()` through a `pcall`, so neither depends on the
> other.
>
> All of the above are soft: [docs/integrations.md](docs/integrations.md) is who
> reaches whom, and what degrades when each one is absent. [lib.nvim] is the one
> **hard** dependency — see [Requirements](#requirements).

---

## Requirements

| | |
| --- | --- |
| Neovim | **0.10+** |
| [lib.nvim] | required — `:Hover` is built on its usercmd composer, and the debounce, notifier, LRU and autocmd helpers come from there |

Optional, each detected at runtime and degrading to a lesser answer rather than
to an error:

| | |
| --- | --- |
| [markdown.nvim] | Link syntax, `<img src>`, and `#heading` section previews |
| [images.nvim] | Actually drawing pictures and rendered PDF pages |
| [pdfport.nvim] | PDF and office-document previews |
| [media.nvim] | Video stills, and what ffprobe knows about the file |
| [gopath.nvim] | Resolving references that are not written as paths |
| `git` | The git-object preview |
| `curl` | Fetching a link's status code and title |
| `ffmpeg` | The still itself — reached through media.nvim, which needs `ffprobe` from the same install |

---

## Installation

```lua
-- lazy.nvim
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

**Two rules decide whether this works at all**, and both are visible in that
spec:

1. **`enable()` is the switch, not `setup()`.** `setup()` configures and returns;
   `enable()` installs the trigger, attaches the buffers already open, and
   applies the keymaps. lazy.nvim's `opts = {}` calls only `setup()`, which
   leaves the plugin loaded, configured and completely inert. `enable(opts)`
   takes the same table, so turning it on and configuring it stays one call.
2. **Do not lazy-load it.** A path in a `.txt`, a code comment or a `:messages`
   dump is a target too, so an `ft = "markdown"` gate leaves the feature silently
   dead everywhere else — which reads as "it randomly doesn't work" rather than
   as a configuration choice. The cost is bounded on purpose:
   `plugin/hover.lua` requires one module and registers one command, and nothing
   else runs until `enable()` is called.

packer.nvim, vim-plug, mini.deps, a local checkout, and how to check that it
worked are in [docs/installation.md](docs/installation.md).

---

## Quickstart

Nothing else is required. Rest the cursor on a path, and a float appears.

When one does not, that is the question `:Hover why` exists to answer:

```vim
:Hover show            " one hover, here, now, ignoring every volume switch
:Hover why             " which gate refused, and what to type about it
:Hover dashboard          " the mode and every switch, as a board you can toggle
```

No key is claimed by default — a plugin that other plugins depend on has no
business taking one on their behalf. `keymaps = { show = "<leader>k" }` is the
one worth setting, and `:checkhealth hover` says so when `mode = "manual"` is
configured without it.

Verify your setup any time with:

```vim
:checkhealth hover
```

---

## What you get with the defaults

Six routes carry most of the daily use. Every route completes with `<Tab>`, and
the state argument may be omitted, which toggles.

| Command | Does |
| --- | --- |
| `:Hover show` | One hover, here, now, ignoring every volume switch |
| `:Hover why` | Why nothing hovered *here* — which gate refused, and what to type about it |
| `:Hover dashboard` | The mode, every switch and what opens by itself — a board where `<CR>` toggles the row and `?` lists the keys |
| `:Hover mode manual` | Nothing opens by itself any more; every preview still answers when asked |
| `:Hover auto [<type>]` | Which target types open by themselves |
| `:Hover links web on` | Let `http(s)` links hover too — off by default, because documentation is made of links. Pair it with `:Hover auto url` for the automatic trigger |

The full list is in [docs/commands.md](docs/commands.md), the keys in
[docs/BINDINGS.md](docs/BINDINGS.md).

---

## Why it does it that way

Each of these is a page of its own, because the interesting half is not the
feature but the decision behind it — nearly every one was made against a
measurement that contradicted the intuition it was meant to confirm.

| | |
| --- | --- |
| [Staying quiet](docs/FEATURES/QUIET.md) | Why so little is on by default: the noise diagnosis this started from, the three axes the opt-in model is built on, and the three modes |
| [Bare paths](docs/FEATURES/BARE-PATHS.md) | The one preview class whose value turns *negative* when it is wrong: how a path with no link syntax is recognised, where it is looked for, and the three measurements that shaped both |
| [Contributions](docs/FEATURES/CONTRIBUTIONS.md) | The registry: what another plugin or your own config can add, what `on_request` is for, and the bug only a live wiring could find |
| [Resizing](docs/FEATURES/RESIZE.md) | One operation with two honest answers, and why the ceiling is found by stepping into it rather than carried as a number |
| [Zooming](docs/FEATURES/ZOOM.md) | Same box, a narrower view: why a picture is cropped and a PDF page re-rendered at a higher DPI instead |
| [Zen](docs/FEATURES/ZEN.md) | The float on the whole editor — not a bigger window but a bigger *budget*, why it pins by default, and why `z` is the one key it could not have |
| [PDF links](docs/FEATURES/WEBPDF.md) | A link that answers with a PDF, shown as its first page — and the `text = true` in the fetch that would have corrupted every one of them |
| [Rendered pages](docs/FEATURES/SHOT.md) | A link shown as a picture of the page: why that is a different category from fetching, why the trigger gets a switch of its own, and the profile flag without which the render would go out as you |

[docs/FEATURES/README.md](docs/FEATURES/README.md) is the index, with a sentence
on each.

---

## Health check

```vim
:checkhealth hover
```

Asks whether `enable()` was ever called — the failure that looks like a broken
plugin and is a configuration choice — which sibling plugins were found and what
each one adds, and whether `mode = "manual"` was configured without a key to
trigger it. Section by section: [docs/health.md](docs/health.md).

---

## Contributing

Clone the repository and either symlink it or add it to your runtime path.
[docs/CONTRIBUTING.md](docs/CONTRIBUTING.md) has the ground rules and the project
layout; [docs/architecture.md](docs/architecture.md) carries the two invariants
that must not be changed casually, and [docs/api.md](docs/api.md) is the registry
contract if what you want is to contribute a hover rather than change this
plugin.

Pull requests very welcome.

---

## Feedback

Your feedback is very welcome. Use the
[issue tracker](https://github.com/StefanBartl/hover.nvim/issues) to report bugs,
suggest features or ask usage questions; anything more open-ended fits a
[discussion](https://github.com/StefanBartl/hover.nvim/discussions).

If you find this plugin useful, a ⭐ on GitHub supports its development.

---

## License

MIT — see [LICENSE](LICENSE).

[lib.nvim]: https://github.com/StefanBartl/lib.nvim
[markdown.nvim]: https://github.com/StefanBartl/markdown.nvim
[images.nvim]: https://github.com/StefanBartl/images.nvim
[pdfport.nvim]: https://github.com/StefanBartl/pdfport.nvim
[media.nvim]: https://github.com/StefanBartl/media.nvim
[gopath.nvim]: https://github.com/StefanBartl/gopath.nvim
