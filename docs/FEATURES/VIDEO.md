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

The one it does **not** answer is playback. Nothing in a terminal Neovim can
play a video, and the reason is worth stating precisely rather than hedging:

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

So the honest answer is a still. `gf` over the hover opens the file in whatever
plays video on that machine, and
[media.nvim](https://github.com/StefanBartl/media.nvim)'s `:Media play` does the
same from anywhere.

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

**Both are percentages, and that is the design.** Ten presses walk any file end
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
  video = { at = "10%", step = "10%", width = 800 },
})
```
