---@meta
---@module 'hover.@types'
---@brief Type contracts for the hover framework.
---@description
--- Every type this plugin declares lives under the `Hover.` namespace.
--- That is not decoration: LuaLS resolves an alias by name, globally, so a
--- one-word type name (`Config`, `Target`, `Source`) belongs to nobody and
--- collides with the first plugin that declares its own (`LLS-22`).
---
--- The `Hover.Source` shape is deliberately loose: a registered source
--- returns a raw target string and the framework builds the record, so a
--- contributing plugin never has to construct one field by field.
---
--- Grouped by the file each block describes.

-- #####################################################################
-- config/DEFAULTS.lua, config/init.lua

--- What may open a float, and when.
---@alias Hover.Mode
---| '"auto"'   # A trigger opens the float on its own. The feature as intended.
---| '"manual"' # Nothing opens by itself; `show({ force = true })`, `:Hover show` and the `keymaps.show` key still answer in full, web links included.
---| '"off"'    # Nothing opens at all, by any route except an explicit `force`.

--- What wakes the hover in "auto" mode.
---@alias Hover.Trigger
---| '"CursorHold"' # Follows 'updatetime', then `delay_ms` on top of it.
---| '"cursor"'     # CursorMoved plus this plugin's own debounce: `delay_ms` is then absolute, and nothing fires while the cursor stands still.
---| '"mouse"'      # Needs `:set mousemoveevent`; never set on the user's behalf.

---@class Hover.Config
---@field mode? Hover.Mode # Default "auto".
---@field trigger? Hover.Trigger[] # Default `{ "CursorHold" }`.
---@field delay_ms? integer # Debounce before the float opens. Default 250.
---@field placeholder_grace_ms? integer # How long an async preview may take before a "rendering..." placeholder is shown. Default 250.
---@field max_lines? integer # Preview line cap (also the float's max height). Default 20.
---@field max_width? integer # Float width cap, in display columns. Default 80.
---@field border? string|string[] # `nvim_open_win` border. Default "rounded".
---@field inline_images? boolean # Draw images / rasterized PDF pages into the float when a provider can. Default true.
---@field filetypes? string|string[] # `FileType` pattern the hover attaches on. Default "*".
---@field links? Hover.LinksConfig
---@field positions? boolean # Whether a registered position preview may open a float. Default true.
---@field paths? Hover.PathsConfig
---@field office? Hover.OfficeConfig
---@field scroll_keys? Hover.ScrollKeys
---@field dismiss_keys? string|string[] # Keys that wave the hover on screen away. Default `{ "q", "<Esc>" }`; a configured list replaces the default, and an empty one binds nothing.
---@field keymaps? Hover.Keymaps
---@field enabled? boolean # Legacy. `false` is read as `mode = "off"` and then dropped.
---@field bare_paths? boolean # Legacy. Read as `paths.enabled` and then dropped.
---@field url? Hover.LegacyUrlConfig # Legacy. Folded into `links` and then dropped.

--- Targets written with link syntax, found by a registered source.
---@class Hover.LinksConfig
---@field enabled? boolean # Whether link targets hover at all. Default true.
---@field web? boolean # Whether an http(s) target hovers. Default false: the offline preview restates what the link already says, and documentation is made of links. Implies `enabled`.
---@field fetch? boolean # Fetch the page for its status code, title and description. Default false: a hover that silently fetches discloses every link brushed past to its host. Implies `web`.
---@field timeout_ms? integer # Fetch timeout. Default 2000.

--- Targets with no link syntax at all.
---@class Hover.PathsConfig
---@field enabled? boolean # Whether a path written in prose hovers. Default true.
---@field missing? boolean # Whether text that resolves to nothing may be marked broken. Default true, and gated behind `hover.bare_path.is_unambiguous_path`.
---@field code? boolean # Whether a path may be found in executable code, not just a source file's comments and strings. Default false; see `hover.scope`.
---@field scope? Hover.ScopeFamilies # Capture families taught to the position gate for one grammar. Both lists empty by default.

--- Office documents (`.docx`, `.xlsx`, `.pptx`, `.odt`, the legacy binary
--- formats). Off means a badge saying what the file is; on means
--- `pdfport.nvim` converts it to a PDF and the page is drawn like any other
--- picture -- a LibreOffice start per document, which is why it is opt-in.
--- Capture families added to `hover.scope`'s built-in sets. `prose` widens
--- what counts as a place a path may be written; `code` narrows it. Only the
--- second can turn the feature off in a language, which is why
--- `:checkhealth hover` reports what is configured here.
---@class Hover.ScopeFamilies
---@field prose? string[] # Treated as prose, alongside `@comment`, `@string`, `@markup`.
---@field code? string[] # Treated as executable code, alongside `@variable`, `@operator`.

