# Bare paths

A path written in prose, with no link syntax around it. This is the only
preview class whose value goes **negative** when it is wrong: a float that says
"this file does not exist" over the word `read/write/execute` is worse than no
float at all, because it is a confident wrong answer rather than silence.

Everything else here follows from that asymmetry. For the switches and their
defaults see [configuration.md](../configuration.md#the-nine-switches); this page is why the
rules are as strict as they are, and the three numbers that set them.

## Recognising one

The rule was tightened after the measurement in [QUIET.md](QUIET.md#what-the-complaint-actually-was):
an extension has to sit on the **last** component, and a leading `./` no longer
counts on its own.

That costs real true positives — `~/notes`, `/etc/hosts`, `lua/lib/nvim` when
they do not exist — and it is meant to. For every other class a miss costs a
float that would have been nice to have; here a false positive costs trust in
every float the plugin has ever drawn.

Two rules keep this from firing constantly. It must **look like a path** — a
separator, an extension, or a `...` truncation, *and* at least one alphanumeric
character somewhere: `helper` is a word, `helper.lua` is a path, `/` and `--%`
are punctuation out of a table. And a **missing** path is reported only when it
cannot have been anything else.

The same asymmetry decides what happens when nothing resolves: a missing target
is reported **only** when the text cannot have been anything but a path
(`is_unambiguous_path`). gopath declining and `<cfile>` declining is not
evidence that something was a path. What counts as evidence is deliberately
narrow, because this rule has been wrong twice in two different directions:

| Evidence | Example | But not |
| --- | --- | --- |
| a truncation | `...nvim/init.lua` | |
| a drive or UNC prefix | `C:\Users\x`, `\\server\share` | |
| an extension on the **last** component | `docs/gone.md`, `./src/app.ts` | `github.com/user/repo` |

None of this touches a target that **exists** — `docs/` and `and/or` both hover
normally the moment something of that name is on disk. The rules only decide
whether *absence* is worth asserting, and `:Hover paths missing off` turns the
class off entirely.

## Where one is looked for

Not everywhere in a source file. `paths.code = false` (the default) means bare
paths are searched in **comments and strings**, not inside expressions — a path
in a source file is written in a comment or a string and never in the middle of
an expression.

That matters because the remaining false positives are not textually different
from a path. `vim.api.nvim_buf_get_lines` has dots and components; `alpha /
beta` has a separator and two parts, exactly like `docs/BINDINGS.md`. No rule
about the characters can separate them, because there is nothing to separate —
only where they sit differs.

```lua
-- see ./docs/BINDINGS.md          hovers  (a comment)
local p = "./docs/BINDINGS.md"  -- hovers  (a string)
local x = vim.api.nvim_get_mode -- silent  (an expression)
local r = alpha / beta          -- silent  (an expression)
```

**The rule is the reverse of what was originally proposed**, and that reversal
is the whole point. "Only look inside comments and strings" presumes that prose
buffers have no parser to ask — but markdown, gitcommit and rst do have one, so
the naive version would have switched the feature off in exactly the buffers it
is most useful in. The question asked instead is whether the position is
*positively identifiable as code*, and everything else is allowed:

| At the cursor | Answer |
| --- | --- |
| no parser for this buffer — `.txt`, a log, a `:messages` dump | looked for |
| a parser, but nothing captured here — an ordinary markdown paragraph | looked for |
| a comment, a string, any markup capture | looked for |
| only code captures — a variable, an operator, a keyword | skipped |
| a capture family this plugin has never heard of | looked for |

Three of those five are permissive and the two that are not need positive
evidence. A grammar nobody anticipated, a parser that fails to load, a query
that throws — each falls through to "look anyway", because a feature that
silently stops working in one language is much worse than an occasional extra
float. The gate fails open in every direction it can; see `hover.scope`.

It costs nothing where it does not run. The token check comes first and rejects
the overwhelming majority of cursor positions — 530 of 531 in this plugin's own
largest source file — so the parse behind this section happens only for text
that already looks like a path. `:Hover paths code on` turns the position check
off entirely and lets the text decide alone; `:Hover show` ignores it
regardless, because asking about this exact spot is already the answer to "is
this worth asking about".

## The three measurements

These contradicted the intuition they were meant to confirm, and twice the
obvious fix was the wrong one. They live in the module headers of
`hover.scope` and `hover.bare_path` so that they are read when that code is
changed.

**1. A bare path that does not exist cost 13.2 ms** — per trigger, in exactly
the population an ambient trigger produces. The earlier number (~3 µs) had been
taken over a source file where almost every position is prose and never reached
the resolver at all. After `75f960e` it is 58.6 µs: **225× faster**.

The fix was *not* "cheap resolver first". gopath answers everything it can well
under 500 µs — **only the misses are expensive**. So the gate sits on the
token: on the automatic trigger gopath is asked only when it could plausibly
help (the token contains `...` or `…`, or has no slash at all), and an explicit
`:Hover show` runs the full pipeline. What that gives up is stated at
`gopath_can_help`: a relative path that exists elsewhere in the project stops
resolving on the timer.

**A correction from 2026-09-03, made by measuring the same thing from the
other side.** This number saw one cost where there were two, because it was
taken in a buffer that had a language server attached:

- **A 200 ms LSP wait** in every buffer with *no* server —
  `vim.lsp.buf_request_sync` does not return early when nobody is listening,
  it times out. Never visible from here, and by far the larger of the two.
  Fixed in gopath (`a7529d1`), where the provider now asks whether a client is
  attached before sending.
- **The tail search**, ~11.5 ms for a token with separators that could be a
  relative path. That one is real resolution work and is unchanged.

So the gate **stays**, and its reason is sharper than it was: measured after
the fix, a token with no separator costs ~100 µs and one with separators still
costs ~11.5 ms — which is exactly the shape the gate already had. It refuses
the slash-bearing tokens and asks for the rest. What did change is that a
hover in a `.txt`, a `gitcommit` or any buffer without a server got 200 ms
cheaper without a line changing here.

**2. The Treesitter gate is 80× more expensive than the token gate before it**,
not cheaper — ~90 µs against ~1.1 µs. It is affordable only because the token
gate throws away 99.8 % of cursor positions first. The roadmap had proposed the
opposite order, which would have paid the parse on every `CursorHold` in every
buffer.

**3. A git spawn costs 41 ms, a Docker spawn 230 ms, Podman 490 ms** — the
same whether they hit or miss, and that is the cheapest call either engine has,
not an `inspect`. That decided two things: the git class answers only on an
explicit request, and a container engine cannot ride the automatic trigger at
all — which is what [`on_request`](CONTRIBUTIONS.md#when-an-answer-is-expensive)
was built for.
