# Videos

A `.mp4` under the cursor, shown as a still from the file — and the paging keys
turn that still into a scrub.

---

## The question this answers, and the one it does not

A video has no text in it, so the byte test in `preview.binary` is right that it
is binary — and it stops there:

```
◆ MP4 video
MP4 · 42.1 MB
```

That is every question about a video except the one anybody actually has, which
is *what is in it*.

What it does **not** answer with a real picture is playback — nothing in a
terminal Neovim can decode and paint video the way a real player does, and
the reason is worth stating precisely rather than hedging:

- The only image protocol that reaches the terminal from inside Neovim is
  OSC 1337. It carries a whole base64 payload per write and has no notion of a
  placement id or a frame — twelve frames a second of a 500×300 still is roughly
  half a megabyte per second through `nvim_ui_send`.
- Neovim repaints over anything drawn between its own redraws. That is already
  documented in `preview/media.lua`, where a *single* image needed a deferred
  draw for exactly this reason; an animation loop would be in a permanent race
  with the redraw cycle.
- The Kitty graphics protocol has animation frames and would be the right tool.
  Measured on 2026-08-05: on Windows in WezTerm, nothing sent from inside Neovim
  renders through it at all. Only OSC 1337 arrives.

So the default is a still, and it stays a still until asked otherwise. `gf`
over the hover opens the file in whatever plays video on that machine, and
[media.nvim](https://github.com/StefanBartl/media.nvim)'s `:Media play` does
the same from anywhere. The transport key (below) is the third option, and by
default (`video.playback = "window"`) it is the most direct one of all: a real
mpv window, video and sound, decoded and drawn by mpv itself rather than by
anything painted through Neovim — which sidesteps every point above by not
going through the terminal at all. `video.playback = "inline"` keeps the
older answer instead: real motion drawn as block graphics, which sidesteps the
same points by a different route, entirely inside the float, and needs no
separate window.

---

## The shape: the office route, one group over

`classify` gives a video its own target type for the same reason an office
document has one — not because it is a special kind of binary, but because it is
the second group with a *second answer available*:

| Type | Becomes a picture by way of | Producer |
| --- | --- | --- |
| `office` | a PDF page | pdfport.nvim → LibreOffice |
| `video` | a frame | media.nvim → ffmpeg |

From there both are image hovers: the same canvas geometry, the same draw, the
same keys. `preview/video.lua` is ninety lines because the interesting work
happens on the other side of the seam.

**Why media.nvim rather than an ffmpeg call here.** `images.nvim` says of PDFs
that it *"draws pictures; it does not read PDFs, and it does not want to"* — the
same sentence with "videos" in it is why the ffmpeg toolchain lives in its own
plugin. hover.nvim `pcall`s it and degrades to the badge when it is not there,
exactly as it already does with pdfport.

---

## The paging keys are the scrub

`preview.media.pdf` reports `scroll = { page = n }`, and the reader's
next/previous keys move it. This reports the same thing — and page *n* is the
still at `at + (n-1) × step` into the file.

Nothing new was needed on either side. What a PDF calls a page, a video calls a
moment.

| Setting | Default | Means |
| --- | --- | --- |
| `video.at` | `"10%"` | where the first still comes from |
| `video.step` | `"10%"` | how far one key press moves |
| `video.playback` | `"window"` | what the transport key does -- a real mpv window, or without mpv the system's own player, or `"inline"` block graphics -- see below |
| `video.use_mpv` | `true` | whether `"window"` may reach for mpv at all -- `false` is "I have it, do not use it", not the same as `"inline"` -- see below |
| `video.system_player_align` | `false` | experimental: best-effort centre the system player's window when there is no mpv window -- see below |
| `video.play_at` | `0` | where *playing* starts -- see below |
| `video.play_scale` | `2.5` | how much larger the playing canvas is than the still's budget (how *fine* each cell is, is images.nvim's `cells`) -- `"inline"` only |

**`at` and `step` are both percentages, and that is the design.** Ten presses walk any file end
to end: a ten-second clip and a two-hour feature both get ten stills spread
evenly, so one setting is right for both. Seconds work too — `at = 0`,
`step = 5` is a perfectly reasonable pair — and a file that reports no duration
falls back to a five-second step, because refusing to move would be the wrong
answer to a file that is otherwise fine.

Every offset visited is a cache entry in media.nvim, keyed by the source file's
mtime. Stepping back through a file already walked is a `stat` and a draw.

**Why 10% and not the first frame.** The first frame of a real video is usually
black, a fade-in, a distributor's logo, or a slate. Ten percent is past all four
in anything that is not a clip, and in a clip it is still an image of the clip.

