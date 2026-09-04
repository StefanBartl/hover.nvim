# Workflow — getting real use out of hover.nvim day to day

Every feature here is documented on its own elsewhere ([Features](FEATURES/README.md),
[Commands](commands.md), [Bindings](BINDINGS.md), [Configuration](configuration.md)).
This is the different question: once several of them exist, *how do they actually
combine* while reading and writing real files.

Almost all of it comes back to one thing. This plugin puts a float over the paragraph you
were reading, and the only reason that is ever welcome is that the float is worth more
than the paragraph. Every lever below is a way of saying where that line sits for you
right now.

---

## The quiet ladder: reach for the narrowest lever that answers

There are four, and they are not interchangeable. Reaching for the blunt one out of habit
is the trap, because it takes previews away that you would have wanted.

| Lever | Takes away | Reach for it when |
| --- | --- | --- |
| `:Hover auto file` | one *kind of target* opening unprompted | text-file heads interrupt but pictures do not — the usual case |
| one switch, e.g. `:Hover paths missing off` | one *class of preview*, everywhere, including `:Hover show` | you never want that class at all |
| `:Hover mode manual` | the automatic trigger, nothing else | "I am reading a document made of links **right now**" |
| `:Hover mode off` | everything | you want the plugin quiet and are not coming back this session |

**`manual` is the one most people actually want, and the one they reach for last.** It
keeps every preview — web links included, in full — and gives up only the part that opens
by itself. It is a mood, not a configuration decision, which is why it is a command rather
than a switch you edit. Bind a key for `show` before you rely on it:

```lua
require("hover").enable({ mode = "manual", keymaps = { show = "<leader>k" } })
```

Without that key, `manual` is indistinguishable from a broken plugin from the outside —
`:checkhealth hover` warns about exactly that combination.

**`auto_hover` is the standing preference; `mode` is the switch for right now.** They
were one setting until 2026-09-03 and are two because they answer different questions.
`:Hover auto file` for the session, `auto_hover = { "image", "pdf", "file" }` in your spec
for good.

## When nothing hovers, ask before you guess

`:Hover why` names which gate declined *at this cursor position*, and what to type about
it. Reach for it first. There are nine switches, three modes, eleven target types and a
Treesitter scope check, and guessing between them is a bad use of anyone's afternoon.

`:checkhealth hover` is the other half and answers a different question — about the
**installation** rather than about this position. Use it when nothing hovers *anywhere*:
it catches the missing hard dependency, the mode set in a forgotten spec, the empty
`auto_hover`, the contribution that never registered. See [health.md](health.md).

The order matters. `:Hover why` on a position where nothing was ever going to hover tells
you the truth and not much else.

## Three operations on a float, and they answer three questions

They are easy to confuse because two of them make the picture bigger.

| You want | Reach for | What actually happens |
| --- | --- | --- |
| more of the *file* | `<C-Down>` / `<C-Up>`, or `<M-PageDown>` / `<M-PageUp>` | the next screenful of lines, or the next PDF page |
| the same content, more *room* | `+` / `-` over a picture, `:Hover resize` anywhere | the box grows: a picture is drawn larger, text shows **more lines** |
| a *detail*, closer | `>` / `\|` / `=`, or `:Hover zoom` | the box stays, the view narrows: a picture is cropped, a PDF page re-rendered sharper |

**Only the third is magnification**, which is why it is not called zoom on the second row
— for text a bigger box cannot mean bigger letters, because the font belongs to the
terminal emulator. Once you are zoomed in, `h`/`j`/`k`/`l` move the view; they are bound
only while zoomed, and handed straight back after.

A zoom step costs about a quarter of a second, so it is a deliberate press rather than a
dial you hold. Stepping back out to a view you have already seen is instant — the crop is
cached for the session.

## `q` is "not now", `:Hover pin` is "stay"

The float is over the thing you are trying to read and you have to stay on the path:
press `q` or `<Esc>`. That is a **dismissal**, not a close — the hover stays away for as
long as the cursor stays on that target, and clears itself the moment the cursor resolves
something else.

Closing alone would not do. Under `CursorHold` the event fires again after any keystroke
followed by quiet, movement or not, so a key bound to `hide()` makes the float vanish and
then brings it straight back while you are still standing where you wanted it gone.

`:Hover pin` is the opposite move: keep this float while the cursor goes elsewhere, for
comparing rather than reading. While pinned the trigger opens nothing — there is one
float — and `:Hover show` replaces it.

## Reading somebody else's documentation

The default is already tuned for this, and the two things worth turning on are turned on
per session rather than in a spec:

- `:Hover links web on` while you are auditing links. Nothing leaves the machine at this
  level — host, path and decoded query are parsed offline.
- `:Hover links web fetch on` on top of it when the question is "is this link still
  alive": you get the status code and the page title. **This is a disclosure**, so leave
  it in the session it belongs to. Every link the cursor rests on becomes a request from
  this machine to that host.

If the float starts landing over every second paragraph while you read, that is
`:Hover mode manual`, not `:Hover links off`.

## Adding one hover without writing a plugin

The `contribute` table takes exactly what `hover.registry.register` takes, so a function
in your config is a contributor like any other:

```lua
require("hover").enable({
  contribute = {
    positions = {
      function(bufnr, row, _col)
        local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
        local ticket = line:match("PROJ%-%d+")
        if not ticket then
          return nil   -- silence is the common answer and must stay cheap
        end
        return { lines = { ("%s — %s"):format(ticket, ticket_title(ticket)) }, title = "tracker" }
      end,
    },
  },
})
```

Two things to know before it disappoints you:

- **It registers under the name `user`**, so a second `setup` replaces it rather than
  stacking a copy. Reloading your config does not make the same function fire twice — and
  a *plugin* must use `register` with its own name, or two callers would silently delete
  each other.
- **Check that it arrived.** `:checkhealth hover` lists it back as `registry: user`. A
  contribution that never registered is absent from that list; one that registered and
  returns `nil` is on it. Those two failures are identical from the outside and this is
  the only thing that tells them apart.

If your answer costs a process start, mark the entry `{ fn = …, on_request = true }` and
it is asked only on `:Hover show`. See
[FEATURES/CONTRIBUTIONS.md](FEATURES/CONTRIBUTIONS.md#when-an-answer-is-expensive).

## Installing a sibling plugin changes what the hover can do, not how it behaves

The whole ecosystem is optional and every plugin buys exactly one row of what the float
can show. Two are worth knowing in this order:

1. **markdown.nvim** — without it *only bare paths* start a hover. With it, link syntax
   and `file.md#heading` opening on that section. If link previews seem not to work at
   all, this is why, and `:checkhealth hover` says "a link source is registered" or does
   not.
2. **images.nvim** — without it a picture is described rather than drawn, and so is a
   rasterized PDF page.

When a hover is *wrong* rather than absent, [integrations.md](integrations.md) reads each
symptom back to the plugin that owns it. That table exists because "the hover is broken"
is almost never a statement about the hover, and a plugin can be named in hover.nvim's own
source without having run any of the code in the stack trace.

## Two plugins answering about the same place

On a dotted name this is routine: one says what the module is, another who imports it.
`<M-n>` (or `:Hover next`) steps between them and wraps. Nothing is counted in advance —
knowing how many *would* answer means calling every contribution on every hover, which is
the cost the whole design avoids — so stepping is what asks, and a contribution marked
`on_request` is reachable that way.

If several plugins are registered and one of them turns out too talkative,
`:Hover positions off` is the lever, and it is a blunt one: it silences every registered
plugin at once.
