# Architecture

What each module is for, and the two invariants a plausible-looking change reintroduces a
bug through.

`:DocMap` builds a browsable module map of this repository under `docs/map/`. It is
generated and gitignored, so it is not in the checkout — run it when you want it.

---

## Modules

| Module | Job |
| --- | --- |
| `hover` | Orchestration: debounce, generation counter, `show`/`hide`/`scroll`/`resize`/`zoom`/`nav`/`dismiss`/`pin`/`set_mode`/`set` |
| `hover.config` | The effective configuration, legacy normalization, and every predicate derived from it |
| `hover.config.DEFAULTS` | Plugin-side defaults, and why each one is what it is |
| `hover.switches` | Every runtime on/off switch, declared once — routes, completion, `status` and `:checkhealth` all read from it |
| `hover.status_view` | `:Hover status` as a board: every switch, its state, and the command that acts on it |
| `hover.cache` | The LRU of built previews, the rule about dropping it, and the registry a previewer with a store of its own hooks into so a switch drops that too |
| `hover.registry` | Plugin sources, previews and position previews |
| `hover.classify` | Target string → typed target. Pure, no I/O beyond one `fs_stat` |
| `hover.formats` | What an extension names, and whether it is convertible |
| `hover.bare_path` | Paths with no link syntax; asks gopath.nvim when present |
| `hover.bare_git` | A git object id under the cursor — shape only, no process |
| `hover.bare_url` | URLs with no link syntax, in any filetype |
| `hover.scope` | Whether the cursor sits somewhere a path could be written at all |
| `hover.float` | The window |
| `hover.notify` | Every announcement, through lib.nvim's notifier |
| `hover.health` | `:checkhealth hover` — see [health.md](health.md) |
| `hover.bindings.*` | Keymaps (borrowed and owned), the `:Hover` verb, the trigger autocmds |
| `hover.preview.text` | File heads, directory listings, the missing marker |
| `hover.preview.binary` | Is this text at all, and what to say when it is not |
| `hover.preview.office` | Office documents: the badge, or the converted PDF's page |
| `hover.preview.url` | URL details, optional fetch |
| `hover.preview.git` | `git show --stat` of an object, async |
| `hover.preview.media` | Images and PDF pages, via whatever provider is installed |

The two directions a plugin and the hover reach each other through — the registry inbound,
a named `pcall` outbound — are in [integrations.md](integrations.md).

---

## Two things that must not be changed casually

Both were bugs, both took a long time to find, and both are easy to reintroduce with a
change that looks obviously correct.

### The float is positioned `relative = "editor"`, not `"cursor"`

Even though "one line below the cursor" is exactly what is wanted.

`nvim_win_get_position` reports a **wrong column** for a cursor-relative float when the
editor window does not start at column 0 — it adds the window's origin to a cursor
position that already contains it. Measured with a 26-column file tree: a float whose
frame is drawn at column ~59 reports **83**. Neovim draws it correctly; only the
self-report is wrong.

That is fatal here, because this float's geometry *is* the drawing box handed to the
terminal for an image. Everything downstream computes a correct offset from a wrong
origin, and the picture lands beside its own frame by the sidebar's width.

So `float.open` takes the cursor's true grid position from `screenpos()` and opens an
editor-relative float, which reports back exactly what it was given. **Reverting that to
`relative = "cursor"` brings the bug straight back**, and it only shows with a sidebar
open.

### The image is fitted to the drawing box, not to the frame

`canvas_cells` subtracts `draw_inset` before asking `fit_cells`, then adds it back for the
frame. That looks like an off-by-two and is not.

`images.anchor` keeps `draw_inset` cells free on every side, so a float sized to fit the
image exactly is drawn into a box two cells smaller per axis. Two cells off 20 rows is a
bigger relative change than two off 77 columns, so the ratio moves — and
`preserveAspectRatio=1` letterboxes the difference and centres it. Measured: ~2.7 cells of
empty space on the left for a 1200×675 image in a 77×20 frame, which reads as "the image
is shifted right".

### If a placement problem appears again

`images.nvim` ships the measurements as `:Image debug` (`report`, `columns`, `float`).
Two traps, both of which cost days:

- **A consistency check passing proves nothing about the origin.** Sent coordinates
  matching the reported float position held throughout both bugs above. Compare the report
  against reality — `:Image debug float` draws a marker at the reported corner for exactly
  that.
- **A generated test card cannot reveal an aspect-ratio problem**, because
  `images.testcard` builds it to whatever box it is handed. Reproduce with a real image.

Neither of these is reachable by CI: what a terminal actually drew is visible and nothing
else. That gap is recorded by hand rather than by CI — in notes kept outside this
repository, because what one person saw on one machine is their record and not this
plugin's documentation.

---

## References

- Neovim: `:help nvim_open_win()`, `:help CursorHold`, `:help 'updatetime'`,
  `:help maparg()` / `:help mapset()` — the four APIs the borrowed-key lifecycle rests on.
- [iTerm2 inline images protocol (OSC 1337)](https://iterm2.com/documentation-images.html)
  — how images.nvim draws into the float.
