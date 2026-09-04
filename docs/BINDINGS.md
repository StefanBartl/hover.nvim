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
| `open_keys` | `gf` | hovers with a target | open what the float is showing, then close it |
| `scroll_keys.down` | `<M-PageDown>`, `<C-Down>` | scrollable hovers only | next screenful of lines, or next PDF page |
| `scroll_keys.up` | `<M-PageUp>`, `<C-Up>` | scrollable hovers only | back |
| `resize_keys.larger` | `+` | hovers with a picture only | the float one step (×1.25) larger |
| `resize_keys.smaller` | `-` | hovers with a picture only | one step smaller |
| `resize_keys.wheel_larger` | `<M-ScrollWheelUp>` | **any** hover, and only while the pointer is over the float | one step larger |
| `resize_keys.wheel_smaller` | `<M-ScrollWheelDown>` | as above | one step smaller |
| `zoom_keys.into` | `>` | hovers whose picture or PDF page **can** be zoomed | magnify a detail one step |
| `zoom_keys.out` | `\|` | as above | step back out |
| `zoom_keys.reset` | `=` | as above | back to the whole picture or page |
| `position_keys.next` | `<M-n>` | **position hovers only**, and only where more than one contribution is registered | the next plugin with something to say about this place; wraps |
| `nav_keys.left` | `h` | **only while zoomed in** | move the magnified view left |
| `nav_keys.right` | `l` | as above | right |
| `nav_keys.up` | `k` | as above | up |
| `nav_keys.down` | `j` | as above | down |

What follows from "borrowed" is below, and each of these has been a bug at some
point. No count in that sentence on purpose: the list has grown with every new
pair of keys, and a number in front of it would be one more hand-kept copy to
fall behind.

- **A key already mapped is restored, not deleted.** `maparg(..., true)`
  captures it before the mapping is set; `mapset` puts it back after.
- **`dismiss_keys` dismiss rather than close, and the difference is not
  cosmetic.** Under the `CursorHold` trigger the event fires again after any
  keystroke followed by `'updatetime'` of quiet — cursor movement or not — so
  a key bound to `hide()` makes the float vanish and then brings it straight
  back, while the reader is still standing where they wanted it gone. The
  dismissal instead holds for as long as the cursor stays on that target, and
  the next target it resolves — another one, or none at all — clears it.
  Unlike the scroll keys they are bound for **every** hover, because anything
  can be waved away, including a picture, which has nothing to scroll.
- **Both scroll pairs are bound, because a key that is not on the keyboard
  cannot be pressed.** Laptop and 60% layouts often reach PageUp/PageDown only
  through an Fn chord, and nothing at runtime can tell whether *this* keyboard
  has them; the arrows are on every keyboard there is. Ctrl rather than Alt on
  them, because `<M-Up>`/`<M-Down>` is a widespread "move this line" binding.
- **The same key listed twice is taken once.** A key that is both a dismiss
  key and a scroll key would otherwise be "restored" to one of our own
  mappings and outlive the float forever. Dismiss wins: the binding that
  always applies beats the one that only sometimes does.
- **Scroll keys are not bound when there is nothing to scroll.** An image, or
  a file that already fits in the float, leaves them alone entirely and they
  keep whatever they mean elsewhere.
- **`+` and `-` hang off a different condition, and had to.** The one above
  is `content.scroll`, which an image deliberately does not declare — so they
  read `content.canvas` instead: what a drawn hover has and a text one does
  not. Hanging them off the existing condition would have bound them for
  every case except the one they were built for.
- **Navigating has the narrowest condition of all, and the strongest case.**
  `nav_keys` are bound only while the hover is *zoomed in* — not merely drawn.
  They are motions, like `+` and `-`, but with one difference that settles it:
  what `h` would otherwise do over a float is move the cursor, and the
  dismissal hangs on `CursorMoved`, so the unbound key takes the picture away.
  Nobody presses `h` at a magnified picture meaning that.
- **The zoom keys were Alt chords until 2026-09-03, and a measurement took
  that away.** There were deliberately no zoom keys at first: a step costs a
  quarter of a second or so — ~258 ms to crop a picture, 120–600 ms to
  re-render a window of a PDF page — which is the wrong shape for a key you
  hold, and the only candidates then on the table were `+` and `-` — real
  motions, already `resize_keys`. `<M-z>`, `<M-Z>` and `<M-R>` displaced
  nothing, and that is worth what the terminal's willingness to send them is
  worth: on the machine this is developed on, `:nnoremap <M-z> <Cmd>echo
  "…"<CR>` prints on no press. A key that displaces nothing *and does
  nothing* is absent, not cheap. Set `zoom_keys` back to the chords wherever
  they do arrive.
