# Installation

## Requirements

- Neovim >= 0.10
- [lib.nvim](https://github.com/StefanBartl/lib.nvim) — **required**, with no fallback.
  The `:Hover` command composer, the debounce behind `delay_ms`, the notifier, the LRU
  under the preview cache and the autocmd helpers all come from it.
- No external tools. Everything hover.nvim does on its own is Neovim and the filesystem;
  the things that shell out — rasterizing a PDF page, converting an office document —
  belong to [pdfport.nvim](https://github.com/StefanBartl/pdfport.nvim) and are optional.

Four optional contributors, none required, each upgrading exactly one row of what the
float can show: markdown.nvim, images.nvim, pdfport.nvim, gopath.nvim. What each brings
and what its absence costs is in [the README's Integrations
section](../README.md#integrations).

## Two rules that decide whether this works

Everything else on this page is a plugin manager's syntax for these two.

### 1. `enable()` is what turns it on, not `setup()`

`setup()` configures and returns. `enable()` installs the `FileType` trigger, attaches
the buffers that are already open, registers `:Hover`, and applies the configured
keymaps.

That distinction has a sharp edge in lazy.nvim specifically: **`opts = {}` calls
`setup()` and nothing else**, so a spec written that way leaves the plugin configured,
loaded, and completely inert. Use `config = function() require("hover").enable() end`.
`enable(opts)` takes the same table `setup()` does, so turning it on and configuring it
stays one call.

`enable()` is idempotent — its two augroups are cleared and rebuilt on every call — so two
plugins calling it still leaves one set of autocmds.

### 2. Do not lazy-load it

A path in a `.txt`, a code comment, a commit message or a `:messages` dump is a target
too. A spec that loads on `ft = "markdown"` therefore leaves the feature silently dead in
every other filetype, which reads as *"it randomly doesn't work"* rather than as a
configuration choice — and that is a much more expensive kind of bug than a slow startup.

The cost of not lazy-loading is small and bounded on purpose: `plugin/hover.lua` requires
one module and registers one command. No autocmd, no keymap, no preview machinery runs
until `enable()` is called.

> markdown.nvim calls `require("hover").enable()` from its own autocmds. That is a
> convenience, not the intended switch: markdown.nvim is normally `ft`-lazy itself, so in
> a session that never opens a `.md` file nothing would ever turn the hover on. Call
> `enable()` from a spec of your own.

## lazy.nvim

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

`priority` only affects `lazy = false` plugins, and only their load order among
themselves — the default is 50. A high one here puts hover.nvim up before the plugins
that register into it, so a host's `setup()` is never the thing that has to pull it in.
It is a tidiness measure rather than a requirement: `require("hover.registry")` resolves
whenever it is called.

Configuration goes in the same call — the whole spec, so it can be pasted as
it stands:

```lua
{
  "StefanBartl/hover.nvim",
  lazy = false,
  priority = 900,
  dependencies = { "StefanBartl/lib.nvim" },
  config = function()
    require("hover").enable({
      mode = "manual",
      keymaps = { show = "<leader>k" },
    })
  end,
}
```

## packer.nvim

```lua
use({
  "StefanBartl/hover.nvim",
  requires = { "StefanBartl/lib.nvim" },
  config = function()
    require("hover").enable()
  end,
})
```

Plain `use` is right. Do not reach for `opt = true`, `ft`, `cmd` or `keys` — packer's
lazy-loading options are exactly the thing rule 2 is about.

## vim-plug

```vim
Plug 'StefanBartl/lib.nvim'
Plug 'StefanBartl/hover.nvim'
```

```vim
" after plug#end()
lua require("hover").enable()
```

vim-plug's `for` and `on` do the same damage as any other filetype gate. Load it
unconditionally.

## mini.deps

```lua
local add = MiniDeps.add

add({ source = "StefanBartl/lib.nvim" })
add({ source = "StefanBartl/hover.nvim" })

require("hover").enable()
```

`MiniDeps.later(function() require("hover").enable() end)` is fine too — deferring
`enable()` past startup costs the first few seconds of a session and nothing else. That
is a different thing from a filetype gate, which may never fire at all.

## From a local checkout

Point the spec at the directory instead of the repository; nothing else changes.

```lua
{ dir = "/path/to/hover.nvim", lazy = false, priority = 900,
  dependencies = { "StefanBartl/lib.nvim" },
  config = function() require("hover").enable() end }
```

No build step, no generated files: the plugin is Lua and a vimdoc. Helptags are the one
thing a plugin manager normally generates for you — `:helptags doc` inside the checkout
if `:help hover` comes back empty.

## Checking that it worked

```vim
:checkhealth hover
```

Four sections: lib.nvim, the configuration, the optional contributors, and the external
tools. Each contributor check asks for the entry point that is actually called rather
than for the module, so "installed" and "answers" cannot drift apart. The configuration
section prints the mode and every switch, and warns where the two disagree with each
other — `mode = "manual"` with no key bound to `show`, for instance, because from the
outside that is indistinguishable from a broken plugin. The tools section looks for
`pdftoppm` and — only when office rendering is on — `soffice`.

```vim
:Hover status
```

The mode and all seven switches in one message. `:Hover` is registered from
`plugin/hover.lua` whether or not anything called `enable()`, so this answers even from
the session where the hover appears to be doing nothing — which is the session someone
typing it is usually in.

If `:Hover` itself does not exist, the plugin is not on `'runtimepath'` at all; check the
plugin manager before anything on this page.

## Turning it off

```lua
{ "StefanBartl/hover.nvim", init = function() vim.g.hover_disable = true end }
```

`vim.g.hover_disable` forces `mode = "off"` and outranks anything a plugin configures, so
a host enabling its hover cannot override you switching the feature off.
`hover.set_mode()` keeps the variable in step with the runtime mode, so the two cannot
disagree.

`vim.g.loaded_hover = true` goes one step further and suppresses even the `:Hover`
command.

## Related

- [Integrations](INTEGRATIONS.md) — what each optional plugin contributes, and what
  degrades without it.
- [Bindings](BINDINGS.md) — every keymap, user command, autocmd, highlight group and
  global variable this plugin installs.
- [README](../README.md#configuration) — the full `setup()` option table.
