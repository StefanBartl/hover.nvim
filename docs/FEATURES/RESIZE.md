# Resizing the hover

Why the float can be made bigger, why that is called **resize** and not zoom,
and why one key pair is bound for pictures while the other two ways in work
everywhere. For *how* to use it, see
[BINDINGS.md](../BINDINGS.md) and [commands.md](../commands.md); this page is the reasoning
underneath.

## One operation, two honest answers

A step multiplies the box the previewer is given — `max_width` and `max_lines`
— by 1.25. That is the whole mechanism. Everything downstream happens exactly
where it happened before: the letterboxing, the inset images.nvim keeps free on
every side, the clamp against the terminal.

A picture answers that by being drawn larger. Text answers it by showing **more
lines**, because the font size belongs to the terminal emulator and Neovim
cannot change it. Both are the natural answer to "give this float more room",
and only one of them is magnification.

## The rename, and why it made the code smaller

The feature shipped as `zoom`, bound only over pictures, because for a picture
the two words coincide: ask for a bigger box and the picture gets bigger.

They come apart everywhere else, and the implementation had already said so
without anyone noticing. `opts.zoom` was read at exactly **one** place —
`canvas_cells` in `preview/media.lua` — where it multiplied `max_width` and
`max_lines` for that one preview. There was never a crop, never a viewport,
never a framing that changed: the whole picture was letterboxed into a larger
area, every time. Even the configuration fields had said it from the first day.
They were `larger` / `smaller`, never `in` / `out`.

So the rename was not a matter of taste, and it did not cost anything — it
*removed* something:

- the `zoom` field is gone from `Hover.PreviewOpts`;
- `hover.resize` scales `preview_opts.max_lines` / `max_width` instead;
- one special case leaves the media previewer, and text works with no second
  path at all.

**Neither name is an alias for the other, and that is the part worth stating
once.** `zoom_keys` was briefly the old spelling of `resize_keys`, and it is
not any more: it configures the real zoom, and a configuration still written in
the old shape (`zoom_keys.larger` / `.smaller`) is reported on startup and
ignored rather than quietly rebound. `hover.zoom(delta)` is likewise its own
function and not a deprecated pointer at `hover.resize(delta)`. An alias for a
renamed operation is exactly what produced the collision this repository paid
for.

**A real zoom is a different mechanism**, not a larger version of this one:
same box, more of the picture cut away, and keys to move the cut around. It
needs a cropped temporary file per step, navigation keys, and a centre to zoom
about. **It is built** — `:Hover zoom`, `h`/`j`/`k`/`l` to move the view, and a
step that costs 258 ms rather than nothing. The PDF half is built too, and is a
re-render at a higher DPI rather than a crop, because cropping a rasterization
gives you bigger and not sharper. Both are in [ZOOM.md](ZOOM.md).

## The keys split by what they cost

There are three ways in, and they are not bound alike.

| Way in | Bound for | Why |
| --- | --- | --- |
| `+` / `-` | a hover with a **picture** only | real motions in normal mode |
| `<M-ScrollWheelUp>` / `<M-ScrollWheelDown>` | **any** hover, where the pointer is | a spare chord costs nobody anything |
| `:Hover resize [bigger\|smaller]` | any hover, no key at all | discoverable through completion |

**`+` and `-` are motions, and that decided their scope.** Displacing a motion
is worth it over a picture, where the feature is the point of having the float
open at all. Over every text float that happens to be up it is not — and text
floats are most of them. The other two ways in have no such price, so they
carry the feature everywhere, and `:Hover resize` is the keyboard route for a
text hover.

**Their borrow condition is `content.canvas`, and it had to be its own.**
`keys.borrow` had exactly one condition before this, `content.scroll`, which an
image deliberately does not declare — scrolling a picture is meaningless.
Hanging the new pair off the existing condition would have bound it for every
case *except* the one it was built for. `canvas` is what a drawn hover has and
a text one does not.

**The wheel replaces the content condition with a position one.** A wheel
*points*, so `<M-ScrollWheelUp>` acts on what it is aimed at: the step happens
only while the pointer is over the float. Pointing elsewhere does nothing,
which is the honest answer rather than a missing one — the chord means nothing
else while a float is up.

Two measurements shaped that gate, both against a real Neovim:

- **`getmousepos()` cannot answer the question.** For a `focusable = false`
  float its `winid` reports the window *underneath* — 1000 for a float that is
  1001 — so `float.contains` computes the rectangle itself and uses only the
  screen coordinates.
- **The border ring counts as inside, on purpose.** The float is anchored one
  row below the cursor, so its top border sits on the cursor's own row — and
  under `trigger = { "mouse" }`, where the pointer *is* the cursor, that is
  exactly where the pointer already is. Excluding the ring would mean the wheel
  never fired in the workflow that puts a pointer over a float to begin with.

Alt rather than Ctrl, because `<C-ScrollWheel>` is the terminal emulator's own
zoom nearly everywhere. The wheel also needs `'mouse'` to include the mode:
with it empty no wheel event reaches Neovim at all and the mapping is inert
rather than broken, which looks identical from the outside — so
`:checkhealth hover` reports it.

One key per direction rather than two. The scroll pairs are doubled because a
key that is not on the keyboard cannot be pressed; `+` and `-` are on every
keyboard, so that argument does not carry. `=` was considered as the unshifted
`+` of a US layout and left alone: it is the indent operator, and borrowing an
operator buys convenience nobody asked for.

## The ceiling is the terminal, and it is found rather than declared

Measured before any of this was written — a 1200×675 image, defaults `80×20`:

| Terminal | Steps available | Picture goes from | to |
| --- | --- | --- | --- |
| 210×55 | five | 71×20 cells | 181×51 |
| 80×24 | **none** | 71×20 | 71×20 — 20 rows is already `lines - 4` |

Any fixed limit would be wrong on one of those two. So there is none: a step
that produces the same float is **stepped back off**, the same way `scroll`
steps back off the end of a PDF, and the level then stops exactly where the
screen does. Holding a key cannot run it off somewhere it has to be pressed
back from.

The comparison is against the float's *clamped* size (`float.size_for`), not
against the content. A clamp is invisible in the content: twenty lines shown
where twenty-five were asked for is a refusal, and a step that missed it would
let a held key run the level away after all.

## What no spec can say

A PDF page is not re-rasterized, so making one bigger costs nothing and is
correspondingly unsharp.

Two things about this feature are only checkable by hand, and both belong in
whatever notes you keep about *your* machine. The geometry is pinned all the way
to `nvim_win_get_config`, but a cell area is only a *request* to the terminal —
whether the drawing followed it is visible and nothing else. And mouse input
cannot be driven headlessly at all: measured, `nvim_input_mouse` fired **zero**
mappings with no UI attached, while `feedkeys` with the same termcode fired
one. So the mapping and the pointer gate are specs; the wheel arriving from a
real terminal is not.
