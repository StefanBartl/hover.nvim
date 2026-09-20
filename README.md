> **Beta stage — active development.** This repository is past its first shape and in
> active use, but the surface is not frozen: breaking changes are still possible. Pin a
> commit or tag if you depend on it.

# hover.nvim

```
██╗  ██╗ ██████╗ ██╗   ██╗███████╗██████╗
██║  ██║██╔═══██╗██║   ██║██╔════╝██╔══██╗
███████║██║   ██║██║   ██║█████╗  ██████╔╝
██╔══██║██║   ██║╚██╗ ██╔╝██╔══╝  ██╔══██╗
██║  ██║╚██████╔╝ ╚████╔╝ ███████╗██║  ██║
╚═╝  ╚═╝ ╚═════╝   ╚═══╝  ╚══════╝╚═╝  ╚═╝
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

> **Do not install this alongside [lewis6991/hover.nvim](https://github.com/lewis6991/hover.nvim).**
> The repository names do not collide; the Lua module root does, and the loser is simply
> not there — nothing is reported and nothing fails. See
> [docs/NAME-COLLISION.md](docs/NAME-COLLISION.md).
>
> **[markdown.nvim](https://github.com/StefanBartl/markdown.nvim)** — the single biggest
> upgrade this plugin can receive. Without it only bare paths start a hover; with it
> `[text](target)`, an `<img src>`, and `file.md#heading` opening on *that section*.
>
> **[images.nvim](https://github.com/StefanBartl/images.nvim)** — turns "1920×1080, 340 KB"
> into the actual picture, and is what makes a rasterized PDF page visible at all.
>
> **[pdfport.nvim](https://github.com/StefanBartl/pdfport.nvim)** — page 1 of a PDF as an
> image, every further page scrollable, and `.docx`/`.xlsx`/`.pptx` too once
> `:Hover office on`.
>
> **[media.nvim](https://github.com/StefanBartl/media.nvim)** — a `.mp4` shown as a frame
> out of itself rather than as a size in bytes, and `<CR>` plays it, video and sound, in a
> real mpv window or whatever this machine already opens a video with.
>
> **[gopath.nvim](https://github.com/StefanBartl/gopath.nvim)** — the same reference,
> followed rather than previewed. hover calls its `resolve_at_cursor()` through a `pcall`,
> so neither depends on the other.
>
> All of the above are soft: [docs/integrations.md](docs/integrations.md) is who reaches
> whom, and what degrades when each one is absent.
> [lib.nvim](https://github.com/StefanBartl/lib.nvim) is the one **hard** dependency.

---

## Documentation

Start at [docs/README.md](docs/README.md) — what's where, and which question
each page answers.

### The Basics

- [Requirements](docs/installation.md#requirements) — Neovim version, required plugins and CLI tools.
- [Installation](docs/installation.md) — plugin managers and load-trigger variants.
- [Quickstart](docs/quickstart.md) — the first thing to run after installing.

### Configuration

- [What you get with the defaults](docs/what-you-get.md) — the six routes that carry most of the daily use.
- [All options](docs/configuration.md) — every `setup()` option and its default.
- [Commands](docs/commands.md) / [Bindings cheatsheet](docs/BINDINGS.md)

### The Rest

- [What it does and what not](docs/scope.md) — the reference table, at a glance.
- [Why it does it that way](docs/FEATURES/README.md) — one page per decision, with the measurement behind each.
- [Health check](docs/health.md) — what `:checkhealth hover` reports, section by section.
- [Contributing](docs/CONTRIBUTING.md)
- [Feedback](https://github.com/StefanBartl/hover.nvim/issues)

`:help hover` is the same reference inside the editor.

---

## License

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

hover.nvim is released under the [MIT License](https://opensource.org/licenses/MIT).
