# Zen: the float on the whole editor

Why there is a third way to make a hover bigger next to
[resize](RESIZE.md) and [zoom](ZOOM.md), why it is not simply "resize, held
down", why it pins by default, and why it was built before the feature that
needs it. For *how* to use it, see [BINDINGS.md](../BINDINGS.md) and
[commands.md](../commands.md); this page is the reasoning underneath.

## Zen is not a bigger window

Every previewer in this plugin renders against a **budget**. `max_lines` and
`max_width` are not a description of the float that comes out — they are the
input: how many lines are read from the file, at what DPI a PDF page is
rasterized, how large a picture is drawn before the terminal is asked to place
it.

A float that merely opened larger would therefore show the same twenty lines,
the same small picture, with a great deal of margin around them. So zen
replaces the *base* of that budget with the editor's own size and builds the
preview again against it:

| | base | multiplied by |
| --- | --- | --- |
| ordinary | `max_width` × `max_lines`, as configured | `1.25 ^ resize` |
| zen | `columns - 4` × `lines - 4` | `1.25 ^ resize` |

Which is [resize](RESIZE.md)'s machinery with a destination where it has a
factor. Both live in one function (`box` in `hover/init.lua`), and that is not
tidiness: `present` tells the float how large it may be, `current_preview_opts`
tells the previewer how large an answer to build, and the two deriving that
number separately is a bug this repository has already shipped once — a
scrolled hover snapping back to the configured size because `scroll` did not
know about the resize level.

## What that gets you, per preview type

The same pair of honest answers resize gives, because it is the same
mechanism:

- **a picture, a PDF page, an office page** — drawn larger, at the size the
  screen actually has;
- **a text preview** — *more lines*. Twenty becomes roughly fifty on an
  ordinary terminal, which is most of a screenful of the file being pointed at.
  The font size belongs to the terminal emulator and Neovim cannot change it.

`+` and `-` keep working inside zen and need no code of their own: the ceiling
`float.size_for` clamps against is the same `columns - 4` / `lines - 4`
expression, so a `+` in zen produces an identical float, `resize` sees that the
size did not change and steps the level back off — exactly the way it finds the
terminal's ceiling anywhere else. `-` shrinks from full screen without leaving
zen. Zen ends when you say so, not when you step out of it.

## Why it was built first

Because the screenshot preview it was built for is unusable without it.
Measured 2026-09-04:

| | |
| --- | --- |
| a page screenshot | 1280 × 900 px |
| a default float, 80 × 20 cells | roughly 640 × 340 px |
| fit factor | height-limited at **~0.38** |
| 16 px body text becomes | **~6 px** |

Unreadable — a feature that has to be zoomed into shape after every open. The
same problem exists in weaker form for every picture, every PDF page and every
converted office document, which is why zen applies to all of them rather than
to web pages.

## Why it is centred

This is the one place in the plugin where a hover is deliberately **not** next
to what it describes. Everything about cursor-relative positioning is an
argument about a small float annotating the line underneath it. A float filling
the screen annotates no particular line, and anchoring it at the cursor would
only decide which edge it gets cut off at.

The float is `relative = "editor"` either way — see the note in `hover.float`
about why the cursor position is resolved through `screenpos()` rather than
handed to Neovim as `relative = "cursor"` — so centring is arithmetic on
numbers that are already in the right coordinate system.

## Why it pins, and why that is configurable

The float is `focusable = false`: it never receives a keystroke, which is what
lets it annotate the buffer instead of interrupting it. The dismissal
correspondingly hangs on `CursorMoved`. Together those mean **every key that is
not borrowed takes the float away** — correct for a twenty-line annotation, and
absurd for one filling the screen, which would close on the first `j`.

So `zen.pin` is `true` by default, and that default follows from the mechanism
rather than from taste. Two details make the coupling behave:

- **Leaving zen releases only a pin zen itself took.** A float pinned by hand
  before going full screen stays pinned after coming back, and `:Hover pin`
  pressed while in zen hands ownership of the pin back to the reader.
- **The pin marker survives a re-render.** `📌` is a prefix on the border
  title, which lives on the window — and `float.open` closes and reopens the
  window on every re-render. A pinned float being resized has silently lost its
  marker since pinning existed; it was survivable while pinning was a rare
  deliberate gesture, and zen made it the ordinary case.

`zen.pin = false` gives the transient reading back: zen opens, the next move
closes it, and `:Hover pin` is still one command away.

## Why not "resize, until it stops"

`resize` already steps up to the terminal's edge, so zen could have been "press
`+` five times" and no new concept at all. Two things decided against it:

- **The step count is a property of the terminal, not of the gesture.**
  Measured 2026-09-02: a 210×55 terminal has room for five steps, an 80×24 one
  for none at all — 20 rows is already `lines - 4`. "Full screen" is one press
  on both; "press `+` until it stops" is five presses on one and a no-op on the
  other.
- **Coming back has to be one press too.** A resize level walked up five steps
  has to be walked down five, and any of them may have been refused. Zen is a
  flag, so leaving it is exact.

## Why `F`

An Alt chord was not a candidate: on the machine this is developed on the
terminal sends none, and a key that displaces nothing *and does nothing* is
absent rather than cheap ([MANUAL-EVIDENCE.md](../MANUAL-EVIDENCE.md)).

Among plain characters the rule is the one `>` and `=` were chosen on: what
does the key cost for as long as the float is up. `F` is
find-character-backwards — pressed on its own it waits for a second character
and completes nothing, so no finished operation is displaced.

`z` was the obvious mnemonic and cannot be taken. It is a **prefix**: borrowing
it would swallow `zz`, `zt`, `zb` and every fold command, and a broken prefix
does not announce itself the way a displaced key does. It hangs, waiting for a
second character that now means something else.

The borrow is the widest in the plugin — every hover with a target, where
`resize_keys.larger` is narrowed to a drawn one. That is the same argument from
the opposite end: `+` is a real motion and displacing it over every text float
is not worth it, `F` costs nothing, and a text hover is exactly where the extra
room buys the most.

A *position* hover is the one case the key is withheld from, because zen can
only decline there: a position preview carries no target to ask again, only the
content one plugin produced for this place once — the same reason `resize`
declines. A key bound to a refusal is worse than an unbound one; `:Hover zen`
still says why.
