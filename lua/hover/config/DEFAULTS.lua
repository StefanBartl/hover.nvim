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
  mode = "auto",

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
  ---@type string|string[] `nvim_open_win` border.
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
  },

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

  -- Bound for *every* hover, not only scrollable ones: anything can be waved
  -- away, including a picture, which has nothing to scroll. The price is
  -- that `q` records no macro for as long as one float is up.
  ---@type string|string[]
  dismiss_keys = { "q", "<Esc>" },

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
