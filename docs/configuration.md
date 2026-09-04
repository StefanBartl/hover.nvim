# Configuration

Every option `setup()` and `enable()` accept, with its default. Both take the same table —
see [installation.md](installation.md) for why `enable()` rather than `setup()` is what
turns the plugin on.

```lua
require("hover").setup({
  mode = "auto",
  trigger = { "CursorHold" },
  delay_ms = 250,
  links = { enabled = true, web = false, fetch = false },
  paths = { enabled = true, missing = true },
})
```

A partial table merges over the defaults one key at a time, so nothing has to be repeated
to change one thing. The exception is any list of keys: a configured list **replaces** the
default rather than extending it, which is what a list should mean. `{}` binds nothing.

---

## What opens a float, and when

| Option | Default | Meaning |
| --- | --- | --- |
| `mode` | `"auto"` | `auto` \| `manual` \| `off`. The switch above every other switch — see [Modes](#modes). |
| `auto_hover` | `{ "image", "pdf" }` | Which target types the automatic trigger opens a float for. A list of type names, `true` for every type, or `false` for none. Gates the **trigger** only: `:Hover show` answers for every type regardless. See [What opens by itself](#what-opens-by-itself). |
| `trigger` | `{ "CursorHold" }` | `"CursorHold"` follows `'updatetime'` and adds `delay_ms` on top. `"cursor"` is CursorMoved plus this plugin's own debounce — `delay_ms` is then absolute, and nothing fires while the cursor stands still. `"mouse"` also needs `:set mousemoveevent`, which is never set for you. |
| `delay_ms` | `250` | Debounce before the float opens. |
| `filetypes` | `"*"` | `FileType` pattern the hover attaches on. A non-empty `'buftype'` is excluded regardless — a picker, a file tree, a terminal or a dashboard has no document to hover in. |

## What the float looks like

| Option | Default | Meaning |
| --- | --- | --- |
| `max_lines` | `20` | Preview line cap, and the float's max height. |
| `max_width` | `80` | Float width cap, in columns. |
| `border` | `"rounded"` | The frame's look. Every `nvim_open_win` name — `none` `single` `double` `rounded` `solid` `shadow` — plus `heavy` (a thick line), `ascii` (`+-\|`, for a font or terminal without box-drawing characters), `dashed` and `block`, which Neovim has no names for. An eight-character list works too, clockwise from the top-left. A name that does not exist is **reported and ignored** rather than passed on: `nvim_open_win` refuses one, and a hover that never opens again over a typo is a bad way to find out. `:Hover border [style]` changes the float already on screen, so a style can be tried. |
| `inline_images` | `true` | Draw pictures / PDF pages into the float when a provider can. Off degrades an image to its format, dimensions and size as text — which is also what happens with no provider installed. |
| `placeholder_grace_ms` | `250` | How long an async preview may take before a "rendering…" placeholder is allowed to interrupt. Below this, waiting quietly reads as instant; above it, silence reads as breakage. |

## The nine switches

Each of these has a `:Hover` route too, and the route is the way to throw one for the
session — see [commands.md](commands.md). **Implication runs upward only:** `fetch` turns
on `web`, which turns on `links`. Switching `links` *off* silences web links without
clearing their flag, so turning it back on restores what you had.

| Option | Default | Meaning |
| --- | --- | --- |
| `links.enabled` | `true` | Whether link syntax hovers at all. |
| `links.web` | `false` | Whether an http(s) link hovers. Implies `links.enabled`. Off because documentation is made of links: the offline preview shows host, path and query, all of which are already *in* the link. |
| `links.fetch` | `false` | Fetch for status code and title. Implies `links.web`. Off a second time for a reason volume does not cover — it is a disclosure: every link the cursor rests on becomes a request from this machine to that host. |
| `links.timeout_ms` | `2000` | |
| `paths.enabled` | `true` | Whether a path written without link syntax hovers. |
| `paths.missing` | `true` | Whether a bare path resolving to nothing may be marked broken. Deliberately hard to satisfy — this is the only preview class whose value goes *negative* when it is wrong. |
| `paths.code` | `false` | Whether a bare path hovers inside executable code. Off: in a parsed buffer, only comments and strings are searched. Prose is untouched — see [BARE-PATHS.md](FEATURES/BARE-PATHS.md#where-one-is-looked-for). |
| `paths.scope` | `{ prose = {}, code = {} }` | Treesitter capture families this plugin has never heard of, taught to it for one grammar. Almost always right to leave empty: the gate already falls open on anything it does not recognise, so an exotic language gets no gating rather than wrong gating. The `code` side is the footgun — adding a family there can silently switch bare paths off in a language. `:checkhealth hover` reports whatever is set here. |
| `positions` | `true` | Whether a registered *position* preview may open a float — a plugin saying something about where the cursor is, when it points at nothing. Costs nothing with none registered. |
| `office.convert` | `false` | Whether a `.docx`/`.xlsx`/`.pptx`/… is converted to a PDF and shown as a page. Off: converting one means starting LibreOffice, which is seconds rather than milliseconds. |
| `office.timeout_ms` | `60000` | LibreOffice's first start is slow, and a timeout that fires on it looks like a broken feature. |
| `office.cache_days` | `7` | How many days a converted PDF may sit in the cache before the next session sweeps it. Converted PDFs outlive the session — the mtime in their key makes that safe — and this is what keeps the cache from being a directory that only grows. `0` keeps nothing between sessions. |

## Keys

Every entry takes a single key, a list, or `false`/`{}` to bind nothing. All but
`keymaps.show` are **borrowed**: bound globally while a float is on screen, handed back
the moment it closes, restoring whatever mapping they displaced. The reasoning for each
borrow condition is in [BINDINGS.md](BINDINGS.md).

| Option | Default | Bound for |
| --- | --- | --- |
| `keymaps.show` | `false` | Owned, kept. A key for `:Hover show`. No key is claimed unless asked for. |
| `dismiss_keys` | `{ "q", "<Esc>" }` | **every** hover — anything can be waved away, a picture included |
| `open_keys` | `{ "gf" }` | Open what the float is showing — through [open.nvim](https://github.com/StefanBartl/open.nvim) when installed, else `vim.ui.open` |
| `scroll_keys.down` | `{ "<M-PageDown>", "<C-Down>" }` | scrollable hovers only. Two pairs, because a key that is not on the keyboard cannot be pressed |
| `scroll_keys.up` | `{ "<M-PageUp>", "<C-Up>" }` | as above |
| `resize_keys.larger` | `{ "+" }` | a hover with a **picture** only — these are real motions, and displacing one is worth it over a picture and not over every text float |
| `resize_keys.smaller` | `{ "-" }` | as above |
| `resize_keys.wheel_larger` | `{ "<M-ScrollWheelUp>" }` | **any** hover. A wheel points, so these fire only while the pointer is over the float, its border ring included. Needs `'mouse'` to include your mode |
| `resize_keys.wheel_smaller` | `{ "<M-ScrollWheelDown>" }` | as above |
| `zoom_keys.into` | `{ ">" }` | whenever the hover on screen **can** be zoomed. Plain characters since 2026-09-03: the Alt chords they replaced displace nothing, which is worth nothing in a terminal that never sends them |
| `zoom_keys.out` | `{ "\|" }` | as above |
| `zoom_keys.reset` | `{ "=" }` | as above |
| `nav_keys.left` | `{ "h" }` | **only while a hover is zoomed in** — the narrowest borrow here, and the strongest case: unbound, `h` moves the cursor and the dismissal takes the picture away |
| `nav_keys.right` | `{ "l" }` | as above |
| `nav_keys.up` | `{ "k" }` | as above |
| `nav_keys.down` | `{ "j" }` | as above |
| `position_keys.next` | `{ "<M-n>" }` | **position hovers only**, and only where more than one contribution is registered — see [When two plugins answer](#when-two-plugins-answer) |

## Contributions

`contribute` is the one field that is not a setting. It takes exactly the table
`hover.registry.register` takes — `sources`, `previews`, `positions` — so a function in
your own config is a contributor like any other, registered under the name `user`. It
never lands in the options table: functions are not settings. See
[FEATURES/CONTRIBUTIONS.md](FEATURES/CONTRIBUTIONS.md).

---

## Modes

| Mode | What opens a float |
| --- | --- |
| `auto` | the trigger, as configured. The feature as intended. |
| `manual` | nothing, by itself. `:Hover show`, `keymaps.show` and `show({ force = true })` still answer **in full** — web links included. |
| `off` | nothing at all. |

`manual` is the answer to "I am reading a document made of links right now" without
deciding class by class which noise is acceptable.

The state also lives in `vim.g.hover_disable`, which is where you say it from a plugin
spec before anything loads — one setting rather than two that can disagree:

```lua
{ "StefanBartl/hover.nvim", init = function() vim.g.hover_disable = true end }
```

That outranks anything a plugin configures: a host enabling its hover cannot override you
switching the feature off, **including its keymaps**. An explicit request opens every
volume switch but not this one, because a veto a keypress can defeat is not a veto.
`vim.g.loaded_hover = true` goes one step further and suppresses even `:Hover`.

## What opens by itself

`auto_hover` names the target types the automatic trigger opens a float for. The names
are `image`, `pdf`, `office`, `markdown`, `file`, `directory`, `url`, `anchor`, `missing`
and `git`, plus `position` for a plugin answering about the *place* the cursor is in.

```lua
require("hover").setup({
  auto_hover = { "image", "pdf" },        -- the default
  -- auto_hover = { "image", "pdf", "file", "position" },  -- and text files too
  -- auto_hover = true,                   -- everything
  -- auto_hover = false,                  -- nothing; same effect as mode = "manual"
})
```

**This gates the trigger, not the plugin.** That is the whole difference between it and
the switches above: `paths.enabled = false` means a bare path is not a target at all, so
nothing finds it; leaving `file` out of `auto_hover` means it is found and waits for you
to ask. Two consequences worth knowing before you keep the default:

- **Position previews are off with the rest.** documentation.nvim saying what a module is,
  insights.nvim saying who imports it — those answer on `:Hover show` and not on their own.
- **It saves the float, not the work before it.** To know that something is a picture, the
  path still has to be resolved. What you get is quiet, not speed.

## When two plugins answer

More than one plugin can have something to say about one place. On a dotted name two
routinely do: documentation.nvim answers *what this module is*, insights.nvim *who
imports it*. Both are true and they are different sentences, so the answers are a **ring**
rather than a race — `<M-n>` or `:Hover next` steps to the next one, and past the last it
returns to the first. With only one answer it says so, because a key that silently does
nothing is indistinguishable from a broken one. The reasoning is in
[CONTRIBUTIONS.md](FEATURES/CONTRIBUTIONS.md#three-kinds-and-why-the-third-exists).

## The pre-1.0 spellings

Three options are still accepted under their old names and normalized on the way in, so a
host that learned them while this plugin lived inside `lib.nvim` keeps working:
`enabled = false` reads as `mode = "off"`, `bare_paths` as `paths.enabled`, and
`url = { hover, fetch, timeout_ms }` as the `links` fields. Nothing downstream ever sees
the old shape.

`zoom_keys` is **not** among them. It briefly was the old spelling of `resize_keys`,
between the rename and the arrival of a real zoom, and it now configures
[zooming](FEATURES/ZOOM.md) instead. A configuration still using the old shape
(`zoom_keys.larger` / `.smaller`) is reported on startup and ignored rather than quietly
rebound — those entries belong in `resize_keys`.
