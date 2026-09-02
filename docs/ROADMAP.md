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

Four of the candidates that used to be listed here are built and live in the
plugins that own them: migrate.nvim, reposcope.nvim, documentation.nvim and
spotlight.nvim. What remains are the two that measurement ruled out, and the
framework gap both of them are waiting on.

### A source that answers only on request

**The missing piece, and two entries below need it.** A registered
contribution is asked on every trigger. There is no way for a plugin to say
"ask me only when the reader asked" — which is exactly what an expensive
answer needs, and what `hover.bare_git` gets by being built in rather than
registered.

Measured, the two populations this would unlock:

    git cat-file -e            41 ms   (built in, force-only, shipped)
    docker --version          230 ms
    podman --version          490 ms

Those are process starts, and a trigger that fires after every keystroke
followed by quiet cannot pay them. `:Hover positions off` is the wrong
granularity — it silences every registered plugin at once, not the expensive
one.

To settle: **what the flag attaches to.** A contribution is a list of plain
functions today; making one of them force-only means either a table form
(`{ fn = …, on_request = true }`, backwards compatible) or a fourth
contribution kind. The first is smaller and reads worse; the second is
honest and adds a concept.

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

### `sandbox.nvim` — the image under the cursor

In a `Dockerfile` or a `compose.yml`, `nginx:1.27-alpine` is a target: is it
pulled, is a container running from it, how big is it.

**Blocked on the entry above.** Measured on this machine, `docker --version`
costs 230 ms and `podman --version` 490 ms — and that is the cheapest call
either engine has, not an `inspect`. Five to twelve times the git cost that
already ruled the automatic trigger out. It needs the force-only source
first, and then it is a small integration.

Second thing to settle once it is: **an image reference collides with
`path:line` syntax.** `nginx:1.27` and `init.lua:42` are the same shape, and
`hover.bare_path` already splits on the colon. Registration order decides it,
and that has to be chosen deliberately rather than discovered.

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

### A demo GIF

`REL-09`, and the only 🟢 left open in the release gate. The README carries an
ASCII mock-up of the float, which explains the idea but not the feel — the
thing worth showing is how little it interrupts reading, and a still cannot.

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
