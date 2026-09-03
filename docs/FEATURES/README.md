# hover.nvim features

hover.nvim draws one float and knows almost nothing. What it does know is
mostly a set of decisions about **when to stay quiet**, and that is where the
interesting part sits: nearly every one of those decisions was made against a
measurement that contradicted the intuition it was meant to confirm.

These pages carry that half. [The README](../../README.md) says what the plugin
does and [BINDINGS.md](../BINDINGS.md) says which key does it. Here is **why
each feature has the shape it has** — the numbers, the alternatives that were
rejected, and the bugs that changed the design.

- **[QUIET.md](QUIET.md)** — why so little is on by default: the noise
  diagnosis this started from, the two axes the opt-in model is built on, the
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
- **[ZOOM.md](ZOOM.md)** — the other operation: same box, a narrower view. Why
  a quarter of a second made it a route before it was a key, why a picture is
  cropped and a PDF page re-rendered at a higher DPI instead, why the panning
  keys have the narrowest borrow condition here and the best case for it — and
  the name collision that survived a green suite.
- **[INTEGRATIONS.md](../INTEGRATIONS.md)** (one level up) — who is wired to
  whom, through which door, and what degrades when a plugin is absent.

Two neighbours are deliberately not in this directory.
[ROADMAP.md](../ROADMAP.md) is what is *not* built and what would have to be
settled first; [MANUAL-EVIDENCE.md](../MANUAL-EVIDENCE.md) is what no CI can
check and has to be seen by a person.

## The house rule these pages exist to record

**Measure before building.** Three measurements in this repository
contradicted the intuition they were testing, and twice the obvious fix was the
wrong one. The numbers therefore live in the module headers of `hover.scope`
and `hover.bare_path` rather than in commit messages — so that they are read
when the code is changed, not when the history is browsed.
