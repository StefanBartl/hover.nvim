# Bindings

Every keymap, user command and autocmd hover.nvim installs. Nothing else is
registered anywhere.

The one thing to know before reading the tables: **most of the keys here are
borrowed, not owned.** They exist for as long as one float is on screen and
are handed back the moment it closes — restoring whatever mapping they
displaced, rather than deleting it. The float is `focusable = false`, so it
never receives a keystroke and can never hold a mapping of its own; a
buffer-local mapping on the *document* would leak into buffers with no hover
open. Global-and-temporary is the only shape that works.

---

## Keymaps

### Owned — bound at `setup()`, kept

| Config key | Default | Does |
| --- | --- | --- |
| `keymaps.show` | `false` | `hover.show({ force = true })` — one hover, here, now, ignoring every volume switch |

No key is claimed by default. A plugin that other plugins depend on has no
business taking one on their behalf, and `:Hover show` covers the same ground.
The one case that wants a key is `mode = "manual"`, where nothing opens a
float unprompted — `:checkhealth hover` warns when that mode is configured
with no key bound.

Any entry takes a single key, a list, or `false` to bind nothing:

```lua
require("hover").setup({ keymaps = { show = "<leader>k" } })
require("hover").setup({ keymaps = { show = { "<leader>k", "K" } } })
require("hover").setup({ keymaps = { show = false } })
```

### Borrowed — bound only while a float is on screen

| Config key | Default | Bound for | Does |
| --- | --- | --- | --- |
| `dismiss_keys` | `q`, `<Esc>` | **every** hover | dismiss this hover until the cursor reaches another target |
| `scroll_keys.down` | `<M-PageDown>`, `<C-Down>` | scrollable hovers only | next screenful of lines, or next PDF page |
| `scroll_keys.up` | `<M-PageUp>`, `<C-Up>` | scrollable hovers only | back |

Three things follow from "borrowed", and each has been a bug at some point:

- **A key already mapped is restored, not deleted.** `maparg(..., true)`
  captures it before the mapping is set; `mapset` puts it back after.
- **The same key listed twice is taken once.** A key that is both a dismiss
  key and a scroll key would otherwise be "restored" to one of our own
  mappings and outlive the float forever. Dismiss wins: the binding that
  always applies beats the one that only sometimes does.
- **Scroll keys are not bound when there is nothing to scroll.** An image, or
  a file that already fits in the float, leaves them alone entirely and they
  keep whatever they mean elsewhere.

The cost of `q` being borrowed is that it records no macro for as long as one
float is up, and none after it. That is the deliberate trade for a dismissal
that works without focusing the float.

A configured list **replaces** the default rather than extending it —
`{ down = { "<C-n>" } }` binds `<C-n>` and nothing else, and `{}` binds
nothing. Both directions can be turned off entirely and driven from your own
mappings instead:

```lua
vim.keymap.set("n", "<C-d>", function() require("hover").scroll(1) end)
vim.keymap.set("n", "<C-u>", function() require("hover").scroll(-1) end)
```

`scroll(delta)` and `dismiss()` both return `false` when there is no open
hover, so either is safe to bind unconditionally.

---

## User commands

One compound verb, `<Tab>`-completed at every level. The state argument may be
omitted, which toggles.

