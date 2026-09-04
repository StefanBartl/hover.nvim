# Zooming a picture, or a page

Not [resize](RESIZE.md), and the difference is the whole feature.

**Resize changes the box.** The whole picture is letterboxed into it, the
framing never changes, and it costs no process at all — the drawing provider
is simply handed a larger rectangle.

**Zoom keeps the box and narrows the view.** What is on screen is a *smaller
part* of the source, larger. That cannot be done by asking for a bigger
rectangle; it needs a new file, which means a process, which is why almost
every decision on this page is about what that process costs.

**Two sources, two mechanisms, one gesture.** A picture is *cropped*: the file
the target names already holds every pixel there will ever be. A PDF page is
*re-rasterized at a higher DPI*, because what is on screen for a page is not
the file the target names — it is a rendering in this plugin's cache, and
cutting a piece out of that is bigger and no sharper. Both answer `>`, both
move with `h/j/k/l`, and neither knows about the other.

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

1. **No key you hold down, and for a while no key at all.**
   `:Hover zoom [in|out|reset]` was the only way in, because the keys on the
   table then were `+` and `-` — real motions, and displacing a motion for an
   operation this slow is a bad trade. **The keys exist now, and what changed
   was never the reasoning — only which key is cheap.** The objection was never
   "zooming is not worth a key", it was "not worth *that* key". See
   [Which keys, and the assumption that cost two of them](#which-keys-and-the-assumption-that-cost-two-of-them).
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

## Which keys, and the assumption that cost two of them

The answer was `<M-z>`, `<M-Z>` and `<M-R>` from the day the keys were built
until 2026-09-03, on one line of reasoning: **an Alt chord displaces nothing.**
That is true, and it is worth exactly what the terminal's willingness to send
the chord is worth — which nobody had measured.

Measured on the development machine, it sends none. `:nnoremap <M-z> <Cmd>echo
"…"<CR>` prints on no press; what arrives is `<Esc>` followed by `z`, and `z`
is a which-key prefix, so the visible symptom is a fold menu opening over a
picture. **A key that displaces nothing and does nothing is not a cheap key, it
is an absent one.** The chords remain the right default in a terminal that
sends them, and a `zoom_keys` table puts them back.

The three plain characters that replaced them do not rest on one argument:

| Key | Why it is affordable |
| --- | --- |
| `>` in | an **operator**: over a float it moves no cursor and completes nothing on its own, so the borrow costs a reader nothing for exactly as long as the float lasts |
| `=` reset | the same, and already the shape of "back to normal" |
| `\|` out | a **motion** — and that is the argument *for* borrowing it. Unbound, it jumps the cursor to column one, the dismissal hangs on `CursorMoved`, and so the press takes the picture away. The same case [`nav_keys`](#navigating-the-narrowest-borrow-in-the-plugin-and-the-strongest-case) makes for `h` |

**Two rejections, and neither is about taste.**

- **`<`** was the first pick for `out` and is unusable with which-key
  installed: `Util.norm` turns it into `<lt>` (measured 2026-09-03) while the
  mapping itself stays `<`, and pressing it re-enters which-key until its own
  guard reports "Recursion detected". `|`, `_`, `>` and `=` all normalize to
  themselves.
- **`-`** is the obvious partner for a `_` and cannot work at all.
  `resize_keys.smaller` holds it, `hover.bindings.keymaps.borrow` takes the
  resize keys **before** the zoom keys, and a key listed twice is taken once.
  The two conditions do not merely overlap sometimes: every hover a zoom key
  is bound for has a picture in it, so `-` would resize and never zoom, on
  every press. `:checkhealth hover` reports the clash rather than leaving it to
  be found as a picture that grows instead of a detail that sharpens.

## A PDF page: sharper, not merely larger

A page was refused for a while, and the reason was never laziness. **What is on
screen for a PDF is not the file the target names** — it is a rasterization
living in this plugin's own cache, rendered once at one DPI. Cropping *that*
magnifies a bitmap already as detailed as it will ever be: bigger, no sharper,
which is the one thing a zoom is for.

The honest answer is a second render at a higher DPI, and it was parked here
with a price on it: **3.3 s a step**, against 258 ms for a crop. That number
is why this sat on the roadmap as a decision rather than a ticket.

**The number was for the wrong operation, and measuring the right one settled
it.** 3.3 s is what re-rendering a *whole page* costs, and a whole page is not
what a zoom shows. Windows, 2026-09-03, dense A4 text page:

| Level | DPI | Whole page | The window actually shown |
| --- | --- | --- | --- |
| 0 | 216 | 176 ms | — |
| 1 | 324 | 304 ms | 140 ms |
| 2 | 486 | 606 ms | 118 ms |
| 3 | 729 | 1 231 ms | 119 ms |
| 4 | 1 094 | 2 653 ms | 119 ms |

The left column grows with the square of the DPI. The right one does not move,
and the reason is arithmetic rather than luck: **the view narrows by exactly
the factor the resolution rises by**, so the window is always about the size of
the plain page in pixels. The same number of pixels comes back every time; only
what they were sampled from changes.

So a page step costs what a picture step costs — measured through the plugin
itself, 207–752 ms at every level on a dense page — and it goes through the
same placeholder machinery for the same reason.

**The sharpness is measured, not asserted.** Same window, same pixel size, one
re-rendered at the higher DPI and one cropped out of the level-0 render and
scaled up (which is what the picture path would have done to a page):

| Level | re-rendered | upscaled crop |
| --- | --- | --- |
| 1 | 0.81 | 0.37 |
| 2 | 0.88 | 0.23 |
| 3 | 0.66 | 0.10 |
| 4 | 0.22 | 0.03 |
| 5 | 0.16 | 0.01 |

Standard deviation of a Laplacian — detail per pixel, as one number. Read the
rows across, never down: *within* a row the re-render carries 2× to 15× the
edge energy, which is the feature. *Down* a column both fall, because a view
narrow enough to hold two letterforms is mostly white however it was made.
`scripts/pdfzoom_probe.lua` prints this table for any PDF.

**The ceiling is a DPI, and that is a different kind of limit.** A picture runs
out of pixels and the source can be asked where that is. A vector page never
runs out, so the limit has to be *chosen*: 2400 DPI, about 11× the base and
five steps. Past that a scanned page has long been showing interpolation rather
than paper, and a vector one is showing the inside of single letterforms. Not a
cost limit — the cost is flat — which is why it is a number rather than a
measurement.

**Every view is kept for the session**, keyed by file, mtime, page, DPI *and*
window. Without the last two the sharp view and the plain one overwrite each
other, which the roadmap named as the obstacle before this was built. How many are worth keeping answers itself: the ceiling bounds the levels,
a few hundred KB each, and they go at `VimLeavePre` with everything else.

**pdftoppm does the cutting, not ImageMagick.** `pdfport.render_page` grew an
`opts.crop` for this (pdfport.nvim `95d27ab`), the same way `images.convert.crop`
grew for the picture half — a window of a page is a rasterizer's job, and doing
it here would mean rendering the whole page first, which is the cost this
feature exists to avoid. A pdfport too old to know the option is detected
(`can_render_page_crop`) rather than discovered: it would ignore an unknown
field in silence, and the page would come back rendered at a higher DPI and
letterboxed into the same float — a key that visibly does nothing.

## Navigating: the narrowest borrow in the plugin, and the strongest case

While a hover is zoomed in, `h` `j` `k` `l` move the magnified view. Every
other borrowed key in this plugin is bound on a *content* condition — is there
something to scroll, is there a canvas. These are bound on a **state**: only
while the hover is actually magnified, and handed straight back the moment it
is not.

That is narrower than anything else here — narrower even than the zoom keys
above, which are bound whenever the picture *can* be zoomed — and it has the
best argument of any of them. `+` and `-` are motions, and displacing a motion costs the reader
something. `h` and `l` are motions too — but what they would otherwise do,
*with a magnified picture on screen*, is **destroy the float**: the dismissal
hangs on `CursorMoved`, so pressing `h` to look further left moves the cursor
and takes the picture away instead. Nobody has ever meant that.

`:Hover nav {left|right|up|down}` is the same thing without a borrow, and it
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
checked by hand, because a terminal is the only thing that can answer it.

**The crop itself is covered now, and was not for a while.** That check
reported *pending* everywhere, which read as "no ImageMagick here" and was
nothing of the sort. Two bootstrap defects, both fixed on 2026-09-02:

- `scripts/minimal_init.lua` built its images.nvim candidate list as a literal
  whose first entry was an unset environment variable. A `nil` at index 1 is a
  hole, `ipairs` stops there, and the loop ran **zero** times — so the `.deps/`
  and sibling fallbacks were never tried, and only someone with
  `IMAGES_NVIM_DIR` exported ever had images.nvim in a spec.
- `scripts/test.sh` ran a single file through `PlenaryBustedFile`, which
  reaches a runner that spawns its child with no options at all — no `-u`, and
  therefore not this repository's bootstrap. A directory run and a single-file
  run of the same spec were two different environments.

The fixture was the third layer: `fake_png` writes a PNG *header* and no pixels,
which is right for `pixel_size` and impossible to crop. The crop test now builds
a real picture with the ImageMagick its own guard has already confirmed.

**The lesson is about the word *pending*.** All three defects were invisible
because the spec announced a reason for skipping that sounded plausible. A skip
with a good explanation is the easiest kind of missing coverage to keep.

Which is why the runner now counts them. Measured on 2026-09-03, because the
summary is worse than it looks and in two different ways:

| Shape | Printed | Counted |
| --- | --- | --- |
| `pending("…")` at describe level | `Pending \|\| …` | in nothing — the Success total merely gets *smaller* |
| `pending("…")` inside an `it` | `Pending \|\| …` | **as a Success** |

The second is the shape a guarded spec has, and it is the one that hid here:
`zoom_spec` has 24 `it` blocks and reported "Success: 24" while one of them
asserted nothing. Neither shape touches the exit code, so no amount of reading
the totals would have caught it.

`scripts/test.sh` now names every pending spec after the run and fails unless
`HOVER_ALLOW_PENDING=1` is set. CI sets it, because the crop check is
legitimately pending on a runner with no ImageMagick — but the names are
printed there too, so a *new* one is visible where it cannot be fatal.

**The most likely reason to see it locally is a worktree.** `minimal_init`
finds images.nvim through `IMAGES_NVIM_DIR`, a `.deps/` checkout, or the
sibling directory — and from `.claude/worktrees/<name>/` the sibling is the
worktree pool, not `E:/repos`. Set `IMAGES_NVIM_DIR` there.