---@class Hover.OfficeConfig
---@field convert? boolean # Default false. `:Hover office on`.
---@field timeout_ms? integer # How long the conversion may take. Default 60000 -- LibreOffice's first start is slow.
---@field cache_days? integer # How long a converted PDF may survive between sessions. Default 7; 0 keeps nothing.

--- The pre-`links` spelling of the web switches, still accepted on input.
---@class Hover.LegacyUrlConfig
---@field hover? boolean # Read as `links.web`.
---@field fetch? boolean # Read as `links.fetch`.
---@field timeout_ms? integer # Read as `links.timeout_ms`.

--- Keys bound globally while a scrollable hover is on screen, and unbound
--- (restoring whatever they shadowed) the moment it closes. Each direction
--- takes a single key or a list; a configured list replaces the default
--- rather than extending it, and an empty list binds nothing.
---@class Hover.ScrollKeys
---@field down? string|string[] # Default `{ "<M-PageDown>", "<C-Down>" }` -- the second pair for keyboards with no PageUp/PageDown.
---@field up? string|string[] # Default `{ "<M-PageUp>", "<C-Up>" }`.

--- Keymaps this plugin sets in the user's own namespace, each disableable on
--- its own with `false`.
---@class Hover.Keymaps
---@field show? string|string[]|false # Show the hover for whatever is under the cursor, ignoring every volume switch. Default false: no key is claimed unless asked for.

-- #####################################################################
-- init.lua, bindings/keymaps.lua

--- One key hover.nvim currently holds, with the mapping it displaced.
--- Covers both the scroll keys and the dismiss keys: they are borrowed and
--- returned by the same mechanism, and differ only in when they are bound.
---@class Hover.BoundKey
---@field lhs string
---@field saved? table # `maparg(..., true)` dict of the mapping that was there, restored on unbind.

--- What the currently open hover is showing, so it can be re-rendered at a
--- different position without re-resolving the cursor. Cleared on close.
--- What the open float is showing. Two shapes, told apart by `target`:
--- a target hover carries one and can be re-rendered at another offset or
--- page, a position hover carries `position` instead and cannot -- its
--- content was produced once, by the plugin that answered.
---@class Hover.Open
---@field target? Hover.Target # Absent for a position preview.
---@field position? string # Dismissal identity of a position preview. Absent for a target.
---@field bufnr integer
---@field row? integer # Cursor row a position preview answered for.
---@field offset? integer # Lines skipped, for a text preview.
---@field page? integer # 1-based page, for a PDF preview.
---@field keys? Hover.BoundKey[] # Keys borrowed for as long as this float is up.

-- #####################################################################
-- classify.lua

--- What a target turned out to be.
---@class Hover.Target
---@field type "image"|"pdf"|"office"|"markdown"|"file"|"directory"|"url"|"anchor"|"missing"
---@field raw string # The target exactly as written.
---@field path? string # Absolute, normalized path for local targets.
---@field anchor? string # Fragment after `#`, without the `#`.
---@field url? string # Normalized URL for `type == "url"`.
---@field ext? string # Lowercased extension, when there is one.
---@field size? integer # Byte size, for local files.
---@field reason? string # Why it is `missing`.

-- #####################################################################
-- registry.lua, bare_path.lua, bare_url.lua

--- What a source reported under the cursor.
---@class Hover.Source
---@field target string # Raw target string, handed to `classify`.
---@field lnum integer # 1-based line it was found on.
---@field col integer # 0-based start column.
---@field col_end integer # 0-based end column.
---@field line? integer # 1-based line the target named (`init.lua:42`), when it named one.
---@field line_end? integer # Last line, when the target named a range (`init.lua:10-20`).
---@field kind? string # Free-form label from the source ("mdlink", "bare_path", ...).

--- One plugin's contribution, keyed by plugin name so a second `setup()`
--- replaces it rather than stacking a second scanner onto every hover.
---@class Hover.Contribution
---@field sources? Hover.SourceFn[] # Tried in registration order, before the built-in bare-path source.
---@field previews? table<string, Hover.PreviewFn> # Keyed by the target type this preview claims.
---@field positions? Hover.PositionFn[] # Tried in registration order, only after every source declined.

