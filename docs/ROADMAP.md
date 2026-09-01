# Roadmap

What is deliberately not built yet, and what would have to be settled first.
A concept that ships gets deleted from here rather than marked done.

---

## Open

### Scoping bare paths to comments and strings

**The remaining half of the noise problem.** In a code buffer a path is almost
always inside a comment or a string literal — never in the middle of an
expression. Gating the bare-path source on "is the cursor in a comment or a
string" would remove nearly all remaining false starts in source files while
leaving prose, `.txt`, commit messages and `:messages` dumps untouched (no
parser, no gate).

Two things to settle first, and they are why this is not done:

- **Fail-open, not fail-closed.** A buffer with no parser, a parser that fails
  to load, or a language whose grammar names the node something else must fall
  through to "check anyway" (`ERR-20`). A silently skipped region is much worse
  than an occasional extra float.
- **The cost is per `CursorHold`.** `vim.treesitter.get_captures_at_pos` on
  every trigger in every buffer needs measuring against the `<cfile>` gate it
  would sit in front of, not assumed to be cheaper.

### A `repository` target type, for reposcope.nvim

[reposcope.nvim](https://github.com/StefanBartl/reposcope.nvim) already keeps
every README it has fetched in a RAM + on-disk cache keyed `owner/repo`.
Everything a hover would need is therefore already local: the natural feature
is resting the cursor on `owner/repo` — in a repo list, a plugin spec, a
lockfile, a note — and getting that README's head in the float.

Two things to settle first:

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

Nothing in this repository has to change for either version. See
[INTEGRATIONS.md](INTEGRATIONS.md).

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
