# Health

```vim
:checkhealth hover
```

Five sections, and the reason there are five is that **"the hover does nothing" has five
completely different causes that look identical from the outside.** A single pass/fail
would report the symptom everyone already has.

| Section | What it answers |
| --- | --- |
| **hover.nvim** | Is `lib.nvim` there, and is it new enough — the one dependency with no fallback |
| **configuration** | Which mode is set, what `auto_hover` opens by itself, and every switch with its current state |
| **optional contributors** | Which sibling plugins are installed, what each absent one is not doing, whether a link source is registered at all, and — read back off the registry — every name that registered |
| **external tools** | `soffice` and `pdftoppm` on `PATH`, and *whether they are even needed* |
| **declared tools** | The tools declared in [`install.json`](install.json), through `lib.nvim.deps` — why each matters and how to install it on this machine. Absent on an older lib.nvim |

---

## The warnings worth knowing about

The section that catches the silent failures is **configuration**, and it warns on four
combinations that each leave a correctly installed plugin doing nothing visible:

- **`mode: off`** — nothing hovers at all. Usually `vim.g.hover_disable` set in a spec and
  forgotten.
- **`manual` mode with no key bound to show anything.** From the outside that is
  indistinguishable from a broken plugin, which is why it is a warning rather than an
  info line.
- **`auto_hover` empty** — the trigger is installed and opens a float for no type. Every
  preview still answers on `:Hover show`.
- **Every preview class switched off** — no target can produce a float, so there is
  nothing left for the trigger to find.

Two more arrive with page screenshots, and only while that switch is on:

- **No headless browser found** — the render cannot happen, and the section names what it
  looked for and how to point it at one.
- **Screenshots on while `images` is off.** A rendered page *is* a picture; with nothing to
  draw it there is no browser worth starting, and the float says so instead of rendering.

One more arrives only with [`persist`](configuration.md#persisting-runtime-changes) on:

- **`persist` is on, but `lib.nvim.cache.disk` is not reachable.** An older lib.nvim,
  most likely. Nothing else breaks — switches simply stop surviving a restart until it is
  updated.

Two more come from the keys rather than from the switches:

- **A resize wheel key bound while `'mouse'` is empty.** No wheel event reaches Neovim at
  all, so the mapping is inert rather than broken — and those look identical from the
  outside.
- **A zoom key that is also a resize key.** Resize is bound first and a key listed twice is
  taken once, so the overlap means it will resize and never zoom. Reported rather than
  left to be discovered as a key that does the wrong thing.

## Reading the contributors section

Each check asks for the **entry point that is actually called** rather than for the
module, so "installed" and "answers" cannot drift apart.

The registry is then read back — every name that registered, with a count per kind and,
in parentheses, how many of those entries are `on_request`:

```
registry: user -- 1 position preview (1 asked only on `:Hover show`)
```

That line is what separates the two failures behind "my hover does not appear", which are
otherwise indistinguishable: a contribution that never registered is **absent** from the
list, and one that registered and returned `nil` is **on** it.

## External tools

`soffice` is needed only when office rendering is on, so with `office.convert = false` a
missing `soffice` is an info line rather than a warning — the section answers "is this
tool needed here" before it answers "is it present".

On Windows the LibreOffice installer does not put `soffice.exe` on `PATH`, so this reports
it missing on a machine where LibreOffice is plainly installed. That is correct, and the
one-line fix is in
[installation.md](installation.md#soffice-on-windows-installing-libreoffice-is-not-enough).

**The browser for page screenshots is the one place the report will appear to contradict
itself, and that is deliberate.** With `:Hover links web shot` on you may see both of
these:

```
✅ page screenshots: C:\Program Files\Google\Chrome\Application\chrome.exe
   -- found off PATH, so the `chrome NOT found` line below is expected and not a problem
⚠️ chrome NOT found (optional)
```

Both are true and only the first one counts. The declared-tools section asks `PATH`, and
the Chrome installer does not extend it — the same thing `soffice` does. hover.nvim
searches the usual install locations itself, so the line that names a path is the one that
says what would actually be run. `links.shot.command` names one outright when the search
picks the wrong browser.

## When it is not the right tool

`:checkhealth hover` answers about the *installation*. When a hover fails to appear for
one specific thing rather than for everything, [`:Hover why`](commands.md) is the sharper
tool: it names which gate declined, at this cursor position, with the command that opens
it.

And when the answer is "nothing is wrong with the installation" but a picture still lands
beside its own frame, the two invariants in
[architecture.md](architecture.md#two-things-that-must-not-be-changed-casually) are the
next place to look.

## What this deliberately does not do

It does not run the test suite. The specs need plenary and a writable temp directory, and
a `:checkhealth` that shells out to a test runner reports on the machine it happens to be
run on rather than on the installation in front of it.