| Command | Does |
| --- | --- |
| `:Hover show` | one hover, here, now, ignoring every volume switch |
| `:Hover status` | the mode and every switch — a chooser where `<CR>` toggles the picked line, falling back to one message without lib.nvim`s UI kit |
| `:Hover why` | why nothing hovered at the cursor -- which gate refused, and what to type about it |
| `:Hover mode [auto\|manual\|off]` | set the mode; omitted, it reports the current one |
| `:Hover toggle` | off if it is on, back to `auto` if it is off |
| `:Hover links [on\|off\|toggle]` | whether link syntax hovers at all |
| `:Hover links web [on\|off\|toggle]` | whether http(s) links hover. Implies `links on` |
| `:Hover links web fetch [on\|off\|toggle]` | fetch a link for its status code and title. Implies `links web on` |
| `:Hover paths [on\|off\|toggle]` | whether a path written in prose hovers |
| `:Hover paths missing [on\|off\|toggle]` | whether a path resolving to nothing is marked broken |
| `:Hover paths code [on\|off\|toggle]` | whether a bare path hovers inside executable code, not just comments and strings. Implies `paths on` |
| `:Hover positions [on\|off\|toggle]` | whether a registered plugin may answer for a cursor position that points at nothing |
| `:Hover images [on\|off\|toggle]` | whether pictures are drawn into the float, or described |
| `:Hover office [on\|off\|toggle]` | whether office documents render through a PDF |

`:Hover` is registered from `plugin/hover.lua`, so it exists before `setup()`
runs and even in a session where nothing turned the hover on. That is the
point: `:Hover mode auto` has to be reachable from exactly the state where
someone is most likely to type it.

The routes are **generated** from `hover.switches`, not written out. Dispatch,
completion, the descriptions above and `:Hover status` all read the same
table, so they cannot drift apart.

No keymap is offered for these. A setting thrown a few times a week, from
wherever you happen to be, does not need to be one keystroke away.

### No range support, deliberately

Every route here acts on the cursor position or on a session-wide switch.
Neither has a meaningful reading over a line range, and a `:'<,'>Hover links
on` that silently ignored its range would be worse than one that does not
accept it.

---

## Autocmds

Two augroups, both cleared and rebuilt on every `enable()` — which is what
makes `enable()` idempotent.

| Group | Event | Scope | Does |
| --- | --- | --- | --- |
| `HoverEnable` | `FileType` | pattern from `filetypes` (default `*`) | attach the hover to this buffer |
| `HoverBuf<n>` | `CursorHold` | one buffer | trigger, under the default trigger |
| `HoverBuf<n>` | `CursorMoved` | one buffer | trigger, under `trigger = { "cursor" }` or `{ "mouse" }` |
| `HoverBuf<n>` | `BufLeave`, `InsertEnter` | one buffer | hide the float |

Three rules decide whether a per-buffer group is created at all:

- **A non-empty `'buftype'` is never attached to.** A picker, a file tree, a
  terminal or a dashboard has no document to hover in, and a float opening
  over one is always wrong. One check catches all of them, which a filetype
  blocklist could never keep up with.
- **Nothing that could answer means no autocmd.** With `paths.enabled = false`
  and no registered source, there is nothing to say, so no `CursorHold` is
  installed rather than one that wakes to find that out.
- **`mode = "manual"` installs the hide autocmds and no trigger.** That is the
  whole mode: every preview still available, none of them unprompted.

`enable()` also attaches directly to buffers that are already loaded, because
`FileType` has long since fired for them and would otherwise leave the very
buffer you are sitting in without a hover until you reopen it.

---

## Highlight groups

Defined on demand with `default = true`, so a colorscheme still wins.

| Group | Links to | Used for |
| --- | --- | --- |
| `HoverMissing` | `DiagnosticError` | the "this target does not exist" marker |
| `HoverError` | `DiagnosticError` | an HTTP 4xx/5xx, or an unreachable host |
| `HoverInfo` | `DiagnosticHint` | the "no text in this file" badge |

---

## Global variables

| Variable | Effect |
| --- | --- |
| `vim.g.hover_disable` | `true` forces `mode = "off"`, outranking anything a plugin configured |
| `vim.g.loaded_hover` | Set by `plugin/hover.lua`; set it yourself to suppress `:Hover` entirely |

`vim.g.hover_disable` is where a user says "not on this machine" from a plugin
spec's `init`, before anything loads. `hover.set_mode()` keeps it in step, so
the runtime switch and the spec setting are one setting rather than two that
can disagree.
