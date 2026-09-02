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
("what is under the cursor?"), a *preview* ("how do I render a target of this
type?") or a *position* ("is there anything to say about this place?") and
needs no change here at all. See [INTEGRATIONS.md](INTEGRATIONS.md) for the
doors and which plugins use which.

Five of the candidates that used to be listed here are built and live in the
plugins that own them: migrate.nvim, reposcope.nvim, documentation.nvim,
spotlight.nvim and sandbox.nvim. What remains is one that is blocked on its
own side, and two that are collisions rather than contributions.

### `insights.nvim` — who else uses this

`insights.run_imports_reverse(module)` answers "which files import this
module", which is the question one actually has while reading a module header.

**Blocked, and not on hover.nvim's side.** `run_reverse` runs
`scan_cwd_async` — a full walk of the working directory, chunked over
`vim.schedule` — and opens a scratch buffer with the report. There is no
index to consult: every query re-scans. A hover cannot start that, and
`positions` cannot answer asynchronously.

To settle, in insights.nvim rather than here: **a cached import index**, warm
enough to answer a lookup, with the preview declining when it is cold rather
than building it. That is a change to that plugin's architecture, not a
wiring job.

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
form. "Behind `:Hover show` only" is expressible per source now — a
contribution marked `on_request` is skipped by the automatic trigger and asked
only when the reader asks for it.

That settles the mechanism and not the question. sandbox.nvim gets away with
`on_request` because a cheap text check rejects `init.lua:42` in a millisecond
before any process starts; a word lookup has no such pre-check, so under
`force` every position is a hit. Whether a dictionary should open in the
middle of prose is a decision for language.nvim, and it has to come before the
wiring rather than out of it.

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

### A demo GIF

`REL-09`, and the only 🟢 left open in the release gate. The README carries an
ASCII mock-up of the float, which explains the idea but not the feel — the
thing worth showing is how little it interrupts reading, and a still cannot.

### A sharp zoom for a PDF page

The picture half of this entry is **built** — `:Hover zoom`, a cropped detail
with `h/j/k/l` to move it, at 258 ms a step. Why it is a route rather than a
key, and why the ceiling is capped instead of discovered, is in
[docs/FEATURES/ZOOM.md](FEATURES/ZOOM.md). What is left here is the half that
crop cannot answer.

**A PDF page on screen is not the file the target names.** It is a
rasterization in this plugin's own cache, rendered once at pdfport's default
DPI. Cropping it magnifies a bitmap that is already as sharp as it will ever
be: bigger, and no more detail — which is the one thing a zoom is for.

The answer is a second rasterization. `render_page` takes a `dpi` and this
plugin passes none. The obstacle is the page cache, whose key is path, mtime
and page number: two resolutions of one page would overwrite each other. One
`dpi` in the key, one in the call, and a decision about how many resolutions
are worth keeping.

**To settle first: the price.** A second render was measured at 3.3 s against
258 ms for a crop, on the same machine and the same day. That is well past the
point where the existing placeholder machinery merely covers a wait, and a
feature whose cheapest honest form takes three seconds may want a different
shape than "press the same key again".

---

## Optimizations

### `hover.scope` as a lib.nvim helper

"Is the cursor in executable code?" is generic, and `REL-31` asks for reusable
functions to move to lib.nvim. It has one implementor, and the rule that sent
the hover *out* of lib.nvim cuts both ways: a helper with one consumer is a
helper shaped by one consumer. The PROSE/CODE sets and the fail-open policy
are this plugin's trade-off, not a general one.

Revisit when something else asks the same question — `open.nvim` deciding
whether a token is routable would be the natural second.

---

## Considered and rejected

### Merging hover.nvim's and open.nvim's classification

The entry that stood here read: two plugins answer nearly the same question
about the same text at the same cursor, one to route it and one to preview
it, and one of them should stop. `open.context.default_target`,
`candidate_targets`, `viewer.scan.is_url`, `is_anchor`, `resolve` against
`hover.classify` and `hover.bare_url`.

**Read at the level of function names it is a duplication. Read at the level
of contracts it is not**, and the names are what mislead:

- `open.context.default_target` picks a *handler key* -- browser or file
  manager -- from a three-pattern URL check. It does not classify anything;
  it routes. `hover.classify` maps a target onto nine types with an
  extension table and one `fs_stat`, so a `.docx` gets an office preview and
  a missing file gets a marker. Neither could stand in for the other.
- `scan.is_url` is a predicate anchored at `^` on a whole target. hover's
  four URL patterns *find* a URL anywhere in a line, require two leading
  alpha characters, and cover `mailto:` and the `http:\\` typo. One asks
  "is this string a URL", the other "where in this line is one".
- `scan.resolve` returns URLs and anchors unchanged, splits and re-attaches a
  `#fragment`, and takes a directory. `classify.resolve_path` always returns
  a path, takes a source *file*, and never sees a fragment because `classify`
  splits it first.

Each is shaped by what its caller needs: open scans many lines for openable
things and must not report prose; hover classifies one target it was handed
and must tell missing from absent. A shared helper would either hand each
caller more than it needs, or grow enough options to be a worse version of
both. There is nothing here to extract.

**The half that was real is shipped**: `open_keys` (`gf` by default) opens
what the float is showing, routed through open.nvim when it is installed and
`vim.ui.open` otherwise. A preview that shows a target and cannot open it was
half an answer, and that was the actual complaint underneath the entry.

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