- **`>`, `|` and `=` replaced them, on two arguments rather than one.** `>`
  and `=` are *operators*: over a float they move no cursor and complete
  nothing, so the borrow is free for exactly as long as the float. `|` is a
  *motion*, and that is the case for taking it — unbound it jumps to column
  one, the dismissal hangs on `CursorMoved`, and the press takes the picture
  away, which is the same argument `h` makes below. `<` was rejected because
  which-key normalizes it to `<lt>` while the mapping stays `<`, and the
  disagreement re-enters which-key until its guard reports “Recursion
  detected”. `-` was rejected because `resize_keys.smaller` holds it: resize
  is bound first, a key listed twice is taken once, and every hover a zoom key
  is bound for has a picture — so it would resize and never zoom.
  `:checkhealth hover` reports that overlap.
- **They are bound whenever the picture or page *can* be zoomed** rather than
  only while it is: `out` and `reset` decline at level 0 anyway, and a pair
  that appears only after a successful press would be worse than one that is
  simply there.
- **The wheel is bound for every hover, and gated on the pointer instead.**
  `+` is a motion in normal mode, and displacing a motion for every text
  float costs more than the feature is worth there; `<M-ScrollWheel>` costs
  nobody anything. What replaces the content condition is a position one: the
  step happens only while the pointer is over the float, border ring
  included. `:Hover resize` is the third way in and takes no key at all.

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

One compound verb, `:Hover`, `<Tab>`-completed at every level. The state
argument may be omitted, which toggles. **[commands.md](commands.md) is the
reference** — what each route does, what it takes, and what happens when it is
left out. The list itself, so this cheatsheet is one:

| Group | Routes |
| --- | --- |
| asking | `:Hover show` &middot; `:Hover why` &middot; `:Hover pin` &middot; `:Hover next` |
| the float on screen | `:Hover resize` &middot; `:Hover zoom` &middot; `:Hover nav` &middot; `:Hover border` |
| volume | `:Hover mode` &middot; `:Hover toggle` &middot; `:Hover auto` &middot; `:Hover status` |
| switches | `:Hover links` &middot; `:Hover links web` &middot; `:Hover links web fetch` &middot; `:Hover paths` &middot; `:Hover paths missing` &middot; `:Hover paths code` &middot; `:Hover positions` &middot; `:Hover images` &middot; `:Hover office` |

`:Hover` is registered from `plugin/hover.lua`, so it exists before `setup()`
runs and even in a session where nothing turned the hover on. That is the
point: `:Hover mode auto` has to be reachable from exactly the state where
someone is most likely to type it.

The routes are **generated** from `hover.switches`, not written out. Dispatch,
completion, the descriptions and `:Hover status` all read the same table, so
they cannot drift apart.

No keymap is offered for these, and none accepts a range. A setting thrown a
few times a week, from wherever you happen to be, does not need to be one
keystroke away; and every route acts on the cursor position or on a
session-wide switch, neither of which has a meaningful reading over a line
range.

---

## Autocmds

Four augroups. The first two are the trigger and are cleared and rebuilt on
every `enable()` — which is what makes `enable()` idempotent. The other two
belong to a float that is on screen, or to the session, and are created the
first time they are needed.

| Group | Event | Scope | Does |
| --- | --- | --- | --- |
| `HoverEnable` | `FileType` | pattern from `filetypes` (default `*`) | attach the hover to this buffer |
| `HoverBuf<n>` | `CursorHold` | one buffer | trigger, under the default trigger |
| `HoverBuf<n>` | `CursorMoved` | one buffer | trigger, under `trigger = { "cursor" }` or `{ "mouse" }` |
| `HoverBuf<n>` | `BufLeave`, `InsertEnter` | one buffer | `hide_unless_pinned()` — leaving the buffer and entering insert are exactly the moments something was pinned *for* |
| `HoverDismiss` | `CursorMoved`, `CursorMovedI`, `InsertEnter`, `BufLeave`, `WinScrolled` | global, `once` | close the float that is open. `CursorMoved` alone would not do: leaving insert or switching windows must clear it too, or a stale float outlives what it described |
| `HoverMedia` | `VimLeavePre` | global, once per session | delete the PNGs rasterized from PDF pages |

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
