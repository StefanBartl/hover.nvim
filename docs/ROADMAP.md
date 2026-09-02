# Roadmap

What is deliberately not built yet, and what would have to be settled first.
A concept that ships gets deleted from here rather than marked done.

Three kinds of entry, in the order they are worth reading:
[integrations](#ecosystem-integrations) (what another plugin could contribute),
[features](#features) (what this one could do), and
[optimizations](#optimizations) (what it already does, worse than it could).
[Considered and rejected](#considered-and-rejected) is at the end, and is not
a to-do list.

---

## Ecosystem integrations

hover.nvim knows almost nothing on purpose: a plugin registers a *source*
("what is under the cursor?") or a *preview* ("how do I render a target of
this type?") and needs no change here at all. See
[INTEGRATIONS.md](INTEGRATIONS.md) for the two doors and which plugins use
which.

The candidates below came out of reading every `.nvim` repository in this
ecosystem against that question. Each names the entry point that already
exists — none needs a new API on the other side. Roughly ordered by value
per unit of work.

### `migrate.nvim` — the deprecated call under the cursor

**The best fit found, and the cheapest.**
`migrate.lsp.migrator.migrate_line(line)` takes a line and returns the
migrated version. Hand it the line under the
cursor: if what comes back differs, that line uses a deprecated Neovim API,
and the float can say which and what replaces it.

Everything the noise argument usually costs is free here: it fires *only*
where there is something to say, because a line with nothing deprecated in it
returns unchanged. No shape heuristic, no switch needed to keep it quiet.

**The framework side is built.** A `positions` contribution answers for a
cursor position that points at nothing, which was the blocker here and for
three of the entries below. Registering this is now:

```lua
require("hover.registry").register("migrate.nvim", {
  positions = {
    function(bufnr, row)
      local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1]
      local migrator = require("migrate.lsp.migrator")
      local migrated = line and migrator.migrate_line(line)
      if not migrated or migrated == line then
        return nil
      end
      return {
        lines = { "deprecated", "", "now: " .. migrated },
        title = "migrate.nvim",
      }
    end,
  },
})
```

Two things left, and both belong in migrate.nvim rather than here:

- **Its rules do not register without a picker.** `migrate.common.picker`
  fails to load in a bare Neovim, so `migrate_line` is a passthrough and the
  pairing above could not be proven end to end from this side. It has to be
  wired and measured where the rules actually exist.
- **Cost per trigger.** `migrate_line` on every `CursorHold` is unmeasured.
  The lesson from `hover.scope` applies: measure it against the gates in
  front of it rather than assuming a string operation is cheap.

### `documentation.nvim` — the module under the cursor

It already produces `docs/map/module_map.json` with a summary, a function
list and a body for every module in a repository. A source that recognises a
dotted module name (`lib.nvim.bindings.usercmd.composer`) plus a preview that
reads that artifact would turn any `require("…")` in any file into its own
documentation, with no scan at runtime.

To settle:

- **The artifact is a snapshot and can be stale**, and it is untracked in at
  least one repository here. A preview from a stale map is worse than none:
  it looks current. Needs the mtime in the float, or a staleness check
  against the source file.
- **A dotted name is not a path**, and the bare-path rules deliberately treat
  it as prose. Same shape as the reposcope entry below: register the source
  ahead of the bare-path one, and answer only for names the map confirms.

### `insights.nvim` — who else uses this

`insights.run_imports_reverse(module)` answers "which files import this
module", and `get_symbols(scope)` indexes symbols. Cursor on a `require`
target: how many places depend on it, and where. That is the question one
actually has while reading a module header, and it is currently a picker away.

To settle: **it is a scan, not a lookup.** The reverse-import query builds an
index; doing that inside a `CursorHold` is out of the question. It needs the
index to be warm and the preview to decline when it is not, rather than
blocking the trigger.

### `open.nvim` — the same classification, twice

The one entry here that is not "a plugin could contribute" but "two plugins
overlap and one of them should stop". `open.context.default_target(signals)`,
`candidate_targets(signals)`, `viewer.scan.is_url`, `is_anchor`, `resolve` —
that is a classification layer answering nearly the question `hover.classify`
answers, for the same text under the same cursor, to route it somewhere
instead of to preview it.

Neither knowing about the other is the current state and it is fine; the two
are not wrong about anything. Worth settling before either grows:

- **Which direction, if any.** hover could ask open "what is this?", open
  could ask hover, or a third module could own it. The precedent in this
  ecosystem is that shared classification with two consumers belongs in
  lib.nvim — but see the note under `hover.scope` in
  [Optimizations](#optimizations): two consumers is the bar, and this would
  be exactly two.
- **The float could offer the action.** Independently of the above, a
  preview that shows a target and cannot open it is half an answer.
  `open.open(target, scope)` is one call. That wants a key on the float,
  which the float cannot hold — it is `focusable = false` — so it would be
  another borrowed key, and the borrowed-key budget is already `q`, `<Esc>`
  and four scroll keys.

### `spotlight.nvim` — how often does this token occur

Reading a log, the cursor on a request id: spotlight already answers "every
other occurrence, right now" and keeps its own list (`spotlight.list(filter)`,
`toggle_here_at(text, pos)`). The float could say *how many* and *where the
next one is* without highlighting anything.

To settle: **the noise question**, which is real here in a way it is not for
migrate. Every token in a log is a token, so this has to answer only for
tokens already spotlighted — the framework has no shape heuristic to apply to
a position preview and cannot help. `:Hover positions off` silences every
registered plugin at once, which is the wrong granularity for "this one is
too eager"; a per-plugin switch is the missing piece if a second noisy
contributor ever appears.

### `reposcope.nvim` — a `repository` target type

[reposcope.nvim](https://github.com/StefanBartl/reposcope.nvim) already keeps
every README it has fetched in a RAM + on-disk cache keyed `owner/repo`.
Everything a hover would need is therefore already local: the natural feature
is resting the cursor on `owner/repo` — in a repo list, a plugin spec, a
lockfile, a note — and getting that README's head in the float.

Two things to settle:

- **A slug is not a path.** `owner/repo` is two components with no extension
  and no root, which the bare-path rules deliberately treat as prose (`and/or`
  is spelled identically). A reposcope source therefore has to run *before* the
  bare-path source — registration order already guarantees that — and must
  answer only for slugs it can confirm against its own cache, never for
  arbitrary text.
- **There is no `repository` target type.** Either reposcope resolves the slug
  to the cached README's path on disk and rides the existing `markdown`
  preview, or `classify` grows a type. The first needs no change here at all,
  and is the one to try.

Nothing in this repository has to change for either version.

### `sandbox.nvim` — the image under the cursor

In a `Dockerfile` or a `compose.yml`, `nginx:1.27-alpine` is a target: is it
pulled, is a container running from it, how big is it. sandbox.nvim manages
containers across pluggable backends and knows all three.

To settle: **an image reference collides with `path:line` syntax.**
`nginx:1.27` and `init.lua:42` are the same shape, and `hover.bare_path`
already splits on the colon. Whichever source runs first wins, which is a
registration-order decision that has to be made deliberately rather than
discovered.

### Two that are collisions rather than contributions

**`fileops.nvim` opens a float on the same event.** Its `on_hold` feature is
an ambient CursorHold line-diff preview (`fileops.features.on_hold`, opt-in,
default off). With both enabled, two plugins put a float on screen from the
same trigger in the same buffer. Nothing crashes and neither is wrong; they
have simply never been on together. Before recommending either alongside the
other, someone has to sit with both on for a day.

**`language.nvim` hovers a word.** Spelling, grammar, translation and
synonyms for the word under the cursor is a hover, and a good one — but every
word is a word. As an automatic trigger it is the noise problem in its purest
form. If it is wired at all it belongs behind `:Hover show` only, which the
framework supports (`show({ force = true })` opens every volume gate) but has
no way to express *per source* today.

### Considered and set aside

`recommender.nvim` (repetition count for a dotted chain) and
`runtime-analysis.nvim` (measured runtime for the function under the cursor)
are both plausible position previews, and the piece all three were waiting on
now exists. They stay here rather than above because neither has an entry
point as ready as `migrate_line` — both would need something new on their own
side first. `github_stats.nvim` overlaps reposcope. `dap.nvim`
and `lsp.nvim` are variable- and symbol-hover, a different feature wearing
the same word.

---

## Features

### Say why nothing happened

**The gap that made today's bugs expensive.** A hover that does not open is
silent by design, and there are now seven independent reasons for it: the
mode, the volume switch for that class, the dismissal, a non-blank character
check, the token shape test, the position gate, and "nothing on disk". From
the outside all seven look identical.

`:Hover why` would run the pipeline for the cursor position and report which
gate refused, without opening anything. Everything it needs already exists as
a value — `hover.status()`, `bare_path.is_unambiguous_path`,
`scope.allows_path`, `config.*_enabled()`.

To settle: **it must not become a second implementation of the pipeline.**
The moment it answers from its own copy of the rules it can be wrong in the
one situation it exists for. It has to be the real path, instrumented — which
means `under_cursor` growing an optional trace parameter, and that is a change
to the hot path for the sake of a debug command.

### Pin a float

A preview is transient by design: move the cursor and it is gone, which is
right for reading and wrong for comparing. Pinning one — keep it on screen
until dismissed, while the cursor goes elsewhere — costs one flag in
`hover.float` and a decision about what happens when the next hover opens.

To settle: **the generation counter assumes one float.** `_open`, `_generation`
and the async-result guard are all written for a single window; a second
concurrent preview is not a flag, it is a lifecycle. Worth knowing before
this is estimated as small.

### A line range as a target

`init.lua:42` resolves today and shows the file's head, not line 42.
`file.lua:10-20` is a shape logs and reviews produce constantly. The preview
would start at the line rather than at the top, which `preview.text` already
supports — it has `skip` and a scroll offset.

To settle: nothing structural. This is the smallest real feature on this
page, and the reason it is not done is that `split_location` currently
discards the line number rather than passing it to the preview.

### A git object under the cursor

A 7-to-40 character hex string in a commit message, a log or a review is a
target: `git show --stat` of it in the float. Unambiguous enough to be safe
(a hex string of that length in a repository that has it) and useless enough
to be silent everywhere else.

To settle: **shelling out per trigger.** `git cat-file -e` is cheap, `git show`
is not, and the answer belongs behind the same async guard PDF rendering uses.

### A demo GIF

`REL-09`, and the only 🟢 left open in the release gate. The README carries an
ASCII mock-up of the float, which explains the idea but not the feel — the
thing worth showing is how little it interrupts reading, and a still cannot.

---

## Optimizations

### Measure where the resolver's time actually goes

`bare_path.under_cursor` measures ~3.1 µs median but ~100 µs *mean* with a
~1 ms p99 — the distribution is all tail, and the tail is filesystem work.
What is not known is how it splits between gopath's resolver, `<cfile>`, and
the `fs_stat` in `classify`. Optimizing before knowing that is guessing, and
the last two measurements on this plugin both contradicted the intuition they
were testing (see `hover.scope`'s header).

### Cache the position gate per line

`scope.allows_path` parses the line it is asked about, every time. Within one
`CursorHold` that is once; moving along a line of code it is once per trigger
on unchanged text. A cache keyed `(bufnr, changedtick, row)` would answer the
second and later calls for free.

To settle: **whether it is worth anything.** The gate runs on roughly 1 cursor
position in 500 — the token gate rejects the rest — so this may be optimizing
something that already almost never happens. Measure first, in a buffer of
code rather than of prose.

### Drop less of the cache on a switch change

Every switch change drops the whole preview cache, because a stale entry
would answer with the old rendering and make the switch look broken. Correct,
and blunt: toggling `paths code` throws away rasterized PDF pages that no
switch can affect. Keying the drop by which classes a switch actually
influences would keep them.

To settle: **the mapping has to be derived, not written.** A hand-maintained
"switch X invalidates classes Y" table is precisely the shape of the
`route_path` bug (`ac50599`) — a second table that can fall behind the first
one silently, with nothing failing when it does.

### Let a grammar teach the position gate

`hover.scope` classifies capture families from two hardcoded sets, and falls
open on anything it does not recognise. That is the right default and it
means an exotic grammar gets no gating at all. A config key adding families to
either set would let someone fix that for their language without a patch.

To settle: **it is a footgun pointed at the good failure mode.** Adding to the
code set can silently disable the feature in a language, which is exactly what
the fail-open design exists to prevent. If it happens, `:checkhealth` has to
report the configured additions.

### `hover.scope` as a lib.nvim helper

"Is the cursor in executable code?" is generic, and `REL-31` asks for reusable
functions to move to lib.nvim. It has one implementor, and the rule that sent
the hover *out* of lib.nvim cuts both ways: a helper with one consumer is a
helper shaped by one consumer. The PROSE/CODE sets and the fail-open policy
are this plugin's trade-off, not a general one.

Revisit when something else asks the same question — `open.nvim` deciding
whether a token is routable would be the natural second.

### Office conversions could survive the session

Converted PDFs are cached under `stdpath("cache")/hover.nvim/office`, keyed by
path *and* mtime, and deleted at `VimLeavePre`. The mtime key already makes
them safe to keep; the deletion is a tidiness choice that costs a LibreOffice
start — seconds — on the first document of every session.

To settle: **an eviction policy**, which is the reason it was not kept. A
cache that only grows is a bug with a slow fuse; this needs a size or age cap
before it is allowed to outlive the session.

### Evidence for what no CI covers

The Windows and POSIX runners cover the specs, the formatter and the linter.
They do not cover the previews that need a terminal: drawing an image,
rasterizing a PDF page, converting an office document. Those are evidenced
only by hand, on one machine, and nothing records *when* they were last
exercised.

A short `docs/MANUAL-EVIDENCE.md` — what was checked, on what, on which date —
would at least make the gap legible instead of invisible. It is not a test,
and should not pretend to be.

---

## Considered and rejected

### A `hover.nvim` health check that runs the test suite

`REL-18` allows it where it is state of the art. It is not, here: the specs
need plenary and a writable temp directory, and a `:checkhealth` that shells
out to a test runner reports on the machine it happens to be run on rather
than on the installation. The health check asks about *this* installation
instead — which soft dependency answers, which switch is on, whether the
configuration is self-consistent.

### Per-filetype switch profiles

"Web links on in markdown, off everywhere else" sounds obviously useful and is
a trap: the switches are session state a reader throws while chasing
something, and making them depend on the buffer means the same key does
different things in two windows on screen at once. `filetypes` already answers
the coarse version — which buffers attach at all — and `:Hover links web on`
is one command.

### An absolute-latency trigger by default

`trigger = { "cursor" }` exists and works — `CursorMoved` plus this plugin's
own debounce, so `delay_ms` means what it says and nothing fires while the
cursor stands still. It is not the default, because `CursorHold` is what every
user's muscle memory and every other plugin's timing is already calibrated
against, and switching the default would change the feel of the plugin for
everyone who never asked.

What would justify promoting it: evidence that inheriting `'updatetime'` — a
global usually set for something else entirely, commonly 200ms for a git blame
— is a bigger surprise than the change. That is a question about real
configurations, not one to answer from the armchair.

### Range and count

Neither has a meaningful reading here today. Every `:Hover` route acts on the
cursor position or on a session-wide switch, and the two motions that exist
(`scroll(1)`, `scroll(-1)`) are already bound to keys rather than to a command.

If `scroll` ever gains a keymap this plugin owns rather than borrows, it wants
`v:count1` — "three pages forward" is a natural reading and `UI-40` asks for
it wherever an action is a step or a movement. The borrowed keys are the wrong
place for it: they exist for one float and a count prefix typed at them would
be indistinguishable from one meant for the mapping they displaced.
