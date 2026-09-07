# Contributing to hover.nvim

Thank you for your interest! Bugs, ideas and questions are welcome in the
[issue tracker](https://github.com/StefanBartl/hover.nvim/issues); pull requests
very welcome.

**Before changing anything, read [`architecture.md`](architecture.md)** — it
carries the two invariants that must not be changed casually — and the page under
[`FEATURES/`](FEATURES/README.md) covering the area you are touching. Nearly
every default in this plugin was set against a measurement that contradicted the
intuition it was meant to confirm, and the measurement is written down.

If what you want is to *contribute a hover* rather than change this plugin, you
do not need to fork it: [`api.md`](api.md) is the registry contract, and
[`FEATURES/CONTRIBUTIONS.md`](FEATURES/CONTRIBUTIONS.md) is why it has the shape
it has.

## Getting the repository into a session

Clone it and either symlink the checkout into your plugin directory or add it to
the runtime path directly:

```lua
vim.opt.rtp:prepend("/path/to/hover.nvim")
require("hover").enable()
```

`enable()`, not `setup()`. `setup()` leaves the plugin loaded, configured and
completely inert — which is the single most common way to conclude the plugin is
broken.

## Ground rules

- Lua only, idiomatic Neovim Lua. 2-space indentation.
- **No sibling plugin is named in the source outside the integration layer.**
  Everything optional is reached through a `pcall` or through the registry, and
  its absence produces a lesser answer, never an error. If your change makes a
  preview fail when a plugin is missing, the fallback is the missing part.
- **Quiet by default.** A new preview type does not open by itself unless it
  cannot be read off the line the cursor is already on — the reasoning is
  [`FEATURES/QUIET.md`](FEATURES/QUIET.md). It gets a switch under `:Hover auto`
  instead.
- **Every refusal is explainable.** `:Hover why` has to be able to name the gate
  that said no. A new gate that does not report itself there turns "nothing
  happened" into an unanswerable question.
- **This plugin is depended on by others.** It claims no keymap by default and
  must not start doing so.
- Commands are registered through `lib.nvim.bindings.usercmd.composer`.
- Descriptive commit messages.

## Project layout

| Path | Contains |
| --- | --- |
| `lua/hover/preview/` | One module per target type: text, directory, image, PDF, office, URL, git object |
| `lua/hover/bindings/` | The `:Hover` route tree and the optional keymaps |
| `lua/hover/config/` | Defaults, the mode and switch model, `setup()` / `enable()` |
| `lua/hover/@types/` | The registry contract and the shared type definitions |
| `docs/FEATURES/` | One page per decision, each with its measurement |
| `docs/` | Everything the README links to |
| `TESTS/` | The spec suite |

## Adding a preview type

1. Implement it under `lua/hover/preview/`, returning content or a reason it
   cannot. Never an error.
2. Give it a type name, a `:Hover auto <type>` switch, and a default of *off*
   unless it meets the bar in [`FEATURES/QUIET.md`](FEATURES/QUIET.md).
3. Teach `:Hover why` to name your gate when it refuses.
4. If it needs a sibling plugin or a CLI tool, reach it through a `pcall`, add
   the degraded answer, and add the row to
   [`integrations.md`](integrations.md) — including the symptom a reader would
   see when it is absent.
5. Report on it in `:checkhealth hover`.
6. Add a spec under `TESTS/`, including the absent-dependency path.
7. Write the page under [`FEATURES/`](FEATURES/README.md) if the decision behind
   it is more interesting than the feature.

## Tests

`TESTS/` is a [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)
busted-style suite; no sibling plugin has to be installed to run it.
[GitHub Actions](../.github/workflows/ci.yml) runs it on every push and PR to
`main`.

## Workflow

1. Fork the repository.
2. Branch as `feature/<name>`.
3. Make the change, add a spec, update the affected pages under `docs/`.
4. Open a PR with a clear description of what changed and why.
