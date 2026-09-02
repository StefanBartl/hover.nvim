# Manual evidence

What is checked by hand, because no CI can check it — and **when it was last
checked**, which is the part that decays.

CI covers the specs, the formatter and the linter, on Ubuntu and on Windows.
It does not cover anything that needs a **terminal to draw into** — an image,
a rasterized PDF page, a converted office document — and it does not cover
anything that needs a **daemon to answer**, which is the container engine
behind a contribution marked `on_request`. Those are the most visible things
this plugin does, and nothing automated has ever exercised them.

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

### A hover resized

| | |
| --- | --- |
| **Checked** | 2026-09-02 — **the picture half. The text half is still unchecked**, see below. |
| **On** | Windows 11, WezTerm, Neovim 0.12.2, images.nvim present |
| **How** | Hover an image, then press `+` a few times and `-` back. The float grows and shrinks with it, and the picture fills it edge to edge at every size. Then hover a *text* file and run `:Hover resize` a few times: the float grows and more lines appear in it — `+` is deliberately not bound there. |
| **Watch for** | The **frame** growing while the picture inside it does not — that is the one failure a spec cannot see. `TESTS/resize_spec.lua` pins the geometry all the way to `nvim_win_get_config`, but the cell area is only a *request* to the terminal, and whether the drawing actually followed it is visible and nothing else. Also: letterboxing that drifts as the box grows (the picture no longer centred, or gaining a margin on one side only), which would mean the inset is being added at the wrong end of the scaling. |

**What was seen:** `+` several times and `-` back, over an image. The float
grows and shrinks with it and the picture fills it edge to edge at every size
— so the picture followed the cell area rather than the frame growing around a
picture that stayed put, which was the one failure no spec can reach.

**Still unchecked: the text half.** `+` and `-` are deliberately not bound over
a text hover — they are motions there — so the check is a different gesture:
hover a text file and run `:Hover resize` a few times. The float should grow
*and more lines appear in it*. That distinction is the whole reason the feature
was renamed, and it is the half a spec covers least convincingly: the spec
asserts the float's geometry, and "more lines are in it" is what a reader
actually looks for.

Measured, not seen, on 2026-09-02: a 1200×675 image at the default `80×20`
grows through five steps on a 210×55 terminal (71×20 cells of picture up to
181×51) and through none at all on 80×24, where 20 rows is already
`lines - 4`. Those are float geometries read back from Neovim — they say the
frame is the right size, not that a picture arrived in it.

### A picture zoomed, and panned around in

| | |
| --- | --- |
| **Checked** | *never* |
| **On** | — |
| **How** | Hover an image, then press `<M-z>` two or three times. Each step takes about a quarter of a second and shows a **smaller part of the picture, larger** — not the same picture bigger. Then `h` `j` `k` `l` to move around in it; `<M-Z>` steps back, `<M-R>` returns to the whole picture. `:Hover zoom [in\|out\|reset]` does the same three from the command line. Finally press `h` with the hover **not** zoomed: the float should go away, because there the key is the cursor motion it always was. |
| **Watch for** | `<M-z>` doing nothing at all, which has two causes that look identical: the picture is not zoomable (no ImageMagick, or it is a PDF page) — the float says so — or the terminal does not send the chord, which `:nnoremap <M-z> :echo "da"<CR>` settles in one press. Then: the **whole picture getting larger** instead of a detail — that is resize's answer arriving where zoom's was asked for, and it looks almost right. Also: panning that jumps to a corner rather than moving a quarter of a view (a pixel centre instead of a fractional one would do that), and a centre that survives `reset` and makes the next zoom start somewhere nobody chose. |

**What is covered without a person.** `TESTS/zoom_spec.lua` pins the
arithmetic, and outside the suite the crops have been confirmed to be written
and to shrink as calculated — `800x533+200+133`, then `533x355+333+222`, then
`355x237+422+281`, with the centre clamped inside the source and `reset`
returning the whole image.

**What that leaves.** Every one of those numbers is a rectangle handed to
ImageMagick. Whether the resulting file is *drawn* into the float, and whether
what appears is a magnified detail rather than a scaled whole, is visible and
nothing else — the same gap as the resize row above, one layer further along.
And whether `h/j/k/l` feel right while panning is not a question a spec can be
asked at all.

**What the suite covers since 2026-09-02.** The crop check used to report
*pending* on every machine, for two bootstrap defects rather than a missing
tool: `scripts/minimal_init.lua` never reached its images.nvim fallbacks, and a
single-file run got a different environment from a directory run. Both are
fixed, and the spec now writes a real cropped file with ImageMagick and
compares its pixel size against the rectangle the arithmetic asked for. What is
left for this row is the part after the file exists: whether it is *drawn*.

### The resize wheel, where it points

| | |
| --- | --- |
| **Checked** | *never* |
| **On** | — |
| **How** | Hover an image. With the pointer **on** the float, `<M-ScrollWheelUp>` a few times: it grows. Move the pointer well off the float and press it again: nothing happens. `<M-ScrollWheelDown>` on the float shrinks it back. |
| **Watch for** | Nothing happening *anywhere*, which is the interesting failure and has two causes that look identical: `'mouse'` not covering the mode (`:checkhealth hover` warns about exactly this), or the terminal not sending Alt+wheel as a distinct chord. `<M-ScrollWheelUp>` mapped to `:echo` tells the two apart in one press. Also worth watching: a step landing while the pointer is *beside* the float rather than on it — the gate is a rectangle test, and a wrong one would show up as a float that resizes from anywhere. |

