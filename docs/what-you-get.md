# What you get with the defaults

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

No key is bound by default; `keymaps = { show = "<leader>k" }` is the one worth
setting. The full command list is in [commands.md](commands.md), every key,
autocmd and highlight group this plugin installs in [BINDINGS.md](BINDINGS.md).
