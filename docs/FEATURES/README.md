# hover.nvim features

hover.nvim draws one float and knows almost nothing. What it does know is
mostly a set of decisions about **when to stay quiet**, and that is where the
interesting part sits: nearly every one of those decisions was made against a
measurement that contradicted the intuition it was meant to confirm.

These pages carry that half. [The README](../../README.md) says what the plugin
does, [commands.md](../commands.md) and [configuration.md](../configuration.md)
say what to type and what to set, and [BINDINGS.md](../BINDINGS.md) says which
key does it. Here is **why each feature has the shape it has** — the numbers,
the alternatives that were rejected, and the bugs that changed the design.
[docs/README.md](../README.md) indexes all of it.

- **[QUIET.md](QUIET.md)** — why so little is on by default: the noise
  diagnosis this started from, the two axes the opt-in model was built on and
  the third one added when they could not express `auto_hover` at all, the
  three modes and what outranks what, and why every switch is derived from one
  table rather than listed.
- **[BARE-PATHS.md](BARE-PATHS.md)** — the one preview class whose value turns
  *negative* when it is wrong: how a path with no link syntax around it is
  recognised, where it is looked for, and the three measurements that shaped
  both.
- **[CONTRIBUTIONS.md](CONTRIBUTIONS.md)** — the registry: what another plugin
  or your own config can add, what `on_request` is for, and the bug that only a
  live wiring could find.
- **[RESIZE.md](RESIZE.md)** — one operation with two honest answers, why it is
  called resize rather than zoom, why `+` and `-` are bound over a picture but
  the wheel is bound everywhere, and why the ceiling is found by stepping into
  it rather than carried as a number.
- **[WEBPDF.md](WEBPDF.md)** — a link that answers with a PDF, shown as its
  first page: the `text = true` in the fetch that quietly corrupts any binary
  body and forced a second request, why that second request is what makes the
  size cap answerable at all, and the one field that made paging and zooming
  work with no code of their own.
- **[SHOT.md](SHOT.md)** — a hovered link shown as a picture of the page: why
  that is a different *category* from fetching rather than a louder setting of
  it, why it is the one feature here whose trigger gets a switch of its own, the
  profile without which a render would go out as the reader, and the fit-factor
  arithmetic that decides how tall a capture may be.
- **[ZEN.md](ZEN.md)** — the third way to make a hover bigger, and the one that
  is not a bigger window: why the previewer's *budget* becomes the screen
  rather than the float merely opening larger, the measurement that made it a
  prerequisite rather than a nicety, why it pins by default and why that
  follows from `focusable = false`, and why `z` is the one key it could not
  have.
- **[ZOOM.md](ZOOM.md)** — the other operation: same box, a narrower view. Why
  a quarter of a second made it a route before it was a key, why a picture is
  cropped and a PDF page re-rendered at a higher DPI instead, why the panning
  keys have the narrowest borrow condition here and the best case for it, how
  a measurement took the Alt chords away again — and the name collision that
  survived a green suite.
- **[integrations.md](../integrations.md)** (one level up) — who is wired to
  whom, through which door, and what degrades when a plugin is absent.

One neighbour is deliberately **not in this repository at all**: the record of
what a person actually saw, on which machine, and when. These pages say why a
decision was made; that record says whether the result was ever looked at — and
since it is one reader's account of one set of machines rather than
documentation of the plugin, it belongs in their own notes. What no CI can
reach is named in each page here instead, next to the decision it belongs to.

## The house rule these pages exist to record

**Measure before building.** Three measurements in this repository
contradicted the intuition they were testing, and twice the obvious fix was the
wrong one. The numbers therefore live in the module headers of `hover.scope`
and `hover.bare_path` rather than in commit messages — so that they are read
when the code is changed, not when the history is browsed.
