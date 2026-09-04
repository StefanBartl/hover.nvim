---@module 'hover.config.DEFAULTS'
---@brief Plugin-side defaults for hover.nvim.
---@description
--- Data only. Nothing here reads the editor, calls an API, or depends on
--- another module -- `hover.config` deep-copies this table and merges the
--- user's options over it, and every runtime switch mutates the *merged*
--- copy rather than this one.
---
--- **The two axes these defaults are chosen along.** A float that opens
--- unasked is only welcome when both hold:
---
---  1. **How explicit is the target?** Link syntax is the author stating
---     "this points somewhere". A bare path in prose is this plugin
---     guessing.
---  2. **How much does the preview add that is not already on screen?** A
---     file's first lines cannot be read off the link text. A URL's host and
---     path can -- they *are* the link text.
---
--- Cost is the tie-breaker where an answer is expensive to produce: a
--- network round trip, or a LibreOffice start.
---
--- Run through the table, that yields exactly these defaults: local links on
--- (explicit, high added value, free), web links off (explicit, but the
--- offline preview restates the link), fetching off (a disclosure), office
--- conversion off (seconds per document), bare paths on (free and high
--- value) -- and the "no such file" marker on, but only for text that cannot
--- have been anything else.
---
---@see hover.config

---@type Hover.Config
return {
  -- "auto" is the feature as it is meant to be used; "manual" keeps every
  -- preview and gives up only the automatic trigger, which is the answer to
  -- "I am reading a document made of links right now". See `hover.mode`.
  --
  -- `mode` says *whether* the trigger asks; `auto_hover` below says *what
  -- for*. The two were one setting until 2026-09-03, and the reason they are
  -- two is that they answer different questions -- one is a switch for right
  -- now, the other a standing preference.
  mode = "auto",

  --- Which target types the automatic trigger opens a float for.
  ---
  --- **The third axis, and the one the other two could not express.** The
  --- switches below are organised by where a target was *found* -- link
  --- syntax, bare prose, a plugin answering for a position. This one is
  --- organised by what the target turned out to *be*, and the two cross: a
  --- markdown link can point at a picture or at a text file, so "pictures
  --- only, however they were written" was not sayable before this existed.
  ---
  --- **Why pictures and PDFs are the default, and everything else is not.**
  --- A picture or a rendered page is the only thing this plugin shows that
  --- cannot be read off the line the cursor is on. The first lines of a text
  --- file are a shortcut -- useful, but a shortcut for something you could
  --- also just open, and the float lands over the paragraph you were reading
  --- to give it to you. The value per interruption is very unevenly spread
  --- across the types, and this is the axis it is spread along.
  ---
  --- Three shapes, all meaning the same thing to the code:
  ---
  ---   * a list of type names -- `{ "image", "pdf" }`, the default
  ---   * `true`  -- every type, which is what this plugin did before
  ---   * `false` -- none, identical in effect to `mode = "manual"`
  ---
  --- **It gates the automatic trigger only.** `:Hover show` (and any keymap
  --- bound to it) answers for every type regardless -- that is the difference
  --- between this and `paths.enabled`, which decides whether a bare path is a
  --- target *at all*. Turn `paths` off and nothing finds it; leave `file` out
  --- of this list and it is found, and waits to be asked for.
  ---
  --- Type names are `Hover.Target.type` plus `"position"` for a registered
  --- position preview. `:Hover auto` lists them with their current state.
  ---
  --- **Written out as a full table here rather than as the short list**, even
  --- though the list is what a user writes. Every key present means a user's
  --- partial table (`auto_hover = { file = true }`) merges the way every other
  --- option does — additively, one key changed — while a *list* replaces the
  --- whole setting, which is what a list should mean. `config.normalize`
  --- turns the list form into this one. `TESTS/switches_spec.lua` holds the
  --- keys against `classify.TYPES`, so a new target type cannot arrive here
  --- silently disabled.
  ---@type table<string, boolean>|boolean|string[]
  auto_hover = {
    -- The two that are worth an interruption without being asked.
    image = true,
    pdf = true,

    anchor = false,
    directory = false,
    file = false,
    git = false,
    markdown = false,
    missing = false,
    office = false,
    url = false,

    -- A plugin answering for the *place* the cursor is in rather than for a
    -- target: what this module is, who imports it, what this container image
    -- would run. Off by default with the rest, and the one entry whose
    -- default is a genuine trade rather than an obvious one -- nothing
    -- registers a position preview by accident, so `position = true` is
    -- defensible. It is off because "install it, and pictures open" is a
    -- promise that stays true on a machine with seven contributors
    -- installed, and `:Hover auto position` is one command.
    position = false,
  },

  -- "CursorHold" follows 'updatetime', a global usually set for something
  -- else entirely (gitsigns' blame, a statusline). It also fires after any
  -- keystroke followed by quiet -- cursor movement or not. "cursor" is
  -- CursorMoved plus this plugin's own debounce: `delay_ms` then means what
  -- it says, and nothing fires while the cursor stands still.
  --
  -- "mouse" additionally needs `:set mousemoveevent`, which is a global user
  -- setting and is never set on the user's behalf.
  trigger = { "CursorHold" },

  ---@type integer Debounce before the float opens, in ms. Added to 'updatetime' under the "CursorHold" trigger; absolute under "cursor".
  delay_ms = 250,

  -- How long an async preview may take before it is allowed to interrupt
  -- with a "rendering..." placeholder. Below this, waiting quietly and
  -- showing only the result reads as instant; above it, silence reads as
  -- breakage. Configurable because "instant" is a property of the machine.
  ---@type integer
  placeholder_grace_ms = 250,

  ---@type integer Preview line cap, and the float's maximum height.
  max_lines = 20,
  ---@type integer Float width cap, in display columns.
  max_width = 80,
  --- The frame's look. Every name `nvim_open_win` knows -- `none`, `single`,
  --- `double`, `rounded`, `solid`, `shadow` -- plus four this plugin adds
  --- because Neovim has no name for them: `heavy` (a thick line), `ascii`
  --- (`+-|`, for a font or terminal without box-drawing characters), `dashed`
  --- and `block`. An eight-character list still works and is the escape hatch
  --- for anything not listed.
  ---
  --- `:Hover border [style]` changes the float that is already on screen, so a
  --- style can be tried rather than decided. See `hover.float`.
  ---@type string|string[]
  border = "rounded",

  -- Draw pictures and rasterized PDF pages into the float when a provider
  -- can. Off degrades an image to its format, dimensions and size as text --
  -- which is also what happens with no provider installed.
  ---@type boolean
  inline_images = true,

  -- Buffers the hover attaches to. Anything with a non-empty 'buftype' (a
  -- picker, a file tree, a terminal, a dashboard) is excluded regardless --
  -- see `hover.bindings.autocmds`.
  ---@type string|string[]
  filetypes = "*",

  --- Targets written with link syntax, found by a registered source
  --- (markdown.nvim contributes one).
  links = {
    -- On: an author who wrote `[text](./doc.md)` said that path is worth
    -- following, and the float shows what the link text cannot.
    ---@type boolean
    enabled = true,

    -- Off: the offline URL preview shows host, path and decoded query --
    -- all of which are already in the link. Documentation is made of links,
    -- so on-by-default turns reading a README into a slideshow, and the
    -- float lands over the paragraph being read. `:Hover links web on` is
    -- the reader saying "for the next while, links are the interesting
    -- thing". Nothing leaves the machine at this level.
    ---@type boolean
    web = false,

    -- Off, on top of `web`, for a reason volume does not cover: every link
    -- the cursor rests on becomes a request from this machine to that host,
    -- and a page with fifty links becomes a request storm while scrolling.
    -- On, the float leads with the status line -- "is this link still
    -- alive" is the question a link hover is actually asked.
    ---@type boolean
    fetch = false,

    ---@type integer
    timeout_ms = 2000,

    --- The page itself, rendered by a headless browser and drawn into the
    --- float like any other picture.
    ---
    --- **A different category from `fetch`, not a louder setting of it, and
    --- that is why it implies `web` rather than `fetch`.** A fetch is one
    --- `curl` GET with a 2 MB cap and no JavaScript. A screenshot *executes*
    --- the page: the site's own scripts run, and every subresource it asks
    --- for -- fonts, analytics, third-party frames -- is fetched from
    --- whatever host it names. Turning `fetch` on must never imply this, and
    --- the announcement says so out loud.
    ---
    --- **The browser is given a throwaway profile.** Without
    --- `--user-data-dir` a headless Chrome can reuse the real one, which
    --- would send the reader's cookies to the hovered host and render logged
    --- in content into the picture. See `hover.preview.shot`.
    shot = {
      -- Off, for the category above. `:Hover links web shot`.
      ---@type boolean
      enabled = false,

      -- Off a second time, and the second switch exists because the two
      -- questions have different answers. `enabled` is "may a link be
      -- rendered at all"; this is "may the *trigger* do it", and the trigger
      -- is the expensive half: a document with fifty links, scrolled
      -- through, is fifty browser starts.
      --
      -- `auto_hover.url` cannot say this. Text preview and screenshot are the
      -- same target type, so "text automatically, a picture only when asked"
      -- has no spelling on that axis. `:Hover links web shot eager`.
      ---@type boolean
      eager = false,

      -- Measured 2026-09-04 on this machine: a browser start alone is
      -- **710-735 ms** (three runs, `about:blank`, no network), and a real
      -- documentation page took 3.9 s to 19.6 s -- the same URL, twice, at
      -- both ends of that. So the timeout is generous for the same reason
      -- `office.timeout_ms` is: one that fires on a slow page looks like a
      -- broken feature rather than a slow one.
      ---@type integer
      timeout_ms = 20000,

      -- The viewport the page is laid out in, and what is captured.
      --
      -- **900 rather than a full-page 4000, and that is a legibility
      -- measurement rather than a preference.** A picture is letterboxed into
      -- the float, so what decides whether it can be read is the fit factor.
      -- On a 210x55 terminal a zen float is roughly 1850x970 px: a 1280x900
      -- capture fits at about 1.0 and 16 px body text stays 16 px, while a
      -- 1280x4000 one is height-limited to 0.24 and the same text becomes
      -- 4 px. Raise it for a whole-page capture and read it with `>` -- the
      -- zoom crops, so a tall picture is exactly what it is for.
      ---@type integer
      width = 1280,
      ---@type integer
      height = 900,

      -- How long a rendered page may sit in the cache before the next session
      -- sweeps it, exactly as `office.cache_days`. Keyed by URL and geometry
      -- rather than by a file's mtime, so a page that has since changed still
      -- answers with the old picture until this expires -- `0` keeps nothing
      -- between sessions, and `:Hover links web shot` off and on again drops
      -- the session's own table.
      ---@type integer
      cache_days = 7,

      -- Stillness required before the trigger is allowed to start a browser,
      -- on top of `delay_ms`.
      --
      -- **Its own number because `delay_ms = 250` is the wrong order of
      -- magnitude to protect anything that costs seconds.** A quarter second
      -- of quiet is what a *free* preview should wait for; hanging 0.7 s of
      -- process start plus up to 20 s of page behind it means scrolling
      -- through a page of links starts a browser for each one it pauses over.
      -- Only the automatic path waits: `:Hover show` is a decision already
      -- made, and making a reader wait a second to confirm it would be an
      -- apology for the wrong thing.
      ---@type integer
      delay_ms = 1000,

      -- The browser to run. Unset means "find one": every usual name on
      -- PATH, then the usual install locations, in a fixed order that
      -- prefers Chrome and Chromium over Edge.
      --
      -- **The path search is not a convenience.** Measured on this machine
      -- 2026-09-04: Chrome is installed and `chrome` is on no PATH at all --
      -- the Windows installer does not extend it, which is the same problem
      -- `soffice` already documents in `docs/install.json`.
      ---@type string|nil
      command = nil,
    },
  },

  --- Targets with no link syntax at all: a path in prose, in a code comment,
  --- in a `:messages` dump.
  paths = {
    -- On: free, and the highest-value preview there is -- the file's own
    -- first lines. A bare path must resolve to something real, so an
    -- ordinary word never opens a float.
    ---@type boolean
    enabled = true,

    -- Whether text that resolves to nothing may be reported as broken, with
    -- a red marker. On, but deliberately hard to satisfy: see
    -- `hover.bare_path.is_unambiguous_path`. This is the only preview class
    -- whose value goes *negative* when it is wrong -- a red cross on prose
    -- is worse than silence -- so the evidence bar is set higher than
    -- anywhere else here.
    ---@type boolean
    missing = true,

    -- Whether a path may also be found in executable code, rather than only
    -- in the comments and strings of a source file. Off: in a parsed buffer
    -- a position Treesitter identifies as code is skipped before the
    -- resolver ever runs. This is the half of the bare-path noise that no
    -- rule about the *text* can remove -- `vim.api.foo` and `a / b` are not
    -- textually different from a path, only positionally.
    --
    -- It costs nothing in prose: a buffer with no parser, a position with no
    -- captures, and a capture family this plugin does not recognise are all
    -- allowed through, so `.txt`, logs, `:messages` and ordinary markdown
    -- paragraphs are untouched. See `hover.scope`.
    ---@type boolean
    code = false,

    -- Capture families this plugin has never heard of, taught to it for one
    -- grammar. Empty, and almost always right to leave that way: the gate
    -- already falls open on anything it does not recognise, so an exotic
    -- language gets no gating rather than wrong gating.
    --
    -- `prose` widens what counts as a place a path may be written; `code`
    -- narrows it. They are not symmetric in risk and the code side is the
    -- footgun: adding a family there can silently switch the feature off in
    -- a language, which is the exact failure the fail-open design exists to
    -- prevent. `:checkhealth hover` reports whatever is configured here, so
    -- it is at least findable.
    ---@type { prose?: string[], code?: string[] }
    scope = { prose = {}, code = {} },
  },

  --- Whether a registered *position* preview may open a float: a plugin
  --- saying something about where the cursor is, when it points at nothing.
  --- A deprecated call on this line, how often this token occurs, what this
  --- module does.
  ---
  --- On, and that is a judgement about who is asking rather than about the
  --- class. Nothing registers one of these by accident: a plugin author has
  --- already decided this position is worth interrupting a reader for, which
  --- is the same trust the `sources` registry has always extended. The switch
  --- exists for where that trust turns out to be misplaced -- a contributor
  --- that answers for every token in a log is exactly the noise this
  --- plugin's opt-in model is otherwise built to prevent, and one command
  --- has to be able to stop it.
  ---
  --- With nothing registered this costs nothing: the trigger is not even
  --- installed unless something could answer.
  ---@type boolean
  positions = true,

  --- Office documents (`.docx`, `.xlsx`, `.pptx`, `.odt`, and the legacy
  --- binary formats).
  office = {
    -- Off: converting one means starting LibreOffice, which is seconds, not
    -- milliseconds. Off, an office document gets a badge saying what it is
    -- and how big; on, its first page rendered, paged like any PDF.
    ---@type boolean
    convert = false,
    -- LibreOffice's first start is slow, and a timeout that fires on it
    -- looks like a broken feature rather than a slow one.
    ---@type integer
    timeout_ms = 60000,

    -- How many days a converted PDF may sit in the cache before the next
    -- session sweeps it. Converted PDFs outlive the session -- the mtime in
    -- their key makes that safe -- and this is what keeps that from being a
    -- directory that only grows. `0` keeps nothing between sessions, which is
    -- how this behaved before the cache was allowed to survive.
    ---@type integer
    cache_days = 7,
  },

  --- The float on (almost) the whole editor, and back again.
  ---
  --- **Zen is not "make the window bigger", and that distinction is the whole
  --- feature.** Every previewer renders against a budget: `max_lines` and
  --- `max_width` decide how many lines are read, at what DPI a PDF page is
  --- rasterized, and how large a picture is drawn. A float that merely opened
  --- larger would show the same twenty lines with a great deal of margin. So
  --- the budget itself becomes the screen, and the preview is built again
  --- against it -- which is exactly what `resize` already does, with a factor
  --- where this has a destination.
  ---
  --- It applies to every preview type rather than to pictures alone, and the
  --- answers differ the same way `resize`'s do: a picture and a PDF page are
  --- drawn larger, a text preview shows *more lines*.
  ---
  --- `:Hover zen`, and `F` while a float is up.
  zen = {
    -- **On, and this is the one setting here whose default follows from a
    -- mechanism rather than from taste.** The float is `focusable = false`,
    -- so it never receives a keystroke, and the dismissal hangs on
    -- `CursorMoved` -- which means every key that is not borrowed moves the
    -- cursor in the document underneath and takes the float away. For a
    -- twenty-line preview that is correct and is the point. For a float
    -- filling the screen it means the thing closes on the first `j`, and
    -- nobody wants a full-screen preview for the length of one keystroke.
    --
    -- `false` is for the reader who wants exactly that: zen opens, and the
    -- next move closes it. `:Hover pin` is then still one command away.
    --
    -- Leaving zen releases the pin again -- but only when zen was what took
    -- it. A float pinned before zen stays pinned after it, because that pin
    -- was the reader's and not this setting's.
    ---@type boolean
    pin = true,
  },

  --- Keys borrowed globally while a hover is on screen, and handed back --
  --- restoring whatever they shadowed -- the moment it closes. The float is
  --- `focusable = false`, so it can never hold a mapping of its own.
  ---
  --- A configured list *replaces* the default rather than extending it; an
  --- empty list binds nothing.
  scroll_keys = {
    -- Two pairs, because a key that is not on the keyboard cannot be
    -- pressed: laptop and 60% layouts often reach PageUp/PageDown only
    -- through an Fn chord, and nothing at runtime can tell whether this
    -- keyboard has them. The arrows are on every keyboard there is. Ctrl
    -- rather than Alt on them: <M-Up>/<M-Down> is a widespread "move this
    -- line" binding, and the borrowing is only meant to last as long as the
    -- float.
    ---@type string|string[]
    down = { "<M-PageDown>", "<C-Down>" },
    ---@type string|string[]
    up = { "<M-PageUp>", "<C-Up>" },
  },

  --- The hover on screen, larger or smaller. One step multiplies the box the
  --- previewer is given -- `max_width` and `max_lines` -- by 1.25.
  ---
  --- **Two honest answers to one operation.** A picture is drawn larger; a
  --- text preview shows *more lines*, because the font size belongs to the
  --- terminal emulator and Neovim cannot change it. That is why this is
  --- `resize` and not `zoom`: only one of the two is magnification, and a
  --- real zoom -- a cropped detail that can be moved around -- is a different
  --- feature, which is built and configured by `zoom_keys` below
  --- (`docs/FEATURES/ZOOM.md`).
  ---
  --- **`larger` / `smaller` are bound only for a *drawn* hover.** They are
  --- real motions in normal mode, and displacing them is worth it over a
  --- picture and not over every float that happens to be up. The wheel below
  --- and `:Hover resize` apply to any hover; neither costs anyone a key.
  ---
  --- One key per direction, not two. The scroll keys are doubled because a
  --- key that is not on the keyboard cannot be pressed -- laptop and 60%
  --- layouts reach PageUp/PageDown only through an Fn chord -- and that
  --- argument does not carry here: `+` and `-` are on every keyboard there
  --- is. `=` was considered as an unshifted stand-in for `+` on a US layout
  --- and left alone: it is the indent operator, and borrowing an operator
  --- buys convenience nobody asked for.
  ---
  --- **The wheel is the other half, and it obeys a different rule.** `+`
  --- acts on the one float there is, wherever the pointer happens to be. A
  --- wheel *points*, so it acts on what it points at: these two fire only
  --- while the pointer is over the float, its border ring included.
  ---
  --- Alt rather than Ctrl. `<C-ScrollWheel>` is the terminal emulator's own
  --- zoom nearly everywhere -- WezTerm does not take it here, but the
  --- expectation is set, and a plugin that borrows it would be wrong on the
  --- next machine. Alt collides with nothing measured on this one.
  ---
  --- Needs `'mouse'` to include the mode: with it empty no wheel event
  --- reaches Neovim at all, and the mapping is inert rather than broken.
  --- `:checkhealth hover` says so, because the two look identical.
  resize_keys = {
    ---@type string|string[]
    larger = { "+" },
    ---@type string|string[]
    smaller = { "-" },
    ---@type string|string[]
    wheel_larger = { "<M-ScrollWheelUp>" },
    ---@type string|string[]
    wheel_smaller = { "<M-ScrollWheelDown>" },
  },

  -- Bound for *every* hover, not only scrollable ones: anything can be waved
  -- away, including a picture, which has nothing to scroll. The price is
  -- that `q` records no macro for as long as one float is up.
  ---@type string|string[]
  dismiss_keys = { "q", "<Esc>" },

  -- Open what the float is showing -- through open.nvim when it is
  -- installed, else `vim.ui.open`.
  --
  -- `gf` because it already means "open what is under the cursor" in
  -- Neovim's own vocabulary, and while a preview float is up that reading is
  -- exact rather than approximate. Borrowed like every other key here: bound
  -- only while a float is on screen, and the mapping it displaced is
  -- restored rather than deleted, so `gf` means what it always meant the
  -- moment the float closes.
  --
  -- `{}` binds nothing, for anyone who wants the API without the key.
  ---@type string|string[]
  open_keys = { "gf" },

  --- Move the magnified view, borrowed ONLY while a hover is zoomed in.
  ---
  --- The narrowest borrow condition in this plugin, and the one with the
  --- strongest case. These are motions, like `+` and `-` -- but unlike those,
  --- the thing they would otherwise do is *destroy the float*: the dismissal
  --- hangs on `CursorMoved`, so pressing `h` over a magnified picture without
  --- this binding moves the cursor and takes the picture away. Nobody means
  --- that. The moment the hover is not zoomed they are handed straight back.
  ---
  --- Called `nav` rather than `pan` since `9fba190`'s successor: the route it
  --- belongs to reads `:Hover nav left`, and one word for one operation is
  --- worth more here than the more precise term. `pan` was one day old and is
  --- gone rather than aliased -- an alias for a renamed operation is exactly
  --- what produced the `zoom`/`resize` collision this repository just paid
  --- for.
  nav_keys = {
    ---@type string|string[]
    left = { "h" },
    ---@type string|string[]
    right = { "l" },
    ---@type string|string[]
    up = { "k" },
    ---@type string|string[]
    down = { "j" },
  },

  --- Step to the next plugin with something to say about this place.
  ---
  --- Borrowed only for a *position* hover, and only where more than one
  --- contribution is registered at all. Several plugins routinely answer for
  --- one place -- a dotted name is both "what is this module" and "who
  --- imports it" -- and until this key existed the first registered one won
  --- and the rest were invisible, decided by plugin load order.
  ---
  --- Alt, and it is now the only Alt chord this plugin binds a keyboard
  --- key to -- the zoom keys gave theirs up on 2026-09-03 because a
  --- terminal that does not send the chord makes it an absent key rather
  --- than a cheap one. This one keeps it because the alternative would be
  --- a plain key bound for *position* hovers, where nothing about the
  --- content narrows the borrow; `:Hover next` is the route for anyone
  --- whose terminal is in the same position.
  --- `n` was never a candidate -- it is search-next, and borrowing it for a
  --- float would be the worst trade in this file. Checked against this
  --- config's own cheatsheets and source before choosing: `<M-n>` is unused
  --- in both.
  position_keys = {
    ---@type string|string[]
    next = { "<M-n>" },
  },

  --- Zoom the picture on screen, borrowed while the hover *can* be zoomed.
  ---
  --- **These exist now and deliberately did not before, and what changed is
  --- the price of the *key*, never the price of the step.** A zoom step costs
  --- about a quarter of a second (measured: 258 ms, see `hover.zoom`), which
  --- is the wrong shape for a key that is held down -- and the only keys on
  --- the table at the time were `+` and `-`, real motions already spoken for
  --- by `resize_keys`. The objection was never "zooming is not worth a key".
  ---
  --- **The default was `<M-z>` / `<M-Z>` / `<M-R>` until 2026-09-03, and a
  --- measurement took it away.** An Alt chord displaces nothing -- which is
  --- worth exactly as much as the terminal's willingness to send it. On the
  --- machine this plugin is developed on it sends none:
  --- `:nnoremap <M-z> <Cmd>echo "..."<CR>` prints on no press, because what
  --- arrives is `<Esc>` followed by `z`. A key that displaces nothing *and
  --- does nothing* is not a cheap key, it is an absent one, and "the terminal
  --- sends Alt" was an assumption wearing an argument's clothes. The chords
  --- remain the right choice where they arrive, and that is a config away.
  --- Checked by hand; a terminal is the only thing that can answer it.
  ---
  --- **So the default is three plain characters that arrive everywhere**, and
  --- the three are not chosen on one argument but on two:
  ---
  ---  * `>` and `=` are **operators**. Pressing one over a float does not
  ---    move the cursor and does not complete on its own, so the borrow costs
  ---    a reader nothing for as long as it lasts -- which is exactly as long
  ---    as the float.
  ---  * `|` is a **motion**, and that is the argument *for* taking it rather
  ---    than against. Unbound it jumps the cursor to column one, the
  ---    dismissal hangs on `CursorMoved`, and so the press takes the picture
  ---    away. Nobody means that at a magnified picture -- the same case
  ---    `nav_keys` makes for `h`.
  ---
  --- **Two candidates were rejected, and neither for taste.** `<` was the
  --- first pick for `out`: which-key normalizes it to `<lt>` (`Util.norm`,
  --- measured 2026-09-03) while the mapping stays `<`, and the disagreement
  --- re-enters which-key until its own guard reports "Recursion detected".
  --- `|`, `_`, `>` and `=` all normalize to themselves. And `-`, the obvious
  --- partner for a `_`, cannot work at all: `resize_keys.smaller` holds it,
  --- `borrow` takes the resize keys first, a key taken twice is taken once --
  --- and every hover a zoom key is bound for has a picture in it, so the
  --- overlap is total rather than occasional. `:checkhealth hover` reports it
  --- instead of leaving it to be discovered as a key that resizes.
  ---
  --- **`into`, not `in`.** `in` is a Lua keyword, so the field could only be
  --- written `["in"]` -- here and in every user's config. The route argument
  --- is still `:Hover zoom in`, where no such rule applies.
  ---
  --- All three are bound on "this hover can be zoomed" rather than on "is
  --- zoomed": `out` and `reset` decline at level 0 anyway, and the narrower
  --- condition would buy nothing while making the pair appear only after a
  --- successful `>`. That is the opposite trade from `nav_keys`, and for the
  --- opposite reason -- there, the key is a motion the whole time.
  zoom_keys = {
    ---@type string|string[]
    into = { ">" },
    ---@type string|string[]
    out = { "|" },
    ---@type string|string[]
    reset = { "=" },
  },

  --- Full screen and back, borrowed for *any* hover on screen.
  ---
  --- **Bound for every hover rather than for a drawn one**, which is the
  --- opposite of `resize_keys.larger`. That pair is narrowed because `+` and
  --- `-` are real motions and taking them over a text float is not worth it;
  --- this key costs nothing to hold (see below), and a text preview is
  --- precisely where the extra room buys the most -- twenty lines becomes
  --- fifty.
  ---
  --- **`F`, and it is chosen on the same rule `>` and `=` were.** `F` is
  --- find-character-backwards: pressed on its own it waits for a second
  --- character and does nothing until one arrives, so borrowing it displaces
  --- no completed operation for as long as the float lasts. It is a plain
  --- character, which after 2026-09-03 is a requirement rather than a
  --- preference -- an Alt chord is worth exactly as much as the terminal's
  --- willingness to send it, and the machine this is developed on sends none
  --- Checked by hand, since only a terminal can answer it.
  ---
  --- `z` was the obvious mnemonic and cannot be taken: it is a *prefix*, so
  --- borrowing it would swallow `zz`, `zt`, `zb` and every fold command for
  --- as long as a float is up -- and unlike a displaced key, a broken prefix
  --- does not announce itself, it just hangs waiting for a second character
  --- that now means something else.
  zen_keys = {
    ---@type string|string[]
    toggle = { "F" },
  },

  --- Keymaps this plugin sets in the user's namespace. Every entry is a
  --- single key, a list of keys, or `false` for "bind nothing".
  ---
  --- `show` defaults to `false` on purpose: a plugin that is a dependency of
  --- other plugins has no business claiming a key on their behalf, and
  --- `:Hover show` covers the same ground. It is the one worth setting in
  --- `mode = "manual"`, where nothing opens a float without being asked --
  --- `:checkhealth hover` says so when that combination is configured.
  keymaps = {
    ---@type string|string[]|false
    show = false,
  },
}
