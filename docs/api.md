# Lua API

Everything a plugin or a config can call. `:help hover-api` is the same list offline.

Every function that acts on the float on screen returns `false` when there is nothing to
act on, so all of them are safe to bind unconditionally.

---

## Opening and closing

| Function | Does |
| --- | --- |
| `hover.setup(opts)` | Configure and return. Does **not** switch anything on |
| `hover.enable(opts)` | Configure *and* install the trigger, attach open buffers, apply the keymaps. Idempotent — its two augroups are cleared and rebuilt on every call |
| `hover.show(opts)` | One hover at the cursor. `opts.force` opens every volume switch, but not the mode |
| `hover.hide()` | Close the float |
| `hover.dismiss()` | Close it **and keep it away** while the cursor stays on this target |
| `hover.pin(on)` | Keep this float while the cursor goes elsewhere; omitted, it toggles |
| `hover.target_under_cursor(bufnr, opts)` | The target under the cursor, or `nil` |

`dismiss` rather than `hide` is what a key should call: under `CursorHold` the event fires
again after any keystroke followed by quiet, so `hide()` makes the float vanish and then
brings it straight back.

## Acting on the float on screen

| Function | Does |
| --- | --- |
| `hover.scroll(delta)` | Next/previous screenful of lines, or PDF page. Does not re-resolve the cursor — the hover keeps showing what it was showing |
| `hover.resize(delta)` | Multiply the box the previewer is given by 1.25 per step. A picture is drawn larger, a text preview shows more lines |
| `hover.zen(on)` | The same box, set to the editor's own size, and the float centred; omitted, it toggles. Returns `asked`, plus the reason where a refusal is worth naming. Pins by default — see [ZEN.md](FEATURES/ZEN.md) |
| `hover.zenned()` | Whether the hover on screen is full screen |
| `hover.zoom(delta)` | Magnify a *detail*: the box stays, the view narrows by 1.5 per step. Not an alias for `resize` |
| `hover.nav(dx, dy)` | Move the magnified view. `dx` is -1 left, 1 right; `dy` is -1 up, 1 down |
| `hover.next_position()` | Step to the next plugin answering for this place |
| `hover.set_border(name)` | Change the frame of the float already on screen |

`resize` and `zen` decline for a *position* preview, whose content came from another
plugin and cannot be asked again at a larger size. `zoom` declines when there is no
picture, or no detail left.

## Mode and switches

| Function | Does |
| --- | --- |
| `hover.mode()` | The mode in effect right now |
| `hover.set_mode(mode)` | `"auto"` \| `"manual"` \| `"off"`. Returns the mode, or `nil` plus a message |
| `hover.toggle(on)` | Off, or back to `"auto"` |
| `hover.set(name, on)` | Turn a single switch on, off, or over. The names are what `hover.switches.names()` returns |
| `hover.enabled(name)` | Whether one switch is in effect, implications included |
| `hover.set_auto(which)` | Which target types open by themselves |
| `hover.status()` | `{ mode, switches, auto }` — for a statusline or a report. Each switch carries `enabled` (the chain folded in), `flag` (its own value) and `route` (the words to type at it) |
| `hover.why()` | Which gate declined at this cursor position |

`set_mode` keeps `vim.g.hover_disable` in step, so the runtime switch and the spec setting
are one setting rather than two that can disagree.

---

## The registry

A plugin registers *into* hover.nvim rather than hover.nvim reaching for it. Nothing about
this requires a plugin around it — `setup`'s `contribute` field takes the identical table.

```lua
require("hover.registry").register("your.nvim", {
  -- "what is under the cursor?" Return a raw target string, or nil.
  -- Tried in registration order, before the built-in bare-path source.
  sources = {
    function(bufnr, row, col)
      return find_target(bufnr, row, col)  -- , { kind = "yours" }
    end,
  },
  -- "how do I preview a target of this type?" Keyed by the type `classify`
  -- produced; returning nil declines and the built-in preview runs.
  previews = {
    anchor = function(target, opts, bufnr) return section_of(target, bufnr) end,
  },
  -- "is there anything to say about this place?" Asked only after every
  -- source declined, because a target is the more specific reading of the
  -- same place. Returns finished content -- there is nothing to classify.
  positions = {
    function(bufnr, row, col)
      local note = something_about(bufnr, row)
      if not note then
        return nil       -- silence is the common answer, and must stay cheap
      end
      return { lines = { note }, title = "your.nvim" }
    end,
  },
})
```

Target types a preview can claim: `image`, `pdf`, `office`, `markdown`, `file`,
`directory`, `url`, `anchor`, `missing`.

**Re-registering under the same name replaces that plugin's contribution**, so a `setup()`
that runs twice does not leave two copies firing on every hover. A source that throws is
skipped and the next one still runs.

### When your answer is expensive

Both `sources` and `positions` accept a table entry instead of a bare function:

```lua
positions = {
  { fn = function(bufnr, row, col) end, on_request = true },
}
```

Such a contribution is asked **only for an explicit request** — `:Hover show`, or a key
bound to it — and never on the automatic trigger. The flag exists because how expensive
your answer is, is knowledge only you have: measured, a git start costs ~41 ms, a
`docker --version` 230 ms, `podman --version` 490 ms, the same whether they hit or miss.

It also does **not** count as "something that could answer" when the trigger decides
whether to install itself at all. A buffer whose only contribution is request-only gets no
`CursorHold` — one that woke, asked nobody and slept again would be pure cost.

### Three rules that follow from the shape

- **Sources win.** On a path inside a deprecated call, the file is what the reader pointed
  at. Positions are asked only after every source declined.
- **Nothing a position answers is cached.** A target has an identity to key a cache by and
  a position does not; what a position preview answers can depend on the whole buffer, so
  a stale entry would be a *wrong* answer rather than an old one. Freshness belongs to the
  plugin that registered it.
- **It is your job to be quiet.** The framework has no shape heuristic to apply here — it
  cannot know what your answer is about. `:Hover positions off` exists for when that
  judgement turns out wrong, and it is a blunt instrument: it silences every registered
  plugin at once.

`:checkhealth hover` lists every name that registered, with a count per kind and how many
of those entries are `on_request`. That line separates "it never registered" from "it
registered and declined", which look identical from the outside.

Why there are three kinds, why one of them can decline to be asked, and the bug that only
a live wiring could find: [FEATURES/CONTRIBUTIONS.md](FEATURES/CONTRIBUTIONS.md). Who
currently arrives through this door: [integrations.md](integrations.md).
