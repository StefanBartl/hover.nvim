# Contributions

The hover framework must not know *who* can read a `#heading` out of a markdown
file, or who can turn a `.png` into pixels. Those are plugin capabilities, and
a library that requires plugins to do its job has the dependency backwards.

So plugins register *into* this one rather than this one reaching for plugins.
For the API and its shapes see
[the README](../../README.md#contributing-from-a-plugin) and
[INTEGRATIONS.md](../INTEGRATIONS.md); this page is why there are three kinds,
why one of them can decline to be asked, and the bug that only a live wiring
found.

## Three kinds, and why the third exists

- **`sources`** — "what is under the cursor?", returning a raw target string.
- **`previews`** — "how do I render a target of *this type*?"
- **`positions`** — "is there anything to say about this **place**?"

The first two answer about a *thing*. The third exists because some of the most
useful answers are not about a thing at all: that this line uses a deprecated
API, how often this token occurs in the buffer, what the module in this
`require` actually is. None of those is something the cursor points *at*, and
until the kind existed "no target" meant "no hover", full stop.

**Four plugins were waiting on the same missing piece** — migrate.nvim,
documentation.nvim, spotlight.nvim, sandbox.nvim — which is the strongest
evidence that the gap was real rather than theoretical.

Sources are ordered and previews are not, and that asymmetry is not an
oversight: several sources can match one cursor position (a markdown link and a
bare path both exist on `[a](./b.png)`), so "first match wins" needs an order,
and registration order is the only one a library can honestly offer. A preview
answers for exactly one type, so a second registration for that type is a
replacement rather than a competitor.

## When an answer is expensive

A `sources` or `positions` entry may be a table instead of a function:

```lua
positions = {
  { fn = function(bufnr, row, col) … end, on_request = true },
}
```

Such a contribution is asked **only for an explicit request** and never on the
automatic trigger. The flag exists because "how expensive is your answer" is
knowledge only the contributor has, and there was no way to state it — the only
lever before was `:Hover positions off`, which silences every registered plugin
at once rather than the expensive one.

It is a flag on the *entry* rather than a fourth contribution kind because it
applies to `sources` and `positions` identically. A `sources_on_request` list
would have needed a `positions_on_request` beside it, and the pair would then
have to be kept in step by hand — which is
[the bug class this repository keeps meeting](QUIET.md#one-declaration-and-every-copy-of-it-that-fell-behind).

**It also does not count as "something that could answer"** when the trigger
decides whether to install itself for a buffer at all. A buffer whose only
contribution is request-only gets no `CursorHold`: a trigger that wakes, asks
nobody and sleeps again is pure cost.

### Measured, against a live Docker engine

`scripts/onrequest_probe.lua` drives four references twice each — once on the
automatic trigger, once forced — and **reads the float back** rather than
trusting the return value. Measured 2026-09-02, Docker Engine 29.5.3, keypress
to finished float:

| Reference | Answer | Forced | Engine calls |
| --- | --- | --- | --- |
| `alpine:edge` | pulled, no container | 566 ms | 2 |
| `lazyvim_starter:latest` | pulled, 1 container | 558 ms | 2 |
| `nginx:1.27-alpine` | not pulled | 294 ms | 1 |
| `init.lua:42` | declined | 0 ms | 0 |

All four stayed silent on the automatic trigger. The last row is the one worth
keeping: an image reference and `path:line` are the same shape, and the
contributor rejects the collision **before** any process starts.

## The bug that only a live wiring found

`has_positions()` answers one question: "should this buffer get a `CursorHold`
at all?" — and a request-only contribution deliberately does not count.

`show_position` used the same function as a pre-guard, **ahead of** its own
`force` check. So a buffer whose only contribution was request-only declined on
both paths: correctly on the automatic one, and by accident on the explicit
one. The feature from `731bbe2` was **never reachable by any route**.

Two things about that are the lesson:

- **It was found only by wiring a real plugin.** The registry specs called
  `position_at` directly, below the guard. Only the path through `hover.show`
  crosses it, and only sandbox.nvim took that path. A feature with nothing but
  its own unit spec is not proven.
- **The fix must not sell the other question with it.** Buying reachability by
  installing the trigger anyway would have destroyed the reason `on_request`
  exists. One of the four new specs pins exactly that.

Fixed in `836a15a`, with a sabotage test: the old code drops two of the four
new cases.

## From a user's config, without a plugin

`setup` takes a `contribute` table which is *exactly* the table `register`
takes — same contract, one thing to learn. It registers under the name `user`,
so a second `setup` replaces rather than stacks, and it never reaches the
options table: functions are not configuration, and the merge that makes
`setup` idempotent would interleave two lists rather than replace one.

A *plugin* should keep using `register` with its own name. Every contribution
made through `contribute` shares the single name `user`, so two callers would
silently delete each other.

`:checkhealth hover` names who registered what, because "did mine arrive?" had
no answer before and is the first question anyone using this asks.
