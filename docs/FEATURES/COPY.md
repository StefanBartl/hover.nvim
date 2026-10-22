# Taking something out of the float

Why a float that cannot be entered needs a copy of its own, why a picture is
copied as a file and never put on the clipboard, why the copy is what is *on
screen* rather than what the target is, and why `Y` is the key. For *what to
type*, see [commands.md](../commands.md); this page is the reasoning
underneath.

## What it is

`:Hover copy`, or `Y` while a float is up:

- **A text hover** (a file, markdown, a directory, a fetched page): the
  float's lines go into the unnamed register, linewise, and onto the clipboard.
  The message says how many lines.
- **A drawn hover** (a picture, a page screenshot, a PDF page, any of them
  zoomed): the very picture on screen is copied to
  `stdpath("cache")/hover.nvim/copies`, and **only its path** goes into the
  registers.

## Why it exists

The float is `focusable = false` (see [ZEN.md](ZEN.md) for what follows from
that). No motion, no Visual mode and no mouse selection reaches it, so nothing
in a hover could be taken out of it. The only gesture there was, `gf`, opens
the target, which is a different question.

It was asked for as "select part of the hover with the mouse and copy it".
Two answers were on the table: this route, or making the float enterable on
request. The route came first because it needs no change to how a float lives.
Entering it is a separate piece of work, for the reasons under
[Why not just enter the float](#why-not-just-enter-the-float).

## What is on screen, not what the target is

**Text is read from the float's own buffer**, not from the content it was
built from. A preview scrolled with `<C-Down>` gives the lines it scrolled to;
`:Hover zen` gives the screenful. The title is in the border, not in the
buffer, so it never comes along. Two things are taken off the end: the blank
lines a preview pads with, and the marker a truncated preview ends on (`…`,
`… (N entries)`). Those say "there is more", they are not part of what is
there. Lines that wrap below the float's lower edge are in the buffer and are
copied too.

**A picture is the file that was drawn.** `present` records
`content.image_path` for every render, and every way of showing a picture goes
through it: the crop of a zoomed view (the crop, not the source), the page of
a PDF as rasterized, the screenshot of a link, the still of a video. A render
that shows text clears it again.

Two states decline, with the reason:

- **A playing video.** The buffer holds block characters and the picture lives
  in extmarks. Copying it gave "copied 33 line(s)" and 33 lines of `█`.
- **A placeholder still rendering.** "rendering page 3…" is a sentence about a
  picture that is not there yet.

## Why a picture is never put on the clipboard

An image on the clipboard is a different program on every platform:
`Set-Clipboard` on Windows, `wl-copy` or `xclip` with a MIME type on Linux,
`osascript` on macOS. Each fails in its own way, and each failure is silent. A
path does the same job everywhere: paste it into a file dialog, an attachment
field or a command line.

The copy is a file of its own, rather than the path of the cached picture,
because those caches sweep themselves: a screenshot, for one, is deleted
after `links.shot.cache_days`. The name comes from the target
(the file's stem, the last part of a URL without its query, fragment or
`user:pw@`) plus the time, so two copies never collide.

**The copy is dated now.** `fs_copyfile` keeps the source's modification time
(`CopyFileW` on Windows, `clonefile` on macOS), and the sweep reads it: a
picture from 2023 was copied as a file two years old and deleted by the next
session, with its path still in the clipboard. Copies are kept for seven days
of their own.

## Why the clipboard gets a newline

A linewise copy goes into `"` as linewise, and `p` puts it on lines of its
own. A clipboard provider keeps no register type. With
`clipboard=unnamedplus`, `"` **is** the clipboard, and the same copy pasted
into the middle of the current line. The clipboard is written last, with a
trailing newline, and that newline is what makes the paste linewise again.

The clipboard itself is lib.nvim's `copy_to_clipboard`, which checks that the
write took rather than trusting `setreg`. When it did not, the message says
"the unnamed register" instead of "the register and the clipboard".

## Why `Y`

`Y` already means yank. It is one finished operation with no prefix (`y$` in
Neovim's defaults), and while a float is up the only thing worth yanking is in
a window that cannot be entered. It is borrowed like every other key in
[BINDINGS.md](../BINDINGS.md): bound for **every** hover, after the dismiss and
open keys, and handed back the moment the float closes, so `y$` is there again.

A key listed twice is taken once, by whichever list is bound first.
`:checkhealth hover` names a copy key that collides with another borrowed list,
in both directions: one that is also a dismiss key never copies, and one that
`zen_keys` also wanted now copies instead of going full screen.

## Why not just enter the float

Making the float focusable on request, a focus route that does not exist yet, would give Visual mode
and the mouse for free, and it is the second stage of the same request. It is
not a switch, for three reasons in how a float lives today:

- **The borrowed keys are global.** Inside the float, `j`, `+`, `F`, `q` would
  still be hover actions.
- **The dismissal is a global autocmd** on `CursorMoved` and `BufLeave`.
  Entering the float is a `BufLeave`, so it would close the float it entered.
- **Every re-render reopens the window.** A resize or a scroll would take the
  float away from under the cursor that is in it.

Each one needs its own change and its own tests, so it is a separate piece of
work.

## What no CI covers

The specs pin the registers, the register type, the path and date of a copied
picture, the declined states, and that `Y` is borrowed and given back, with the
clipboard stubbed (lib.nvim's clipboard may start a process the test guards
refuse). Not covered: a real clipboard, and that a zoomed view really copies
the crop. Both need a terminal that draws pictures.