**And why that reasoning stops at the still.** `video.at` is a thumbnail
offset, and playing borrowed it until 2026-09-08 — so pressing play on a
nine-minute file started it at 0:54, and on a two-minute one at 0:14, with no
way back to the opening. Skipping the slate is right for a picture nobody asked
to see and wrong for a viewer who pressed play. `video.play_at` is separate and
defaults to `0`. A *scrubbed* still keeps its position: from page 2 on, the
reader chose where to be, and play begins there.

---

## Playing it, and sound

A hover appearing is a glance — the cursor rested somewhere for `updatetime`,
which is not a request for motion. `transport_keys.toggle` (`<CR>` by
default) is that request.

**By default that request opens a real mpv window (`video.playback =
"window"`), not the block graphics described below.** The reason is a
measurement rather than a preference: painting a run of stills into the float
is the editor's own redraw, and on Windows in WezTerm that measured at about
one repaint a second — a slideshow — however the paint was written (buffer
lines, then extmarks, then overlay virtual text; three attempts, the same
ceiling, because the ceiling was never the Lua). mpv decodes and draws the
file itself, video and sound, with no editor redraw in the loop; the float
shows a short "playing" panel rather than a picture, since there is nothing
for it to paint. The same key stops the window, and so does closing the hover
any other way — a cursor move, `q`, `:qa`; `media.core.player` inside
media.nvim keeps its own `VimLeavePre` backstop for the exit that runs no
teardown at all. Playback starts from the scrubbed position exactly as the
route below does — `video.playback_offset` is the one function both share, so
the two cannot drift apart the way two hand-kept copies of that arithmetic
once did. `preview.window` also asks `preview.monitor` which screen the
terminal is on right now and passes it to mpv's `--geometry`, so the window
centres where the reader actually is on a multi-monitor machine rather than
always screen 0 — `preview.monitor`'s own doc has the reasoning (the
foreground window at the moment `<CR>` is pressed) and why the screen *index*
is Windows-only, verified against a real two-monitor machine.

**`video.use_mpv = false` asks for something `playback = "inline"` does
not.** "I have mpv installed, but this plugin should not touch it" — `<CR>`
then skips past the mpv tier straight to the one below, real video and sound
still, rather than falling all the way to silent block graphics. It silences
inline's optional sound too (`video.sound`), since "do not use mpv" means
none of it, not just the window.

**Without mpv (or with `use_mpv = false`), `"window"` still beats a muted run
of block graphics.**
`preview.external` hands the file to `media.play()` instead — a configured
player, or whatever this machine already opens a video with, the same call
`gf` already makes for "open externally". Real video and sound, nothing extra
to install, at a real cost: nothing here holds a process to kill the way
`preview.window` holds mpv's, since `media.play()` on Windows hands off
through `explorer.exe`, which dispatches to the registered app and exits
itself almost at once. `<CR>` a second time only drops the float back to the
still; the player keeps running until its own window is closed by hand,
exactly as it would have if opened with `gf` in the first place. A resize (or
any other re-render while the hover stays open) must not spawn a second copy
of the same file — `preview.external` tracks the last path it handed off and
treats a repeat for the same path as a no-op, since it has no handle to close
first the way the window tier's `M.open` does.

**`video.system_player_align` (default `false`, experimental) reaches for the
same "centred, like mpv" feel from outside a process this plugin does not
own** — on the same monitor `preview.monitor` found for the mpv tier, not
always the primary one. There is no `--geometry` to pass a system player the way
`media.core.player` passes mpv one, so the only way left is to watch for the
window that appears right after the hand-off and move it. `preview.
align_win` does this on all three platforms, and is honest that it can fail
silently on each:

- **Windows** moves a classic window (VLC, MPC-HC) cleanly with
  `SetWindowPos`. The stock handler for a video, "Films & TV", is a UWP app
  running inside a shared `ApplicationFrameHost.exe` container, and that
  container's window has historically ignored being moved from outside it —
  measured true on the machine this shipped from.
- **macOS** drives `System Events` over `osascript`, which can move most
  apps' windows once the terminal running Neovim has Accessibility
  permission (System Settings → Privacy & Security → Accessibility). Without
  it, every `tell` answers nothing, not an error.
- **Linux** prefers `xdotool` (search, geometry, move and activate in one
  tool), falling back to the cruder `wmctrl` (can move a window, cannot query
  its size, so it lands at a fixed offset rather than a true centre). Neither
  can move anything under Wayland, by that compositor's own security model —
  there is no escape hatch, only silence.

None of the three ever reports failure. Each writes a disposable script to
`stdpath("cache")` and runs it hidden: centres the window when it can, and
changes nothing from the plain fallback above when it cannot.

