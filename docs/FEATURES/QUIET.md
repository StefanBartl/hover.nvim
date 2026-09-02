# Staying quiet

Why so little of this plugin is on by default, and where the lines were drawn.
For *what* the switches are and how to throw them, see
[the README](../../README.md#what-is-opt-in-and-why); this page is the
reasoning underneath.

## What the complaint actually was

The feature that became this plugin was switched on and immediately produced
too many floats. "Too sensitive" turned out to be **three unrelated causes**,
which matters because fixing the loudest one would have left the other two.

1. **The trigger fires more often than "the cursor moved."** `CursorHold`
   fires after *any* keystroke followed by quiet — cursor movement or not — and
   with `updatetime = 200` plus `delay_ms = 250` that is a float about 450 ms
   after every pause. `trigger = { "cursor" }` exists for exactly this and is
   not the default; see [ROADMAP.md](../ROADMAP.md).

2. **The opt-in line was drawn in the wrong place.** The argument "a document
   is made of links, so links must be opt-in" had only ever been applied to
   `http(s)`. Counted in one real document (lib.nvim's `docs/modules.md`):
   **104 links, of which 2 were http.** The switch silenced two and left the
   other 102 — which were the volume.

3. **The bare-path rule marked prose as broken paths.** Rebuilding the
   heuristic and running it over prose showed what a three-segment rule
   accepts: `2026/09/01`, `github.com/user/repo`, `./components/Button` (every
   extensionless JS import), `TODO/FIXME/DONE`, `read/write/execute`,
   `key/value/pair`, `a/b/c` — each one drawn with a red ✗ as a path that does
   not exist. That class has [its own page](BARE-PATHS.md).

## The model: two axes, not a list of target types

Every default is derived from two questions, and the pair explains all of them:

- **How explicit was the target?** Link syntax means the author *claimed* there
  is something there. A bare path means we are guessing.
- **How much does the preview say that is not already on screen?** A file's
  first lines are not in the link text. A URL's host and path are.

Cost breaks a tie: fetching a page discloses the link to its host and takes a
network round trip, so it is off even where the answer would be worth having.

The value of the model is that it **derives every default that already
existed** and disagrees with exactly two of them — which is what made it worth
adopting rather than an opinion competing with an opinion.

## Three modes, and what outranks what

`auto`, `manual`, `off`. `manual` keeps every preview and gives up only the
automatic trigger, which is the answer to "I am reading a document made of
links *right now*" without deciding class by class.

**An explicit request opens the volume switches, never the mode.** That
distinction was a bug until 2026-09-02: `show()` skipped the mode check
whenever `force` was set, so `mode = "off"` and `vim.g.hover_disable` did not
hold for `:Hover show`, for `keymaps.show`, or for a *host plugin's* keymap —
which is precisely what `vim.g.hover_disable` exists to overrule. Measured
before the fix:

    mode = "off",          show({ force = true })  ->  true
    vim.g.hover_disable,   show({ force = true })  ->  true
    mode = "off",          show()                  ->  false

`:Hover why` meanwhile reported `mode: off` as the reason nothing had appeared,
while `:Hover show` opened a float on the same position — two routes
disagreeing about one switch. Fixed in `3e12c9f`: a veto a keypress can defeat
is not a veto, and "silent by itself, answering in full when asked" already had
a name (`manual`).

## One declaration, and every copy of it that fell behind

`lua/hover/switches.lua` is the single declaration of the switches. Routes,
completion, `:Hover status` and `:checkhealth hover` are all *derived* from it,
so adding a switch is a table entry and nothing else.

That is not tidiness. **Every time something in this repository kept a second,
hand-written copy of a list the source already had, the copy fell behind — and
nothing failed.** No count is given here on purpose: the tally was itself a
hand-kept number and went stale twice before this sentence replaced it.

- `usrcmds.route_path` (`ac50599`) — a new switch landed at the top level
  instead of under its parent.
- `switches.effective` (`144c405`) — a new switch read as permanently on;
  `:Hover status` and `:checkhealth` both lied.
- `preview/office.lua` (`a5531e5`) — a badge advertised a command that no
  longer existed.
- **The documents** (2026-09-02) — the vimdoc listed seven of the nine switch
  names, `docs/INTEGRATIONS.md` carried four hand-counted numbers that were all
  stale, and `docs/ROADMAP.md` said "four of the candidates are built" with
  five. One step worse than the code ones: in code a spec eventually trips over
  it, in a document nobody does.
- `init.scroll` (`9fba190`) — it assembled its own `preview_opts` and therefore
  knew nothing about the resize level, so paging a resized hover snapped it
  back to the configured size. Now one `current_preview_opts()`.
- `config.replace_key_lists` (`efafb82`) — a literal list of the key tables to
  replace, under a doc comment claiming it was "declared rather than written
  out". A configured `zoom_keys.into` would have merged *alongside* the default
  and bound both. It now reads every `DEFAULTS` entry whose name ends in
  `_keys`.
- `switches_spec` (`efafb82`) — a second hand-written list of the routes'
  argument values, already shorter than the one `docs_spec` had. Both now
  derive it from the routes' own `args[].enum`.

The code ones are derived now, and the specs against them are written over
`switches.names()` rather than over a list, so a tenth switch is covered from
its declaration. The documents are why `TESTS/docs_spec.lua` exists: every
claim a document makes that the source can be asked about is now asked, in both
directions.

**The pattern is worth more than the list.** Two of these were found by a
measurement that was after something else, one by a LuaLS scan, one by a
reader, and none by a failing test — because a copy that has fallen behind is
still valid code and still valid prose. When a bug here does not fit any other
shape, look for a second copy of a list first.