--- "What is under the cursor?" Returns a raw target string, or nil to
--- decline. Declared as an alias rather than written inline, because an
--- optional or nested function type does not survive inline (`LLS-13`).
---@alias Hover.SourceFn fun(bufnr: integer, row: integer, col: integer): string|nil, table|nil

--- "Is there anything to say about this *place*?" Returns finished content,
--- or nil to decline. Unlike a source it hands back no target string, because
--- there is nothing the cursor points at -- the answer is about the position
--- itself: a deprecated call on this line, how often this token occurs, what
--- this module is. Declared as an alias for the same reason as `SourceFn`
--- (`LLS-13`).
---@alias Hover.PositionFn fun(bufnr: integer, row: integer, col: integer): Hover.Content|nil

--- "How do I preview a target of this type?" Returning nil declines, and
--- the built-in preview runs instead.
---@alias Hover.PreviewFn fun(target: Hover.Target, opts: Hover.PreviewOpts, bufnr: integer): Hover.Content|nil

-- #####################################################################
-- preview/*.lua

--- Options threaded from the configuration into the previewers.
---@class Hover.PreviewOpts
---@field max_lines integer
---@field max_width? integer # Needed by the image previewer, which sizes the float itself rather than letting it be measured from text.
---@field inline_images? boolean
---@field url_fetch? boolean
---@field url_timeout_ms? integer
---@field office_convert? boolean # Convert an office document to a PDF for a real page preview, instead of showing a badge.
---@field office_timeout_ms? integer # Conversion timeout, passed to pdfport.
---@field office_cache_days? integer # How long a converted PDF may survive between sessions.
---@field line? integer # Text previews: 1-based line the target named (`init.lua:42`); the first view starts near it.
---@field line_end? integer # Text previews: last line of a named range (`init.lua:10-20`); shown exactly, without lead-in.
---@field offset? integer # Text previews: lines to skip. Set by `hover.scroll`.
---@field page? integer # PDF previews: 1-based page to render. Set by `hover.scroll`. Office documents page through their converted PDF the same way.

---@class Hover.Content
---@field lines string[]
---@field filetype? string # Set only where a filetype is known, never guessed.
---@field title? string # Rendered in the float border.
---@field image_path? string # Draw this image into the float, if a provider can.
---@field canvas? Hover.Canvas # Size the float to this instead of to `lines`, and show no text or title: the float is a frame for the picture, not a caption for it.
---@field highlight? string # Highlight group for the first line, where that line is a verdict rather than content: `HoverMissing` (-> `DiagnosticError`, the broken-target marker), `HoverError` (-> `DiagnosticError`, an HTTP 4xx/5xx or an unreachable host), `HoverInfo` (-> `DiagnosticHint`, the "no text in this file" badge).
---@field scroll? Hover.Scroll # Present when the preview has more to show; drives the `scroll_keys`.
---@field pending? boolean # Provisional; an async result replaces it (and it is not cached).

--- Where a scrollable preview currently is, and whether more follows.
--- Absent means "not scrollable" -- an image, or a file that fits -- and the
--- scroll keys are then not bound at all.
---@class Hover.Scroll
---@field offset? integer # Lines skipped, for text previews.
---@field page? integer # 1-based page, for PDF previews.
---@field step integer # How much one scroll step advances.
---@field more boolean # Whether anything follows the current position.
---@field past_end? boolean # The requested position does not exist (paged past the last PDF page).

--- Pixel dimensions of an image. Structurally identical to images.nvim's
--- `Images.Scale.Dims`, declared here because images.nvim is a soft
--- dependency (`pcall(require, ...)`) and its types are not on this
--- workspace's library path (`LLS-23`: only what the original does not
--- carry into this workspace is declared).
---@class Hover.Preview.Dims
---@field width integer
---@field height integer

-- #####################################################################
-- float.lua

--- Exact float size in cells, for a preview that is a picture rather than
--- text.
---@class Hover.Canvas
---@field cols integer
---@field rows integer

--- Geometry and appearance for `hover.float.open`.
---@class Hover.FloatOpts
---@field title? string
---@field filetype? string
---@field max_width? integer
---@field max_height? integer
---@field canvas? Hover.Canvas # Blank float of this exact size; `lines`, `title` and `filetype` are ignored.
---@field border? string|string[]
---@field focusable? boolean
---@field highlight? string # Highlight group for the first line. `HoverMissing`/`HoverError` (-> `DiagnosticError`) and `HoverInfo` (-> `DiagnosticHint`) are defined on demand, with `default = true` so a colorscheme still wins.
---@field on_close? fun()

return {}
