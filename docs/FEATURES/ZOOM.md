# Zooming a picture

Not [resize](RESIZE.md), and the difference is the whole feature.

**Resize changes the box.** The whole picture is letterboxed into it, the
framing never changes, and it costs no process at all — the drawing provider
is simply handed a larger rectangle.

**Zoom keeps the box and cuts the source.** What is on screen is a *smaller
part* of the picture, larger. That cannot be done by asking for a bigger
rectangle; it needs a cropped file, which means a process, which is why almost
every decision on this page is about the 258 milliseconds that process costs.

---

## The measurement came first, and it decided the shape

Windows, 2026-09-02, against a real ImageMagick:

| What | Cost |
| --- | --- |
| a bare `magick` start | 71 ms |
| crop + fit a 1920×1080 screenshot | **258 ms** |
| the same size, dense image | 502 ms |
| a 4K source | ~900 ms |
| one rasterized PDF page, for comparison | 1150 ms |

No format or compression setting brought it under ~150 ms, and batching
several crops into one process saved only the start — the work is the work.

**So a zoom step is not a dial.** A quarter of a second is far too slow for a
key you hold down and watch respond, and fast enough that a deliberate press
feels answered. That single number produced three decisions:

1. **Zooming lives on a route, not a key pair.** `:Hover zoom [in|out|reset]`.
   `+` and `-` stay with resize, which costs nothing and *is* a dial.
   `hover.zoom(delta)` is public for anyone who disagrees and wants a key.
2. **It goes through the placeholder machinery** that PDF pages have used all
   along — `build_async`, a generation counter, and a provisional frame that
   waits out the grace period. Measured, a zoom beats the page it borrowed the
   machinery from: 258 ms against 1150 ms.
3. **The ceiling is capped rather than discovered.** This is the exact opposite
   of [resize](RESIZE.md), where only the terminal knows where the room ends
   and the only honest way to find it is to step into it. Here the limit is the
   source's own pixels, and arithmetic answers it — spending a 258 ms `magick`
   run to discover there was no more detail would be paying the full price for
   a refusal.

## Pictures only, and not PDF pages

A PDF page is a picture too, and zooming one is a reasonable thing to want.
It is refused, and the reason is not laziness:

**What is on screen for a PDF is not the file the target names.** It is a
rasterization living in this plugin's own cache. Cropping *that* would magnify
a bitmap that was already rendered at one fixed resolution — the result is
bigger and no sharper, which is the one thing a zoom is for.

The honest answer for a page is a **second render at a higher DPI**, and that
is a different feature with a different price: measured at 3.3 s against
258 ms. It stays on [ROADMAP.md](../ROADMAP.md) rather than being approximated
here.

## Panning: the narrowest borrow in the plugin, and the strongest case

While a hover is zoomed in, `h` `j` `k` `l` move the magnified view. Every
other borrowed key in this plugin is bound on a *content* condition — is there
something to scroll, is there a canvas. These are bound on a **state**: only
while the hover is actually magnified, and handed straight back the moment it
is not.

That is narrower than anything else here, and it has the best argument of any
of them. `+` and `-` are motions, and displacing a motion costs the reader
something. `h` and `l` are motions too — but what they would otherwise do,
*with a magnified picture on screen*, is **destroy the float**: the dismissal
hangs on `CursorMoved`, so pressing `h` to look further left moves the cursor
and takes the picture away instead. Nobody has ever meant that.

`:Hover pan {left|right|up|down}` is the same thing without a borrow, and it
exists because a borrowed key is undiscoverable until it has been seen once.

**A step is a quarter of the visible rectangle**, so four of them cross the
view exactly once: far enough to be worth a press at 258 ms, near enough that
nothing is skipped over.

**The centre is kept as a fraction of the source, not in pixels.** That is what
makes going deeper keep looking at the same place — a pixel centre would drift
as the visible rectangle shrinks. Stepping all the way back out
(`:Hover zoom reset`, or `out` to level 0) drops the centre as well: a centre
chosen inside a magnified view means nothing once the whole picture is on
screen again, and keeping it would make the *next* zoom start somewhere nobody
chose.

## The name collision the rename left behind

Worth recording, because it survived a green suite, green CI and a review.

`8ec5b40` renamed zoom to resize and kept `M.zoom` as a deprecated alias
"because it was public". `9fba190` then defined a real `M.zoom` — this
feature — seventy lines further down the same file. Lua takes the second
definition, so the alias was dead from the day the real zoom landed, and
`hover.zoom(delta)` silently stopped meaning *resize* and started meaning
something else: a different feature, with requirements the old one never had
(images.nvim plus ImageMagick) and a cost the old one never had.

Nothing failed. The suite was green, the vimdoc described the real zoom
correctly, and only the README still claimed the alias forwarded to `resize` —
two documents disagreeing, one of them true. **The LuaLS scan is what saw it**
(`duplicate-set-field`, twice), and that scan had not been run after the commit
that introduced it. Fixed in `bd72836`; the alias is gone rather than renamed,
because `zoom_keys` folding into `resize_keys` is the half of the rename anyone
actually configures.

The rule this reinforces is the one already in the handover: **a scan belongs
after every commit that adds code, not only after one that changes `lua/`.**

## What no spec can say

**That the magnified detail actually appears.** The arithmetic is covered
(`TESTS/zoom_spec.lua`), and outside the suite the crops have been confirmed to
be written and to shrink as calculated:

```
level 1 -> 800x533+200+133      level 2 -> 533x355+333+222
level 3 -> 355x237+422+281      centre 0,0 at level 2 -> 533x355+0+0
pan right/down/left -> a fresh 355x237 each time
reset -> the whole picture;  pan while not zoomed -> false
```

What nobody has seen yet is the result **in a terminal**, and whether `h/j/k/l`
feel right while panning is not a question a spec can be asked at all. Both are
tracked in [MANUAL-EVIDENCE.md](../MANUAL-EVIDENCE.md).

**And one gap that is a defect rather than a limit:** `scripts/minimal_init.lua`
does not get images.nvim onto the runtimepath *inside* a spec, though it does
when invoked directly. The one spec that would check the crop itself therefore
runs as *pending* rather than passing. See the handover.