**Why this cannot be a spec.** Mouse input needs a UI attached: measured on
2026-09-02, `nvim_input_mouse` fired **zero** mappings with
`#nvim_list_uis() == 0`, while `feedkeys` with the same termcode fired one. So
the specs drive the chord and stub the pointer position, which pins the
mapping and the rectangle test but says nothing about a real wheel reaching
Neovim.

The same measurement is why the gate does not use `getmousepos().winid`: the
float is `focusable = false`, and with the pointer squarely inside one, that
field named the window *underneath* it. Only the screen coordinates are
usable, so `hover.float.contains` does the rectangle test itself.

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
| **Checked** | 2026-09-02, and confirmed a second time the same day — **the conversion and the cache. The sweep is still unchecked**, see below. |
| **On** | Windows 11, WezTerm, Neovim 0.12.2, pdfport.nvim + LibreOffice 25.x |
| **How** | `:Hover office on`, then hover a `.docx`. The first one costs a LibreOffice start, which is seconds. Then `:qa`, restart, `:Hover office on`, and hover the same document again. |
| **Watch for** | The badge saying LibreOffice is missing rather than a failed conversion — `can_create("office")` is asked first, precisely so the answer is a sentence and not a hang. On Windows that badge is the *expected* first result even with LibreOffice installed, because its installer does not extend `PATH`; the fix is in [installation.md](installation.md#soffice-on-windows-installing-libreoffice-is-not-enough) and it is not a bug in this path. |

**What was seen**, in order: with office rendering off, the badge
`no text preview  ·  :Hover office on`. With it on, `converting to PDF…`,
then the rendered first page inside the float. After `:qa` and a restart, the
same document showed a badge for roughly a third of a second and then the
page — **no LibreOffice start**, which is the whole point of letting the cache
outlive the session. The flash is the PDF being rasterized again, not the
document being converted again; those are two different caches, and only the
outer one is this plugin's.

The cache directory afterwards held exactly one file:

```
<stdpath("cache")>/hover.nvim/office/Bewerbung_…-a62f1bc27aecd87f.pdf
```

To list it yourself — `nvim --headless -c 'echo …'` mixes the startup message
into its own output, so the path has to be written rather than echoed:

```powershell
ls "$(nvim -u NONE --headless -c 'lua io.write(vim.fn.stdpath("cache"))' -c 'q')/hover.nvim/office"
```

**Still unchecked: the age-based sweep.** `office.cache_days` (default 7) is
covered by specs only where it is wiring; the sweep itself touches a real
cache directory, and that is in no test. What is left to confirm by hand:
a file in that directory older than `cache_days` is gone after the next
conversion, and nothing outside the directory is touched. Backdating one file
there and hovering any office document is the whole check.

### A contribution asked only on request

| | |
| --- | --- |
| **Checked** | 2026-09-02 |
| **On** | Windows 11, Neovim 0.12.2, sandbox.nvim beside this repo, Docker Engine 29.5.3 holding four images and two stopped containers |
| **How** | `nvim --clean --headless -l scripts/onrequest_probe.lua docker` from the repo root. Four references in one buffer — a pulled image with no container, a pulled image with one, an image that is not pulled, and `init.lua:42` — each asked twice: once on the automatic trigger, once forced. |
| **Watch for** | Anything but `quiet` in the `auto` column. That column is the whole of what `on_request` buys, and losing it is silent: an engine start would then run after every keystroke followed by quiet, arriving as a stutter nobody would connect back to a container engine. Second: `(nothing shown)` on a row that should answer, which is the shape of `836a15a` — a preview correctly registered and reachable by no route at all. |

**Why no CI can do this.** A contribution marked `on_request` is skipped by
the automatic trigger and asked only for an explicit request; the only shipped
one is sandbox.nvim's container-image preview, and answering costs a container
engine. So the last step — a force-only contribution actually putting lines on
the screen — has no automated witness. The probe reads the float's first line
back rather than trusting the return value, because `836a15a` lived exactly in
the gap between "the pipeline returned true" and "something arrived".

Measured on the machine above, keypress to finished float:

| Reference | Answer | Forced | Engine calls |
| --- | --- | --- | --- |
| `alpine:edge` | pulled, no container | 566 ms | 2 |
| `lazyvim_starter:latest` | pulled, 1 container | 558 ms | 2 |
| `nginx:1.27-alpine` | not pulled | 294 ms | 1 |
| `init.lua:42` | declined | 0 ms | 0 |

All four stayed quiet on the automatic trigger. The 294 ms row is the evidence
for the second engine call happening only on a hit; the 0 ms row is evidence
that the `name:tag` collision with a file-and-line reference is refused
**before** any process starts.

**The run with no argument is the one that found something.** Without an
engine name the probe used sandbox.nvim's own detection, and on this machine
that picked `podman` — on PATH, but with its VM not running. Every row then
declined after ~370 ms, silently and for a reason that had nothing to do with
this plugin, while a working Docker engine sat beside it.

That was a sandbox.nvim bug and it is **fixed there** (sandbox.nvim `deb45bc`,
2026-09-02): detection now takes the first installed engine that actually
answers, and the same probe run picks `docker`. The row is kept because the
*shape* is worth recognising and will recur — an integration can be registered,
green in every spec, and silent on the machine, and the only thing that says so
is a run on a real one. When a container hover answers nothing, **check which
engine was chosen before suspecting the hover.**

## What is checked automatically, for contrast

Not evidence of the above, and listed only so the boundary is clear: the spec
suite, `stylua --check`, `luacheck`, and a LuaLS scan with the real injected
library — the last of those run from
`nvim/scripts/luals-scan/`, not from this repository. All four on Ubuntu and
Windows, per push.

## Keeping this honest

A row whose date is older than the code it describes is worse than no row,
because it reads as a check that happened. When one of the seven paths above
changes, either check it again and move the date, or set the date back to
*never* and say why.