Everything from here describes `video.playback = "inline"`: it decodes a
short run with `media.frames()`,
draws it as block graphics (`images.blocks`, the same reasoning as above —
text survives redraws, an image protocol does not), and starts a timer.
`.` / `,` step one frame back or forward, pausing first — mpv's own
frame-step keys, picked so a float does not eat a leader key or a bracket
motion (`<Space>`, `]`, `[` were tried and reverted; see `transport_keys` in
`config/DEFAULTS.lua`).

**The window rolls, so it does not stop after two seconds.** One decode covers
two seconds — 24 stills at 12 fps — which is what makes the first frame arrive
quickly. On its own that meant playback stopped dead at the end of it while the
sound carried on alone, which is what a reader reported as *"no video, just a
couple of seconds"*. So the transport asks for the next window a second before
it needs it (a decode plus its sampling was measured at ~0.6 s) and swaps it in
when the picture reaches the seam. The clock keeps reading in source time across
the swap, so nothing about it is visible except that the film continues.

**A step is a place in the file, not an index into that window.** While it was
the latter, the transport keys could not leave the window they were in: `,`
stopped at its start and `<CR>` resumed from there, which right after play began
was the opening offset — reported as *"it jumps back to 0:54 and plays on from
there"*. A step past an edge now seeks mpv and fetches the window that holds
the target. A held key coalesces: one decode is in flight at a time and the
newest position wins, so leaning on `,` costs one window's wait rather than one
ffmpeg per press.

**The bar under the picture measures the film.** It measured the window until
2026-09-08, which meant it filled up and reset every two seconds forever —
read as reloading rather than as a position, and a second, contradictory answer
to the question the clock beside it (`0:55 / 9:05`) already answers. Without a
duration to measure against, the window is all there is and the bar says so.

**How sharp it is, is two settings.** A cell carries two pixel rows with a half
block (`▀`), so the still's 20-line budget is a picture 38 pixels tall.
Measured 2026-09-08, per window of 24 stills: 78x19 cells sampled in 168 ms and
painted in 6.4 ms; 140x36 — nearly four times the picture — sampled in 184 ms
and painted in 6.4 ms. ImageMagick's startup dominates one and extmark count
barely moves the other, so the small canvas bought nothing. Playing therefore
scales the **box** by `play_scale`, capped to the editor's own rows and
columns -- the box, because the float and the canvas are both derived from it
and have to agree. Scaling only the canvas wrapped every row onto two and
pushed the control row off the bottom, silently; `hover.box()` is the one place
that number lives, and it already reconciles zen and resize there.

That is the first of the two; the second is how finely each of those cells is
divided, which belongs to images.nvim (`display.ascii_fallback.cells`). A cell
holds two colours whatever character is in it — the terminal decides that — but
a half block can only place them top and bottom, while a sextant divides the
cell into six and keeps the diagonal edges. The same 113x32 canvas is a 113x64
picture with half blocks and a **226x96** one with sextants. Sextants are the
default there; `:checkhealth images` prints a row of each geometry, because
whether a terminal draws Unicode 13 block characters is not something Neovim
can ask it.

**That the finer geometries are free took one more fix, and finding it took a
reader.** A half block is always `▀`, so only its colours change; a sextant
picks a different glyph per cell per frame, and the paint therefore rewrote
every line of the canvas with `nvim_buf_set_lines` twelve times a second. That
is not a cheap thing done often — it bumps `changedtick`, runs every `on_lines`
listener, invalidates the extmarks on the lines it replaces, and marks every
window showing the buffer for a full redraw. Headless it is invisible, which is
why three rounds of measurement here missed it: the paint measured 8-15 ms and
looked healthy while a terminal ran at 1-2 fps. The reader found it in one line
by switching to half blocks and watching it go smooth. `images.blocks` now
paints an overlay `virt_text` mark per run of same-coloured cells, carrying the
glyphs as well as the highlight, and touches the buffer never
(`images.nvim@67964af`): `changedtick` stands still across a run in all three
geometries, and the sextant paint fell from 14.9 ms to 4.4.

**The picture runs on a local clock that mpv corrects, not on mpv itself.**
Until 2026-09-08 the transport asked mpv for its position once per painted
frame and skipped the tick while an answer was outstanding, which made the IPC
round trip a hard ceiling on the frame rate. Measured against a stub with a
known latency: 0 ms gives 11.3 fps, 80 ms gives 11.0, **150 ms gives 5.7 and
300 ms gives 3.0**. A real round trip averages 9.5 ms here but was measured at
377, and every two seconds playback starts an ffmpeg and an ImageMagick for the
next window — so the spikes are not rare, and a reader reported 1-2 frames per
second with the sound running a second ahead of the picture. Now the frame to
draw comes from `uv.hrtime`, corrected against mpv four times a second: sound
still leads, because every correction moves the picture to wherever mpv
actually is, but a paint never waits for an answer.

