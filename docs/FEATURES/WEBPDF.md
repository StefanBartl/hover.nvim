# A link that answers with a PDF

Why the cheapest picture this plugin produces was also the last one it learned,
why it needs a second request when the plan said it would need none, and why
the size cap is the interesting part. For *how* to use it, see
[commands.md](../commands.md) and [configuration.md](../configuration.md).

## What it is

`:Hover links web fetch pdf`, and then a link whose server answers
`application/pdf` shows the document's **first page** instead of its size. From
there it is a PDF like any other: `<C-Down>` / `<C-Up>` page through it, `>`
magnifies by re-rendering at a higher DPI, `F` puts it on the whole screen.

Nothing is converted. The bytes at the other end already *are* a PDF, so they
go into the pdfport/`pdftoppm` pipeline a local `.pdf` has always used — this
feature is a download, a cache, and a hand-off.

## Why the plan was wrong about the second request

The plan for this said it would need no request of its own: `links.fetch` had
already downloaded the body, so the bytes were paid for. That was the whole
argument for shipping it without a switch, and it does not survive contact with
the code.

`lib.nvim.net.curl` runs:

```lua
vim.system(argv, { text = true, ... })
```

**`text = true` replaces `\r\n` with `\n` in the output.** For HTML that is
invisible. For a PDF it is fatal: a binary stream rewritten at every `0D 0A` is
a file `pdftoppm` will not open — and the failure would arrive looking like a
broken renderer rather than like a mangled download, which is the worst shape a
bug can have.

So the document is downloaded again, with `curl -o` writing straight to the
cache file. The bytes never pass through Lua as text.

And because it *is* a second request, it is a switch. Everything in this plugin
that costs a round trip is one.

## Why that second request is also the answer to the size cap

A fetch is capped at 2 MB (`--max-filesize`), which is right for a page and far
too small for a document. The obvious fix — raise the cap — is wrong: it would
raise it for every HTML page too, and the cap is what bounds what a *hover*
will pull down.

The real obstacle is ordering. **The content type is not known until the first
response has come back**, so one request cannot carry both numbers. Two can:
the first learns what the link is, the second is sized for the answer.

`links.pdf.max_bytes` is that number, 25 MB by default. A document over it is
**refused rather than truncated**, and the message names both the size and the
option:

```
PDF, 41.2 MB -- larger than links.pdf.max_bytes (25.0 MB)
docs.example.com
/reports/annual.pdf
```

Half a PDF is not a smaller PDF. It is a file that will not open, and serving
one from the cache for a week would produce a rasterizer error every time.

## What counts as a PDF

The **server's** content type, never the URL's extension.

A `.pdf` in a path is the author's word for what a link points at. This module
is about to spend a request and up to `max_bytes`, so the server's word is the
one worth acting on — and the two disagree often enough to matter: a download
endpoint with no extension, or a `.pdf` that 404s to an HTML error page.

The download is checked again on arrival, before anything is rasterized: a file
that does not start `%PDF-` and end with `%%EOF` is deleted rather than cached.

## The cache, and the key it cannot have

Downloads live in `stdpath("cache")/hover.nvim/webpdf`, swept once per session
by `links.pdf.cache_days`, exactly as [office documents](../configuration.md)
and [rendered pages](SHOT.md) are.

`preview/office.lua` keys its converted PDFs by path **and mtime**, so an edited
document converts again. A URL has no mtime this side of a request, so the key
here is the URL plus **the length the server declared**. That is weaker and it
is the honest limit of what a response offers for free: a document replaced by
one of a different size is fetched again, and one replaced by an identically
sized file is not.

## Paging and zooming, and the one line that made both work

A PDF behind a link is a `url` target, not a `pdf` one — and two places in the
orchestrator decided what to do by that type:

- `hover.scroll` turned pages for `pdf` and `office`, and moved by lines for
  everything else;
- `hover.zoom` re-rendered for `pdf`, and cropped for everything else.

Both were reading the type as a proxy for *"is this preview paged"*, and the
proxy stopped being accurate the moment a link could answer with a document.
So `present` records the answer from the content instead — only a paged preview
declares `scroll.page` — and both read that. The type test is kept beside it,
because a paged preview whose first answer is a placeholder declares no
`scroll` at all, and a keypress in that moment would otherwise take the wrong
branch.

That is one field on the open hover, and it is why a web PDF pages and
magnifies with no code of its own.

## What it costs when it is off

Nothing. With the switch off a PDF link is what it always was — the status
line, the content type and the size:

```
HTTP 200 OK
application/pdf · 2.3 MB
docs.example.com
/reports/annual.pdf
```

Which is honest, and was the whole preview until this existed.
