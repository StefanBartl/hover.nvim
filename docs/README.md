# hover.nvim documentation

What is here, and which question each page answers. [The README](../README.md) is the
short version of all of it; `:help hover` is the same ground offline.

## Getting it running

| Page | Answers |
| --- | --- |
| [installation.md](installation.md) | Requirements, every plugin manager, and the two rules that decide whether the hover works at all: `enable()` rather than `setup()`, and not lazy-loading it. Ends with how to check that it worked |
| [NAME-COLLISION.md](NAME-COLLISION.md) | Why installing this **and** `lewis6991/hover.nvim` silently leaves one of the two not there. Neither can work around it; install one |
| [health.md](health.md) | What `:checkhealth hover` asks, why it is five sections, and the warnings that catch a plugin which is installed correctly and doing nothing |

## Using it

| Page | Answers |
| --- | --- |
| [WORKFLOW.md](WORKFLOW.md) | How the pieces combine day to day: the quiet ladder and which lever to reach for, scroll against resize against zoom, and what to do when no hover appears |
| [commands.md](commands.md) | Every `:Hover` route, its arguments, and what each one does |
| [BINDINGS.md](BINDINGS.md) | Every keymap, user command, autocmd, highlight group and global variable this plugin installs — and which keys are *borrowed* rather than owned |
| [configuration.md](configuration.md) | Every option `setup()` takes, with its default and what it means |
| [api.md](api.md) | Every Lua function a config or a plugin can call, and the registry contract a contributor registers through |

## Why it is the way it is

| Page | Answers |
| --- | --- |
| [FEATURES/](FEATURES/README.md) | One page per feature, and each one is about the **decision** rather than the feature: the measurement it was built against, the alternatives that were rejected, and the bug that changed the design |
| [integrations.md](integrations.md) | Who reaches whom and through which door, what degrades when a plugin is absent, and a table reading each symptom back to the plugin that owns it |
| [architecture.md](architecture.md) | The module map, and the two invariants a plausible-looking change reintroduces a bug through |
| [MANUAL-EVIDENCE.md](MANUAL-EVIDENCE.md) | The things no CI can check — a drawn image, a rasterized page, a converted document, a contribution asked only on request — with the date each was last seen by a person, and on what |

## Here, but not prose

**`install.json`** is the machine-readable declaration of the external tools this plugin
can use, read by `:Lib deps show hover.nvim`. What the tools are *for* is in
[installation.md](installation.md) and [health.md](health.md).

## Not here at all

**The roadmap.** What is deliberately not built yet, and what was considered and
rejected, is planning material rather than documentation: it answers a question the
author has, not one a reader of this plugin has. It lives outside the repository.

**`docs/map/`.** `:DocMap` builds a browsable module map there. It is generated and
gitignored, so it is not in the checkout — run it when you want it.