**The sound joins the picture, and never the other way round.** mpv takes about
a second to answer its IPC socket, and the transport does not wait for it — it
paints from frame one immediately. Until 2026-09-08 mpv's clock then took over
unadjusted, and mpv was still at the offset play began from: a second behind,
so the picture snapped back to meet it, reported as *"the sound comes in and the
video starts over from the beginning"*. mpv is now started paused, seeked to
wherever the picture has got to when its handle arrives, and only then resumed —
so nothing on screen moves backwards and no sound is heard from the wrong place
while it comes up. A short catch-up guard covers the ticks right after that
seek, where mpv still reports the position it is leaving.

**Sound joins automatically when there is something to play it with.** If
the file has an audio track and [mpv](https://mpv.io) is on PATH,
`media.audio()` starts it alongside the run — no separate opt-in beyond
`video.sound` (default `true`, one flag to turn it off). Neither ingredient
is required: no track, or no mpv, and the run plays exactly as it did before
sound existed, muted, never an error.

**Why this does not drift the way picture-plus-sound usually does.** The
picture does not run on its own clock and hope the sound stays close — the
timer asks mpv *where it is* once per tick and paints whatever frame belongs
to that answer, so a late tick just jumps to wherever the sound has gotten
to rather than falling further behind it. See
[`media.core.audio`](https://github.com/StefanBartl/media.nvim)'s module
header for the design and why it had to be a real player rather than a
decoder.

```lua
require("hover").setup({
  video = { sound = false },  -- keep it muted even when mpv is available
})
```

---

## What it costs, and what happens when it cannot

A still is a keyframe seek and a scale. `-ss` goes *before* `-i` in the argv
media.nvim builds, which makes it a seek rather than a decode of everything up
to the offset — measured on a 4 GB h265 file, 210 ms for an offset near the end
against roughly half a minute for the slow form.

That is the same order as the PDF previewer, which is why there is **no
`convert` switch** here the way `office` has one: an office page costs a
LibreOffice start-up, seconds per document, and had to be asked for.

Every way this can fail degrades to the badge, with a note naming the reason:

| Situation | Shown |
| --- | --- |
| media.nvim not installed | `(media.nvim not installed — no frame preview)` |
| ffmpeg not on PATH | `(ffmpeg not on PATH — no frame preview)` |
| no image provider | badge + the metadata line |
| `inline_images = false` | badge + the metadata line |
| the seek found nothing | the error, in the badge |

None of them is an error, and none of them is silent.

---

## The metadata line

Under the badge — and in the border under the picture — goes:

```
1920x1080 · 4:32 · h264 · 100.0 MB
```

It comes from `media.ui.summary`, so hover.nvim and `:Media probe` describe the
same file with the same words rather than inventing two vocabularies for it. It
is the one thing a still cannot say about itself.

Two details in it are less obvious than they look, and both are media.nvim's
doing:

- **The resolution is the displayed one.** A video recorded on a phone held
  upright stores 1920×1080 frames plus a 90-degree display matrix. ffmpeg
  auto-rotates on decode, so the still is upright — and reporting the stored
  pair would size a landscape float around a portrait picture.
- **An mp3's album art is not a video.** ffprobe reports it as a video stream,
  truthfully; taking that at face value would make every tagged music file in a
  library hover as a one-frame film. Audio files get the badge here.

---

## Which extensions are claimed

`mp4`, `m4v`, `mkv`, `mov`, `avi`, `webm`, `wmv`, `flv`, `mpg`, `mpeg`, `m2ts`,
`ogv`, `3gp`.

**`.ts` and `.mts` are deliberately absent.** They are MPEG transport streams,
and they are TypeScript. In an editor the second reading wins by orders of
magnitude, and claiming them would send every TypeScript file in a project to
ffmpeg. `.m2ts` is unambiguous and stays.

`.ogg` stays audio, for the weaker version of the same reason: it is a container
that legally holds video, and in practice does not.

---

## Off by default, like office

`video` is not in `auto_hover`. A directory listing scrolled past should not
start a process per line — the same argument that keeps `office` out, and the
one `QUIET.md` makes in general.

```vim
:Hover show          " answers for a video always, asked or not
:Hover auto video    " and this makes the trigger do it unprompted
```

```lua
require("hover").setup({
  auto_hover = { video = true },
  video = { at = "10%", step = "10%", width = 800, sound = true, play_at = 0, play_scale = 1.75 },
})
```
