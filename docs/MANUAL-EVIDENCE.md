# Manual evidence

What is checked by hand, because no CI can check it — and **when it was last
checked**, which is the part that decays.

CI covers the specs, the formatter and the linter, on Ubuntu and on Windows.
It does not cover anything that needs a terminal to draw into: an image, a
rasterized PDF page, a converted office document. Those three are the most
visible things this plugin does, and nothing automated has ever exercised
them.

This file exists so that gap is *legible* rather than invisible. **It is not
a test suite and must not be read as one.** A row here says one person saw
one thing work once, on one machine.

## How to read a row

| Column | Means |
| --- | --- |
| Checked | The date. A row with no date has never been checked, only written down. |
| On | The machine, terminal and Neovim it was seen on. Everything here is terminal-dependent, so "it worked" without that is not a claim. |
| How | Enough to repeat it. If a row cannot be repeated from what it says, it is not evidence. |

## What no CI covers

### Images drawn into the float

| | |
| --- | --- |
| **Checked** | 2026-09-01 |
| **On** | Windows 11, WezTerm, Neovim 0.12.2, images.nvim present |
| **How** | Rest the cursor on a `./assets/*.png` path. The picture appears inside the float, fitted, not beside it. |
| **Watch for** | The picture landing beside its own frame — that is the placement bug written up in [the README](../README.md#two-things-that-must-not-be-changed-casually), and it only shows with a sidebar open. Reproduce with a real image; a generated test card cannot reveal an aspect-ratio problem. |

### A PDF page rasterized

| | |
| --- | --- |
| **Checked** | 2026-09-01 |
| **On** | Windows 11, WezTerm, Neovim 0.12.2, pdfport.nvim + `pdftoppm` on PATH |
| **How** | Cursor on a `.pdf` path; page 1 appears. `<M-PageDown>` pages forward and stops at the last page. |
| **Watch for** | "rendering…" that never resolves, and paging past the end — the page count is never known in advance, so the last page is discovered by asking for one too many. |

### An office document converted

| | |
| --- | --- |
| **Checked** | *never — see below* |
| **On** | — |
| **How** | `:Hover office on`, then hover a `.docx`. The first one costs a LibreOffice start, which is seconds. |
| **Watch for** | The badge saying LibreOffice is missing rather than a failed conversion — `can_create("office")` is asked first, precisely so the answer is a sentence and not a hang. |

**The office path has not been checked since the conversion cache was allowed
to outlive the session.** That change (age-based sweep, `office.cache_days`,
default 7) is covered by specs only where it is wiring; the sweep itself
touches a real cache directory and a real LibreOffice, and neither is in any
test. The two things worth confirming by hand:

- a second session hovering the same document does **not** start LibreOffice
  again — that is the whole point of letting the cache survive;
- a file in `stdpath("cache")/hover.nvim/office` older than `cache_days` is
  gone after the next conversion, and nothing outside that directory is
  touched.

## What is checked automatically, for contrast

Not evidence of the above, and listed only so the boundary is clear: the spec
suite, `stylua --check`, `luacheck`, and a LuaLS scan with the real injected
library — the last of those run from
`nvim/scripts/luals-scan/`, not from this repository. All four on Ubuntu and
Windows, per push.

## Keeping this honest

A row whose date is older than the code it describes is worse than no row,
because it reads as a check that happened. When one of the three paths above
changes, either check it again and move the date, or set the date back to
*never* and say why.
