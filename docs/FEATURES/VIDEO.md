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
the same from anywhere. The transport key (below) is the third option: real
motion, drawn as block graphics rather than a real picture, which sidesteps
every point above because text is not a graphics protocol.

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
| `video.play_at` | `0` | where *playing* starts -- see below |
| `video.play_scale` | `1.75` | how much larger the playing canvas is than the still's budget |

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
default) is that request: it decodes a short run with `media.frames()`,
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

**How sharp it is, is `video.play_scale`.** A cell carries two pixel rows (the
half block `▀`), so the still's 20-line budget is a picture 38 pixels tall.
Measured 2026-09-08, per window of 24 stills: 78x19 cells sampled in 168 ms and
painted in 6.4 ms; 140x36 — nearly four times the picture — sampled in 184 ms
and painted in 6.4 ms. ImageMagick's startup dominates one and extmark count
barely moves the other, so the small canvas bought nothing. Playing therefore
gets a canvas `play_scale` times the still's budget, capped to the editor's own
rows and columns.

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
