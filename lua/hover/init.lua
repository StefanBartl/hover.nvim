---@module 'hover'
---@brief Rest the cursor on something that points at a file, and see what it points at.
---@description
--- The cursor rests on something that points at a file ==> a small float
--- shows what it points at, whatever that is: an image, a PDF page, a
--- markdown file's section, a plain file's head, a directory listing, an
--- in-page anchor, a URL -- or, when the target does not exist, *that*,
--- which is often the most useful answer of all. A file whose bytes are not
--- text (a `.docx`, an archive, an executable) gets a badge saying so rather
--- than a float full of its bytes.
---
--- **What is opt-in, and why.** A float that opens unasked is welcome only
--- when the target was explicit *and* the preview says something the line
--- does not already say. Run every preview class through that and the
--- defaults fall out: local links and bare paths on, web links off (the
--- offline preview restates the link text), fetching off again on top (it
--- discloses every link brushed past to its host), office conversion off (a
--- LibreOffice start per document). Each is a switch, not a fixed default --
--- `:Hover links web on` while chasing a broken link, off afterwards. Above
--- them all sits `mode`: `:Hover manual` keeps every preview and gives up
--- only the automatic trigger, which is the answer to "I am reading a
--- document made of links right now".
---
--- **Nothing here installs an autocmd by itself.** `enable()` does, and it
--- has to be called from somewhere that is not lazy-loaded -- see the
--- README. A plugin that started previewing things the moment it landed on
--- the runtimepath would be overstepping.
---
--- **What this module knows, and what it does not.** Classification is
--- `hover.classify`, presentation `hover.float`, per-type content
--- `hover.preview.*`, and "what is under the cursor with no link syntax at
--- all" is `hover.bare_path` for a path and `hover.bare_url` for a URL.
--- markdown.nvim contributes link scanning and `#heading` previews through
--- `hover.registry`; images.nvim, pdfport.nvim and gopath.nvim are reached
--- by name from inside the previews. All four are optional, and none is
--- required for the hover to work.
---
--- Asynchronous previews (PDF rasterization, URL fetch) are guarded by a
--- generation counter: if the cursor moves on before the result lands, the
--- result is dropped rather than opening a float for a target the reader has
--- already left.
---
---@see hover.config
---@see hover.switches
---@see hover.registry

local M = {}

local api = vim.api

local cache = require("hover.cache")
local classify = require("hover.classify")
local config = require("hover.config")
local float = require("hover.float")
local keys = require("hover.bindings.keymaps")
local switches = require("hover.switches")

---@type integer Bumped on every request; stale async results compare against it.
local _generation = 0
---@type table|nil
local _debounced = nil
---@type integer|nil Delay the current debounce was built with.
local _debounced_delay = nil
---@type Hover.Open|nil What the open float is showing.
local _open = nil
---@type string|nil Identity of a target dismissed by `M.dismiss`, until the cursor leaves it.
local _suppressed = nil

---@type number What one resize step multiplies the float's box by.
--- 1.25 rather than 1.5: measured against a real Neovim on 2026-09-02, a
--- 210x55 terminal has room for five steps at this size (71x20 cells of
--- picture up to 181x51) and only two at 1.5. Five presses to fill the screen
--- is a dial; two is a switch with an awkward middle.
local RESIZE_STEP = 1.25

---@type number What one zoom step divides the visible rectangle by.
--- Mirrors `hover.preview.media`'s own constant, and is here only so `nav`
--- can size a step against the view rather than against the source: a quarter
--- of what is on screen, whatever level that is.
local ZOOM_VIEW_STEP = 1.5

---@internal
--- The multiplier the hover on screen is currently asking for.
---
--- Read in two places that must not disagree: `resize`, which asks a
--- previewer for a bigger answer, and `present`, which tells the float how
--- large it may be. Splitting them was the bug that kept this feature to
--- pictures for a while -- `present` clamped every text float back to the
--- configured `max_lines` no matter what had been asked for.
---@return number
local function resize_factor()
  return RESIZE_STEP ^ ((_open and _open.resize) or 0)
end

---@internal
--- The box the hover on screen is currently asking for: `max_width` and
--- `max_height`, in cells.
---
--- **Three readers, and they used to be three derivations.** `present` tells
--- the float how large it may be, `current_preview_opts` tells the previewer
--- how large an answer to build, and `resize` compares the size a step would
--- produce against the one on screen. The first two each did the multiply
--- themselves, which is the hand-kept-copy shape this file has been bitten by
--- repeatedly -- and zen is a second input on the same number, so keeping them
--- apart would have meant a full-screen float showing twenty lines.
---
--- **Zen replaces the base; resize still multiplies on top of it.** The base
--- is the editor's own size rather than a configured one, and the ceiling
--- `float.size_for` clamps against is exactly the same expression -- so `+` in
--- zen produces the identical float, `resize` sees that and steps back off,
--- and `-` shrinks from full screen without leaving zen. That is the whole
--- interaction between the two, and it needed no code of its own.
---@return integer max_width
---@return integer max_height
local function box()
  local c = config.get()
  local width, height = c.max_width or 80, c.max_lines or 20
  if _open and _open.zen then
    width = math.max(20, vim.o.columns - 4)
    height = math.max(3, vim.o.lines - 4)
  end
  local factor = resize_factor()
  return math.max(1, math.floor(width * factor + 0.5)),
    math.max(1, math.floor(height * factor + 0.5))
end

-- ---------------------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------------------

--- Configure the hover. Merged over the current values, so a host can set
--- only what it cares about, and calling it twice does not reset the rest.
---
--- The pre-move option names (`enabled`, `bare_paths`, `url = { ... }`) are
--- still accepted and normalized -- see `hover.config`.
---
--- **`contribute` is the one field that is not a setting.** It takes exactly
--- the table `hover.registry.register` takes, so "can I add a hover of my own
--- without writing a plugin" is answered by a function in this table rather
--- than by a second mechanism. Registering was always public; what was
--- missing was saying so where a reader configures the plugin.
---
--- It is registered under the name `"user"` and never reaches the options.
--- Both halves of that matter: functions are not configuration, and the name
--- makes a second `setup()` replace that registration rather than stack a
--- duplicate on it -- a reloaded config must not fire the same function
--- twice. A *plugin* should call `register` under its own name instead; two
--- callers sharing the `"user"` slot would silently delete each other.
---@param opts? Hover.Config
---@return Hover.Config
function M.setup(opts)
  -- Report the declared external tools (docs/install.json) once, ever, on
  -- the first setup after installation. pcall'd because an older lib.nvim
  -- without lib.nvim.deps must not break setup() over an informational
  -- popup; `:Lib deps show hover.nvim` stays available either way. Turn it
  -- off with `vim.g.lib_nvim_deps_disable_first_run` (or the per-plugin
  -- `vim.g.lib_nvim_deps_disabled_plugins`).
  local ok_deps, deps = pcall(require, "lib.nvim.deps")
  if ok_deps then
    deps.show_once("hover.nvim")
  end

  if type(opts) == "table" and type(opts.contribute) == "table" then
    require("hover.registry").register("user", opts.contribute)

    -- Removed from a shallow copy rather than from the caller's table: what
    -- arrives here may be a host's own live configuration (markdown.nvim
    -- hands one over), and clearing a field in it would be a side effect on
    -- that plugin's state.
    local settings = vim.tbl_extend("force", {}, opts)
    settings.contribute = nil
    return config.setup(settings)
  end
  return config.setup(opts)
end

--- Switch the hover on: install the trigger autocmds, the configured
--- keymaps and the `:Hover` command, and attach to buffers already open.
---
--- Idempotent -- call it from two plugins and you still get one autocmd.
--- Accepts the same options as `setup`, so turning it on and configuring it
--- is one call.
---@param opts? Hover.Config
---@return nil
function M.enable(opts)
  if type(opts) == "table" then
    M.setup(opts)
  end
  -- After the installation spec's own `opts`, and before the `is_enabled`
  -- check below: a persisted `mode = "off"` has to be able to take effect on
  -- the very check that reads it. See `hover.persist`.
  local persist = require("hover.persist")
  persist.load()
  persist.setup()
  require("hover.bindings.usrcmds").setup()
  if not config.is_enabled() then
    return
  end
  keys.setup()
  require("hover.bindings.autocmds").enable()
end

--- Install the hover autocmds for one buffer. Hosts normally let `enable()`
--- do this through its `FileType` autocmd.
---@param bufnr integer
---@return nil
function M.attach(bufnr)
  require("hover.bindings.autocmds").attach(bufnr)
end

-- ---------------------------------------------------------------------------
-- Finding a target
-- ---------------------------------------------------------------------------

---@internal
--- Identity of a target for a *dismissal* -- "is this still the same thing
--- the reader waved away?"
---
--- Deliberately not `cache.key`: that carries the file's mtime, so saving
--- the file you are standing in would end the dismissal and pop the float
--- back. Deliberately not the line either -- a dismissed hover has to
--- survive its path sliding down the buffer as you edit above it, which is
--- precisely the situation the dismissal exists for.
---@param target Hover.Target
---@return string
local function identity(target)
  return table.concat({ target.type, target.raw, target.path or "", target.anchor or "" }, "|")
end

--- The target under the cursor in `bufnr`, or nil.
---
--- Registered sources first, in registration order -- markdown.nvim
--- contributes link scanning and `<figure>` resolution there -- then the
--- bare URL source, then the built-in bare-path source. That order matters:
--- on `[a](./b.png)` both the link scanner and the path source would answer,
--- and the link is the more specific reading of the same text.
---
--- This does *not* fall back to "the only target on the line": a hover must
--- describe what the cursor is actually on, or it pops up while the cursor
--- sits in unrelated text.
---
--- `opts.force` opens every volume gate: an explicit request for whatever is
--- under the cursor is not the problem those switches exist to solve, so it
--- answers for a web link with `links web off` and for a link with `links
--- off`. It does not open the *cost* gates -- fetching stays off unless it
--- was configured on, because a keypress is not consent to disclose the link
--- to its host.
---@param bufnr? integer
---@param opts? { force?: boolean }
---@return Hover.Source|nil
function M.target_under_cursor(bufnr, opts)
  opts = opts or {}
  local force = opts.force == true
  -- `0` means "current buffer" by Neovim convention but is truthy in Lua, so
  -- `bufnr or ...` would leave it as 0 and the check below would compare a
  -- real handle against 0 and always bail out.
  if not bufnr or bufnr == 0 then
    bufnr = api.nvim_get_current_buf()
  end
  local win = api.nvim_get_current_win()
  if api.nvim_win_get_buf(win) ~= bufnr then
    return nil
  end

  local pos = api.nvim_win_get_cursor(win)
  local row, col = pos[1], pos[2]
  local line = api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1]
  if not line then
    return nil
  end

  -- Link syntax, from whatever plugin registered a scanner. Gated here
  -- rather than after classification, because "links off" is a statement
  -- about how the target was *found*, not about what it turned out to be:
  -- the same text may still be a resolvable bare path, and `paths` decides
  -- that separately.
  if force or config.links_enabled() then
    local target, extra = require("hover.registry").source_at(bufnr, row, col, { force = force })
    if target then
      local record = { target = target, lnum = row, col = col, col_end = col }
      for k, v in pairs(type(extra) == "table" and extra or {}) do
        record[k] = v
      end
      return record
    end
  end

  -- A URL written as plain text -- in a code comment, a `.txt`, a commit
  -- message, a `:messages` dump. Before the bare-path source, because that
  -- one would find `https://example.com/a.html` too, by way of `<cfile>` and
  -- the "a component carries an extension" rule -- and would find it
  -- truncated at whatever `'isfname'` excludes.
  --
  -- Only when the web hover is on: this is the source that would otherwise
  -- make every link in every document a hover target, which is exactly the
  -- overload the switch exists to prevent.
  if force or config.web_enabled() then
    local url = require("hover.bare_url").under_cursor(bufnr)
    if url then
      return url
    end
  end

  -- A git object id, and only on an explicit request. Confirming that a hex
  -- string is an object costs a git start -- 41 ms measured, the same whether
  -- it hits or misses -- so this class is the one that never rides the
  -- automatic trigger at all. See `hover.bare_git`.
  if force then
    local git = require("hover.bare_git").under_cursor(bufnr)
    if git then
      return git
    end
  end

  -- Nothing claimed it: the text may be a path carrying no link syntax at
  -- all. Same target shape, so everything downstream is unchanged.
  if not (force or config.paths_enabled()) then
    return nil
  end
  return require("hover.bare_path").under_cursor(bufnr, {
    -- Forced, the broken-target marker is wanted: "there is nothing here"
    -- is the answer someone asking about this exact text came for.
    missing = force or config.missing_enabled(),
    -- Forced, the position gate goes too: someone asking about this exact
    -- text has already said the text is worth asking about, and being told
    -- "no" because the cursor is inside an expression would be answering a
    -- question nobody asked.
    code = force or config.paths_code_enabled(),
    -- Forced, the resolver runs its full pipeline: the cost is the point of
    -- asking. See `bare_path.gopath_can_help`.
    force = force,
  })
end

--- Backwards-compatible alias. The framework predates having sources other
--- than markdown links, and `markdown.hover.link_under_cursor` was public.
---@param bufnr? integer
---@return Hover.Source|nil
function M.link_under_cursor(bufnr)
  return M.target_under_cursor(bufnr)
end

-- ---------------------------------------------------------------------------
-- Building a preview
-- ---------------------------------------------------------------------------

---@internal
--- Run a previewer that may answer now or later, and decide when its
--- provisional content is allowed on screen.
---
--- The contract `preview.media.pdf` and `preview.office.preview` share: they
--- return what to show *now* -- final, or marked `pending` -- and call
--- `on_result` when the real thing lands. Two things have to happen around
--- that, and both were written twice before this existed:
---
---  * **A stale result is dropped.** The generation counter moves when the
---    cursor does; a page that finishes rasterizing afterwards must not open
---    a float over a line the reader has left. The work is not wasted -- the
---    previewer keeps its page -- it simply does not interrupt.
---  * **A placeholder waits out the grace period.** A render that beats it
---    shows the finished page and nothing else, with no flash of a
---    differently sized text float first. One that misses it has a real wait
---    to explain, and then the placeholder is worth its interruption.
--- `run` may answer `nil` -- `media.zoomed` does, when there is nothing to
--- crop -- and the `type(provisional) ~= "table"` check below has always
--- handled it. The annotation said `Hover.Content` and was simply narrower
--- than the code, which is the direction that produces a finding rather than
--- a bug.
---@param run fun(on_result: fun(content: Hover.Content)): Hover.Content|nil
---@param emit fun(content: Hover.Content|nil)
---@return nil
local function build_async(run, emit)
  local generation = _generation
  local settled = false

  local provisional = run(function(content)
    settled = true
    if generation ~= _generation then
      return
    end
    emit(content)
  end)

  if type(provisional) ~= "table" then
    return
  end

  if not provisional.pending then
    emit(provisional)
    return
  end

  vim.defer_fn(function()
    if settled or generation ~= _generation then
      return
    end
    emit(provisional)
  end, config.placeholder_grace_ms())
end

---@internal
--- Build the content for `target`, then hand it to `emit`. Synchronous
--- previewers call `emit` immediately; async ones later.
---@param target Hover.Target
---@param bufnr integer
---@param opts Hover.PreviewOpts
---@param emit fun(content: Hover.Content|nil)
---@return nil
local function build(target, bufnr, opts, emit)
  local text = require("hover.preview.text")

  -- A registered preview claims its type outright. This is how anything
  -- needing knowledge this plugin does not have gets in: markdown.nvim
  -- registers `anchor` (and `markdown` targets carrying one), because
  -- resolving `#some-heading` means GFM slugging and heading parsing, which
  -- belong to the plugin that owns markdown.
  local claimed = require("hover.registry").preview_for(target.type)
  if claimed then
    -- A registered preview may decline (nil) -- an anchor that resolves to
    -- nothing, say -- and the built-in handling below is then still the
    -- better answer than an empty float.
    local ok, content = pcall(claimed, target, opts, bufnr)
    if ok and content then
      emit(content)
      return
    end
  end

  if target.type == "anchor" then
    -- No plugin claimed in-page anchors: nothing here can resolve a heading,
    -- so there is nothing honest to show.
    emit(nil)
  elseif target.type == "missing" then
    emit(text.missing(target))
  elseif target.type == "directory" then
    emit(text.directory(target, opts))
  elseif target.type == "markdown" or target.type == "file" then
    -- A `markdown` target with an unclaimed `#anchor` falls through to the
    -- plain file preview: the file still exists, only the fragment could not
    -- be resolved, and its first lines beat an error.
    emit(text.file(target, opts))
  elseif target.type == "image" then
    local media = require("hover.preview.media")
    if (opts.zoom or 0) > 0 then
      -- A magnified detail is a `magick` run and a file on disk, so it takes
      -- the route a PDF page takes -- and measured, it is the faster of the
      -- two: ~258 ms against ~1150 ms for one rasterized page.
      build_async(function(on_result)
        return media.zoomed(target.path, opts, on_result)
      end, emit)
    else
      emit(media.image(target, opts))
    end
  elseif target.type == "pdf" then
    build_async(function(on_result)
      return require("hover.preview.media").pdf(target, opts, on_result)
    end, emit)
  elseif target.type == "office" then
    -- Same shape as the PDF branch, and for a stronger reason: a LibreOffice
    -- start is seconds, so the "converting..." placeholder is one the reader
    -- will actually see. When the conversion is off, `preview` answers with
    -- a badge synchronously and nothing is deferred at all.
    build_async(function(on_result)
      return require("hover.preview.office").preview(target, opts, on_result)
    end, emit)
  elseif target.type == "git" then
    build_async(function(on_result)
      return require("hover.preview.git").preview(target, opts, on_result, bufnr)
    end, emit)
  elseif target.type == "url" then
    local url = require("hover.preview.url")
    -- **Two gates, and the second one is what `auto_hover` could not say.**
    -- `shot_enabled` is "may a link be rendered at all"; `shot_eager` is "may
    -- the *trigger* do it". Without the second, a document made of links is a
    -- browser start per link while scrolling -- and `auto_hover.url` cannot
    -- express the difference, because the text preview and the screenshot are
    -- the same target type. `requested` carries "this was asked for" down
    -- from `show`, which is the only other thing that opens the gate.
    if opts.shot_enabled and (opts.shot_eager or opts.requested) then
      build_async(function(on_result)
        return require("hover.preview.shot").preview(target, opts, on_result)
      end, emit)
    elseif opts.url_fetch then
      build_async(function(on_result)
        url.fetch(target, opts, function(content)
          -- curl's exit lands in a fast event context, where opening a
          -- window is not allowed.
          vim.schedule(function()
            on_result(content)
          end)
        end)
        -- The parsed URL, held back for the grace period: a response that
        -- beats it shows the status line and nothing else, and one that does
        -- not still leaves something on screen instead of a wait that looks
        -- like the hover simply failing.
        return vim.tbl_extend("force", url.offline(target), { pending = true })
      end, emit)
    else
      emit(url.offline(target))
    end
  else
    emit(nil)
  end
end

---@internal
--- Whether the hover described by `open` is one a zoom could act on.
---
--- Pure, and separate from `zoomable` below for one reason: `present` needs
--- the answer to decide whether to borrow the zoom keys, and `zoomable` needs
--- it *plus* the "there is no float any more, tear down" branch that only a
--- caller acting on a keypress wants. Written twice, the two would answer
--- differently the first time either changed -- which is the failure mode
--- this repository keeps meeting.
---@param open Hover.Open|nil
---@return boolean
local function can_magnify(open)
  local target = open and open.target
  if not target then
    return false
  end
  local media = require("hover.preview.media")
  -- A rendered page is a third source for the same gesture, and the one that
  -- does not fit the `target.path` test above: what is on screen is a PNG in
  -- this plugin's cache, not a file the target names -- the target names a
  -- URL. Asked of the cache only, because `shot.cached` never starts a
  -- browser and "can this be zoomed" must not have a twenty-second answer.
  if target.type == "url" then
    -- Two ways a link becomes a picture, and they magnify differently. A
    -- rendered page is a PNG and is cropped; a downloaded PDF is re-rendered
    -- at a higher DPI, exactly as a local one is. Both are asked of a cache
    -- only -- neither may start a browser or a download to answer "can this be
    -- zoomed".
    if require("hover.preview.webpdf").cached(target) then
      return media.can_zoom_pdf()
    end
    return media.can_zoom() and require("hover.preview.shot").cached(target) ~= nil
  end
  if not target.path then
    return false
  end
  -- Two kinds of magnification behind one key, because they are the same
  -- gesture and a different mechanism. A picture is cropped: the file at
  -- `target.path` is the source and already carries every pixel there will
  -- be. A PDF page is *re-rasterized* at a higher DPI, because the thing on
  -- screen is a rendering in this plugin's cache rather than the file the
  -- target names -- cropping that would magnify a bitmap already as sharp as
  -- it gets. See `docs/FEATURES/ZOOM.md`.
  if target.type == "image" then
    return media.can_zoom()
  end
  if target.type == "pdf" then
    return media.can_zoom_pdf()
  end
  return false
end

---@internal
--- Put `content` on screen: open the float, draw a picture into it if there
--- is one, and take the keys this hover borrows.
---@param content Hover.Content|nil
---@return nil
local function present(content)
  if not content then
    return
  end
  -- **Whether this hover pages, recorded from the content rather than guessed
  -- from the type.** `scroll` and `zoom` both need the answer, and both used to
  -- derive it from `target.type == "pdf" or "office"` -- which was a proxy for
  -- "this preview is paged" and stopped being an accurate one the moment a
  -- *link* could answer with a PDF. The content already says so: only a paged
  -- preview declares `scroll.page`.
  --
  -- The type test is kept alongside it, and not as a belt: a paged preview
  -- whose first answer is a placeholder declares no `scroll` at all, and a
  -- scroll during that moment would otherwise take the by-lines branch.
  if _open then
    local t = _open.target
    _open.paged = (t and (t.type == "pdf" or t.type == "office")) == true
      or (content.scroll ~= nil and content.scroll.page ~= nil)
      or nil
  end

  local c = config.get()
  local max_width, max_height = box()

  float.open(content.lines, {
    title = content.title,
    filetype = content.filetype,
    canvas = content.canvas,
    highlight = content.highlight,
    max_width = max_width,
    max_height = max_height,
    -- A full-screen float annotates no particular line, so it stops being
    -- anchored to one. See `hover.float`.
    center = (_open and _open.zen) == true,
    border = c.border,
    -- The float dismisses itself on the next cursor move, through an autocmd
    -- this module never hears about. Without a hook there, the keys it
    -- borrowed would stay bound until the next trigger -- up to 'updatetime'
    -- in which `q` records no macro and `<Esc>` does nothing, long after the
    -- float they belonged to is gone.
    on_close = keys.release,
  })

  -- **Re-applied, because `float.open` closes and reopens the window.** The
  -- marker is a prefix on the border title and lives on the window, while
  -- `pinned` lives on `_open` -- so every re-render (a scroll, a resize, a
  -- zoom step) put a pinned float back on screen with the pin invisible. That
  -- was survivable while pinning was a deliberate, rare gesture; zen pins by
  -- default, which makes it the ordinary case.
  if _open and _open.pinned then
    float.set_pinned(true)
  end

  -- An image target draws over the float it just opened.
  if content.image_path then
    local win = float.win()
    if win then
      local on_close = require("hover.preview.media").draw_into(content.image_path, win)
      if on_close then
        float.set_on_close(on_close)
      end
    end
  end

  keys.borrow(content, {
    scroll = M.scroll,
    resize = M.resize,
    nav = M.nav,
    zoom = M.zoom,
    zoomed = ((_open and _open.zoom) or 0) > 0,
    zoomable = can_magnify(_open),
    -- Handed over for every target hover, and withheld for a position one --
    -- `M.zen` would only decline there, and a key bound to a refusal is worse
    -- than an unbound one.
    zen = (_open and _open.target) and function()
      M.zen()
    end or nil,
    next_answer = M.next_position,
    -- Registered, not answering: see `registry.position_count`. Only a
    -- *position* hover has other answers to step to at all.
    has_answers = (_open and _open.position ~= nil)
      and require("hover.registry").position_count() > 1,
  })
end

-- ---------------------------------------------------------------------------
-- Showing, hiding, scrolling
-- ---------------------------------------------------------------------------

--- Show the hover for the target under the cursor. No-op when there is none.
---@param opts? { force?: boolean } `force` ignores every volume switch.
---@return boolean shown
function M.show(opts)
  opts = opts or {}
  -- `force` opens the volume gates, not the master switch. `mode = "off"`
  -- reads "nothing at all", and `vim.g.hover_disable` -- a reader's veto over
  -- a host plugin that switched this on -- arrives here as exactly that mode.
  -- A host's own keymap calling `show({ force = true })` must not be able to
  -- defeat it, which is what skipping this check let it do. "Silent by
  -- itself, still answering in full when asked" is `mode = "manual"`, and
  -- that is the whole reason the mode exists.
  if not config.is_enabled() then
    return false
  end

  -- A pinned float belongs to the reader, not to the cursor. The trigger
  -- neither replaces it nor closes it; an explicit request does both, because
  -- asking about something else is unambiguous about what you want.
  if _open and _open.pinned and not opts.force then
    return false
  end

  local bufnr = api.nvim_get_current_buf()
  local found = M.target_under_cursor(bufnr, { force = opts.force })
  if not found then
    -- Nothing the cursor *points at*. There may still be something to say
    -- about where it *is* -- a deprecated call on this line, how often this
    -- token occurs in the buffer. Asked here rather than earlier because a
    -- target is the more specific reading of the same place.
    if M.show_position(bufnr, opts) then
      return true
    end
    -- The most common exit by far, since moving the cursor off a target
    -- comes back through here. `hide` rather than `float.close`, for the two
    -- things it does besides closing: hand back the borrowed keys, and bump
    -- the generation. Without the bump, a PDF still rasterizing for the
    -- target just left would land afterwards, match the unchanged generation
    -- and open a float over a line the reader has moved past.
    M.hide()
    -- The cursor is on nothing at all, so it has left whatever was
    -- dismissed: going back to that target should show it again.
    _suppressed = nil
    return false
  end

  local source = api.nvim_buf_get_name(bufnr)
  local target
  if found.kind == "git" then
    -- Not classified: a hex run is not a path and `classify`'s job is to
    -- decide what a *path-like string* is. The source already decided.
    target = { type = "git", raw = found.target }
  else
    target = classify.classify(found.target, source ~= "" and source or nil)
  end

  -- The web hover is off and the cursor is on a link: nothing opens.
  --
  -- Gated here as well as at the source, because a URL reaches this from two
  -- directions -- markdown.nvim's link scanner finds `[text](https://...)`
  -- in a markdown buffer, `bare_url` finds a URL in anything else -- and one
  -- switch has to answer for both.
  if target.type == "url" and not opts.force and not config.web_enabled() then
    M.hide()
    _suppressed = nil
    return false
  end

  -- The type is one this reader does not want opening by itself.
  --
  -- Here rather than at the source, and for the opposite reason the web gate
  -- above is in two places: this one is *about* the type, and the type is not
  -- known until `classify` has run. Everything before this point has already
  -- happened either way -- the scope check, the `fs_stat` -- so what is saved
  -- is the float and the preview behind it, not the work of finding out there
  -- was something here. A reader expecting this to make the plugin cheaper is
  -- getting quiet instead, which is what they asked for.
  if not opts.force and not config.auto_hover_for(target.type) then
    M.hide()
    _suppressed = nil
    return false
  end

  if _suppressed then
    if opts.force or _suppressed ~= identity(target) then
      -- Either the cursor reached a different target, or a caller asked for
      -- this one outright. Both end the dismissal.
      _suppressed = nil
    else
      -- Still standing on the thing that was waved away. Nothing to close --
      -- `dismiss` already did that -- and nothing to open.
      return false
    end
  end

  _generation = _generation + 1
  local generation = _generation

  keys.release()
  -- `requested` is remembered rather than only passed, because a re-render is
  -- a continuation of whatever opened this float: a screenshot asked for with
  -- `:Hover show` must still be a screenshot after `F`, and not fall back to
  -- the text preview because the second render came from a keypress.
  _open = {
    target = target,
    bufnr = bufnr,
    offset = 0,
    page = 1,
    requested = opts.force == true or nil,
  }

  -- Deliberately not widened by `force`. Volume gates open for an explicit
  -- request; the fetch does not, because a keypress asking "what is this"
  -- is not consent to tell the link's host about it.
  local preview_opts = config.preview_opts()
  -- `init.lua:42` out of a log or a stack trace: show line 42, not the
  -- file's first twenty lines, which are almost never the ones being asked
  -- about. Sources that name no line leave this nil and nothing changes.
  preview_opts.line = found.line
  preview_opts.line_end = found.line_end
  -- Not the same question as `force`, which opens the *volume* gates. This
  -- one says the reader asked, and it is read by anything whose cost makes
  -- that difference matter -- today the screenshot, which starts a browser
  -- for a request and waits to be told it may for a trigger.
  preview_opts.requested = opts.force == true

  local key = cache.key(target)
  local cached = cache.get(key)

  ---@param content Hover.Content|nil
  local function guarded(content)
    if generation ~= _generation then
      return
    end
    present(content)
  end

  if cached and not cached.pending then
    guarded(cached)
    return true
  end

  build(target, bufnr, preview_opts, function(content)
    if content and not content.pending then
      cache.put(key, content)
    end
    guarded(content)
  end)

  return true
end

---@internal
--- The position half of `show`: a registered *position* preview, for a cursor
--- position that points at nothing.
---
--- Deliberately not cached. The target cache is keyed by what a target *is*,
--- and a position has no such identity -- what a position preview answers can
--- depend on the whole buffer, and a stale entry would be a wrong answer
--- rather than an old one. The plugin that registered it owns its own
--- freshness.
---
--- Dismissal works the same way it does for a target, keyed by plugin and
--- row: waving away a deprecation note keeps it away while the cursor stays
--- on that line, and moving to another line brings it back.
---@param bufnr integer
---@param opts { force?: boolean }
---@return boolean shown
function M.show_position(bufnr, opts)
  -- `has_positions` answers about the *automatic* trigger: it deliberately
  -- does not count an `on_request` contribution, so a buffer whose only one
  -- is force-only gets no CursorHold. Using it as a guard here too would make
  -- such a contribution unreachable by any route -- which it was, until a
  -- live test of sandbox.nvim showed a registered preview that could never be
  -- asked. Under `force`, whether anything answers is `position_at`'s to
  -- decide, not this guard's.
  if not opts.force and not require("hover.registry").has_positions() then
    return false
  end
  if not opts.force and not config.positions_enabled() then
    return false
  end
  -- The same type gate the target path gets, for the one entry in it that is
  -- not a target type. Asked before `position_at`, which is the expensive
  -- call here: every registered contribution is invoked, and one of them
  -- reads a file.
  if not opts.force and not config.auto_hover_for("position") then
    return false
  end

  local win = api.nvim_get_current_win()
  if api.nvim_win_get_buf(win) ~= bufnr then
    return false
  end
  local pos = api.nvim_win_get_cursor(win)
  local row, col = pos[1], pos[2]

  local content, name =
    require("hover.registry").position_at(bufnr, row, col, { force = opts.force })
  if not content then
    return false
  end

  local id = table.concat({ "position", name or "?", bufnr, row }, "|")
  if _suppressed then
    if opts.force or _suppressed ~= id then
      _suppressed = nil
    else
      return false
    end
  end

  _generation = _generation + 1
  keys.release()
  -- No `target` field: that absence is what `scroll` and `identity` read to
  -- tell the two kinds apart, rather than a flag either could forget to set.
  -- `col` and `position_nth` so `next_position` can ask the same place for
  -- its next answer. The row alone was enough while only one could win.
  _open = { position = id, bufnr = bufnr, row = row, col = col, position_nth = 1 }
  present(content)
  return true
end

--- Step to the next plugin that has something to say about this place.
---
--- **Why stepping and not merging.** Several plugins can answer for one
--- position, and on a dotted name two routinely do: "what is this module"
--- and "who imports it". Until now the first registered won and the rest were
--- invisible -- decided by plugin load order, which is nobody's decision.
---
--- Merging them into one float was the other way, and it is worse than it
--- looks: `Hover.Content` is shaped for *one* answer. Two contents mean two
--- titles for one border, two filetypes for one highlight, two `scroll`
--- states for one pair of borrowed keys -- and a picture cannot be merged
--- with text at all. Stepping keeps each answer whole, which is the property
--- that makes it worth the key.
---
--- **It asks with `force`.** Stepping is an explicit act, so a contribution
--- that declared its answer expensive (`on_request`) is reachable here --
--- exactly as it is through `:Hover show`, and for the same reason.
---
--- Wraps: past the last answer it returns to the first, so the key is a ring
--- rather than a dead end. With only one answer it says so instead, because a
--- key that silently does nothing is indistinguishable from a broken one.
---@return boolean stepped
function M.next_position()
  if not (_open and _open.position and float.win()) then
    keys.release()
    return false
  end

  local registry = require("hover.registry")
  local current = _open.position_nth or 1

  ---@param nth integer
  ---@return Hover.Content|nil, string|nil
  local function ask(nth)
    return registry.position_at(_open.bufnr, _open.row, _open.col or 0, {
      force = true,
      nth = nth,
    })
  end

  local nth = current + 1
  local content, name = ask(nth)
  if not content and current > 1 then
    nth = 1
    content, name = ask(nth)
  end
  if not content then
    require("hover.notify").info("no other answer here")
    return false
  end

  local id = table.concat({ "position", name or "?", _open.bufnr, _open.row }, "|")
  _generation = _generation + 1
  keys.release()
  _open = {
    position = id,
    bufnr = _open.bufnr,
    row = _open.row,
    col = _open.col,
    position_nth = nth,
  }
  present(content)
  return true
end

--- Why nothing opened here.
---
--- **The gap this fills.** A hover that does not open is silent by design,
--- and there are now seven independent reasons for it: the mode, the volume
--- switch for that class, an active dismissal, the non-blank character check,
--- the token shape test, the position gate, and "nothing on disk". From the
--- outside all seven look identical -- a cursor sitting on something that
--- does not hover -- and the only way to tell them apart was to read the
--- source.
---
--- **It runs the real pipeline.** The one thing this must not become is a
--- second implementation of the rules: the moment it answers from its own
--- copy, it can be confidently wrong in exactly the situation it exists for.
--- So it calls the same predicates in the same order, and `bare_path`
--- reports where it stopped through an optional `trace` table rather than
--- being re-derived here. The cost on the hot path is one nil check per
--- gate, and nothing is allocated unless someone asked.
--- Returns the report rather than emitting it: the notifying belongs to the
--- command layer, the way `status` already works (`ERR-04`).
---@return string[] lines
function M.why()
  local bufnr = api.nvim_get_current_buf()
  local out = {}

  local function say(fmt, ...)
    out[#out + 1] = select("#", ...) > 0 and fmt:format(...) or fmt
  end

  say("mode: %s", M.mode())
  if not config.is_enabled() then
    say("  nothing hovers in this mode. `:Hover mode auto` turns it back on.")
    return out
  end

  if vim.bo[bufnr].buftype ~= "" then
    say("buffer: buftype=%q -- never attached to.", vim.bo[bufnr].buftype)
    say("  A picker, tree, terminal or dashboard has no document to hover in.")
    return out
  end

  local found = M.target_under_cursor(bufnr, {})
  if found then
    local target = classify.classify(
      found.target,
      (function()
        local n = api.nvim_buf_get_name(bufnr)
        return n ~= "" and n or nil
      end)()
    )
    say("target: %s (%s, via %s)", found.target, target.type, found.kind or "source")
    if target.type == "url" and not config.web_enabled() then
      say("  but web links are off. `:Hover links web on`.")
    elseif not config.auto_hover_for(target.type) then
      -- The gate `:Hover links web on` used to walk straight into. Both
      -- statements were true at once -- web links hover, and the trigger does
      -- not open them -- and this report knew only the first, so the one
      -- command written to answer "why is nothing happening" answered "this
      -- should hover. If it does not, that is a bug worth reporting."
      --
      -- After the web check and before the dismissal, because that is the
      -- order `show` asks them in: a URL with `web` off never reaches the type
      -- gate at all, and a report that named the second reason would send the
      -- reader to fix something that is not what stopped them.
      say(
        "  but %s targets do not open by themselves. `:Hover auto %s`, or `:Hover show`.",
        target.type,
        target.type
      )
    elseif _suppressed and _suppressed == identity(target) then
      say("  but it was dismissed. Move off it, or `:Hover show`.")
    else
      say("  this should hover. If it does not, that is a bug worth reporting.")
    end
    return out
  end

  -- Nothing was found. Ask the bare-path pipeline where it gave up.
  if not config.paths_enabled() then
    say("bare paths: off. `:Hover paths on`.")
  else
    local trace = {}
    require("hover.bare_path").under_cursor(bufnr, {
      missing = config.missing_enabled(),
      code = config.paths_code_enabled(),
      trace = trace,
    })
    local token = trace.token and ("%q"):format(trace.token) or "(none)"
    local why = ({
      blank = "the cursor is on whitespace.",
      shape = ("%s is not shaped like a path -- no separator, no extension, no truncation."):format(
        token
      ),
      scope = ("%s sits in executable code, where a path is not looked for. `:Hover paths code on`."):format(
        token
      ),
      missing_off = ("%s resolved to nothing, and the broken-target marker is off."):format(token),
      ambiguous = ("%s resolved to nothing, and could have been prose. `:Hover paths missing` only reports the unambiguous ones."):format(
        token
      ),
    })[trace.stopped_at]
    say("bare path: %s", why or ("nothing under the cursor (token: %s)"):format(token))
  end

  local registry = require("hover.registry")
  if registry.has_sources() then
    say("sources: registered, and none claimed this position.")
  else
    say("sources: none registered. markdown.nvim contributes the link scanner.")
  end

  if registry.has_positions() then
    if not config.positions_enabled() then
      say("positions: registered, but the class is off. `:Hover positions on`.")
    else
      say("positions: registered, and none had anything to say here.")
    end
  end

  return out
end

--- Pin the open hover, or unpin it.
---
--- **What pinning is, and what it deliberately is not.** A preview is
--- transient by design: move the cursor and it is gone, which is right for
--- reading and wrong for comparing. Pinning keeps *this* float on screen
--- while the cursor goes elsewhere -- into another window, another buffer,
--- into insert mode -- so the thing being compared against stays visible.
---
--- It does **not** open a second float. That was the obvious reading and it
--- is a lifecycle rather than a flag: `_open`, the generation counter and the
--- async-result guard are each written for one window, and a second
--- concurrent preview would need all three rebuilt. What this does instead is
--- take one float out of the cursor's hands, which delivers the reason
--- someone wants pinning without pretending the rest is free.
---
--- The consequence, stated rather than discovered: **while a float is pinned,
--- the automatic trigger opens nothing.** There is one float, and it is
--- spoken for. `:Hover show` still answers -- an explicit request replaces
--- the pinned float, because asking about something else is unambiguous --
--- and `q`/`<Esc>` still take it away.
---@param on? boolean explicit state; omitted toggles
---@return boolean pinned
function M.pin(on)
  if not (_open and float.win()) then
    return false
  end
  if on == nil then
    on = not _open.pinned
  end
  _open.pinned = on and true or nil
  -- Whatever the pin was before, it is the reader's now. `zen` sets this flag
  -- again immediately after its own call, so the only thing this clears is a
  -- pin someone changed by hand -- and leaving zen must not undo that.
  _open.zen_pinned = nil
  float.set_pinned(_open.pinned == true)
  return _open.pinned == true
end

--- Whether the open hover is pinned.
---@return boolean
function M.pinned()
  return (_open and _open.pinned) == true
end

---@internal
--- Close the float unless it is pinned. What the `BufLeave`/`InsertEnter`
--- autocmds call: those events are why someone pinned it.
---@return nil
function M.hide_unless_pinned()
  if M.pinned() then
    return
  end
  M.hide()
end

--- Open what the float is showing.
---
--- **A preview that shows a target and cannot open it is half an answer.**
--- The cursor is on a path, the float says what is there, and the next thing
--- a reader wants is to go there -- with `gf`, which is what that key already
--- means in Neovim. While a preview float is up, "open what is under the
--- cursor" and "open what this float is showing" are the same thing, so the
--- key needs no new vocabulary and is borrowed and restored like every other.
---
--- **Through open.nvim when it is installed**, which is the whole point of
--- routing rather than opening directly: it knows the difference between a
--- path that wants a file manager, a URL that wants a browser, and the
--- handler the user configured for either. Without it, `vim.ui.open` is the
--- honest fallback -- the OS decides, which is right for a URL and adequate
--- for a file.
---
--- **Not for every target.** A `missing` target has nothing to open, and a
--- position preview has no target at all -- it is a fact about a line. Both
--- decline rather than guessing.
---@return boolean opened
function M.open()
  if not (_open and float.win()) then
    return false
  end
  local target = _open.target
  if not target then
    -- A position preview: content about a place, not about a thing.
    return false
  end

  local what
  if target.type == "url" then
    what = target.url or target.raw
  elseif target.type == "missing" or target.type == "git" then
    -- Nothing on disk, or an object id no opener understands.
    return false
  else
    what = target.path or target.raw
  end
  if type(what) ~= "string" or what == "" then
    return false
  end

  local ok_open, open = pcall(require, "open")
  if ok_open and type(open.open) == "function" then
    -- `nil` as the handler is open.nvim's context-aware pick: a browser for a
    -- URL, the configured file manager for a path. `path=` for a path so a
    -- filename that happens to spell one of its scope keywords ("cwd",
    -- "git") is still read as a path.
    local scope = target.type == "url" and what or ("path=" .. what)
    local ok_call = pcall(open.open, nil, scope)
    if ok_call then
      M.hide()
      return true
    end
  end

  if type(vim.ui.open) == "function" then
    local ok_ui = pcall(vim.ui.open, what)
    if ok_ui then
      M.hide()
      return true
    end
  end

  require("hover.notify").warn("nothing here can open " .. what)
  return false
end

---@internal
--- `config.preview_opts()` brought up to where this hover actually is.
---
--- Four things the configuration knows nothing about, and a re-render that
--- forgets any of them silently undoes it: how far the reader has scrolled,
--- which page they are on, how much the float has been resized, and which
--- detail is being magnified. Each of `scroll`, `resize`, `zoom` and `nav`
--- used to build its own table, which is the hand-kept-copy shape this plugin
--- has been bitten by four times -- and it was already wrong: **scrolling a
--- resized hover reset it to the configured size**, because `scroll` never
--- knew about the resize level. One place now, and adding a fifth piece of
--- state is one line rather than four.
---
--- Zen was that fifth piece, and it went in without a line here at all: the
--- box is `box()`'s answer, and that function is where both the resize factor
--- and the full-screen base already live.
---@return Hover.PreviewOpts
local function current_preview_opts()
  local opts = config.preview_opts()
  opts.max_width, opts.max_lines = box()
  if _open then
    opts.page = _open.page
    opts.offset = _open.offset
    opts.zoom = _open.zoom
    opts.zoom_cx = _open.zoom_cx
    opts.zoom_cy = _open.zoom_cy
    opts.requested = _open.requested
  end
  return opts
end

--- Scroll the open hover's content by `delta` steps.
---
--- A page for a PDF (and for an office document, which has become one by the
--- time there is anything to page through), a screenful of lines for a file.
--- Re-renders the same target at a new position; it does **not** re-resolve
--- the cursor, so the hover keeps showing what it was showing even if the
--- cursor has since moved off the target.
---
--- Bound to `scroll_keys` while a scrollable hover is open, and public so a
--- user can bind their own keys. Deliberately no image case: there is
--- nothing to scroll in a picture.
---@param delta integer positive scrolls forward, negative back
---@return boolean scrolled
function M.scroll(delta)
  -- Also the safety net for a mapping that outlived its float by any route
  -- the explicit teardowns do not cover: it takes itself away rather than
  -- silently swallowing the key from then on.
  if not (_open and float.win()) then
    keys.release()
    _open = nil
    return false
  end

  -- A position preview has no target to re-render at a new offset: its
  -- content is whatever the registering plugin produced for this place, once.
  -- Declining is the honest answer -- and `keys.borrow` only binds the scroll
  -- keys for content that declares `scroll`, so reaching here at all means
  -- such content was produced and the key was pressed anyway.
  local target = _open.target
  if not target then
    return false
  end

  local c = config.get()
  local preview_opts = current_preview_opts()

  -- Paged, not scrolled: a PDF, and an office document, which *is* a PDF by
  -- the time anything is drawn -- the conversion is cached, so paging
  -- through a `.docx` costs one rasterize per page and no second LibreOffice
  -- start.
  if _open.paged then
    local next_page = math.max(1, (_open.page or 1) + delta)
    if next_page == _open.page then
      return false
    end
    _open.page = next_page
    preview_opts.page = next_page
  else
    local step = c.max_lines or 20
    local next_offset = math.max(0, (_open.offset or 0) + delta * step)
    if next_offset == _open.offset then
      return false
    end
    _open.offset = next_offset
    preview_opts.offset = next_offset
  end

  -- Bypass the cache: it is keyed by target identity, not by position, so a
  -- cached entry would answer with the page the hover already shows.
  _generation = _generation + 1
  local generation = _generation

  build(target, _open.bufnr, preview_opts, function(content)
    if generation ~= _generation or not content or content.pending then
      return
    end
    -- Paged past the last PDF page: step back and leave what is on screen.
    if content.scroll and content.scroll.past_end then
      _open.page = math.max(1, (_open.page or 1) - delta)
      return
    end
    present(content)
  end)

  return true
end

--- Make the hover on screen larger or smaller by `delta` steps.
---
--- **What one step is.** The box the previewer is given -- `max_width` and
--- `max_lines` -- multiplied by 1.25, and nothing else. Everything downstream
--- happens where it always did: the letterboxing, the inset images.nvim keeps
--- free on every side, the clamp against the terminal.
---
--- **Why that is `resize` and not `zoom`.** For a picture the two coincide:
--- ask for a bigger box and the picture is drawn larger. For text they come
--- apart -- a bigger box shows *more lines*, not larger ones, because the font
--- size belongs to the terminal emulator and Neovim cannot change it. One
--- operation, two honest answers, and only one of them is magnification. A
--- real zoom means cropping the source and moving the crop around, which is
--- `M.zoom` below rather than this function; see `docs/FEATURES/ZOOM.md`.
---
--- **The ceiling is the terminal, and it is found rather than declared.**
--- Measured against a real Neovim on 2026-09-02, 1200x675 image, defaults
--- 80x20:
---
---     terminal 210x55  ->  five steps, 71x20 cells of picture up to 181x51
---     terminal  80x24  ->  no step at all: 20 rows is already `lines - 4`
---
--- Any fixed limit would be wrong on one of those two, so there is none. A
--- step that produces the same float is stepped back off -- the same way
--- `scroll` steps back off the end of a PDF -- and the level then stops
--- exactly where the screen does. That comparison is on the *clamped* size
--- (`float.size_for`), because a clamp is invisible in the content: twenty
--- lines shown for twenty-five asked is a refusal, and a step that missed it
--- would let a held key run the level away.
---
--- A PDF page is not re-rasterized either, so making one bigger costs nothing
--- and is correspondingly unsharp: the same pixels, over more cells. The
--- sharp answer for a page is a second render at a higher DPI, and that is
--- what `zoom` does -- the two are different operations on a page in exactly
--- the way they are on a picture.
---@param delta integer positive makes it bigger, negative smaller
---@return boolean asked `false` when there is no hover to resize. `true` says the re-render was started, not that the float grew -- for a PDF the answer is asynchronous, and the terminal may refuse the step either way.
function M.resize(delta)
  -- The same safety net `scroll` carries: a mapping that outlived its float
  -- takes itself away rather than swallowing the key from then on.
  if not (_open and float.win()) then
    keys.release()
    _open = nil
    return false
  end

  -- A position preview has no target to re-ask, only an id. Resizing one
  -- would mean putting the question back to the registry, which is a
  -- different change; it declines rather than pretending.
  local target = _open.target
  if not target then
    return false
  end

  local before_w, before_h = float.size()
  local level = (_open.resize or 0) + delta
  _open.resize = level

  -- `_open.resize` is already the new level, so this carries it -- along with
  -- the page, the offset and any magnified detail.
  local preview_opts = current_preview_opts()

  -- Bypass the cache, for the same reason `scroll` does: it is keyed by what
  -- a target is, not by how large it is being shown.
  _generation = _generation + 1
  local generation = _generation

  build(target, _open.bufnr, preview_opts, function(content)
    if generation ~= _generation or not content or content.pending then
      return
    end
    local w, h = float.size_for(content.lines, {
      canvas = content.canvas,
      max_width = preview_opts.max_width,
      max_height = preview_opts.max_lines,
    })
    if w == before_w and h == before_h then
      -- The screen refused, not this function. Undo the step so holding the
      -- key does not run the level off somewhere it has to be pressed back
      -- from, and leave the float alone -- it already shows this.
      _open.resize = level - delta
      return
    end
    present(content)
  end)

  return true
end

-- There is deliberately no `M.zoom` alias for `resize` here any more. One was
-- written when `zoom` was renamed (`8ec5b40`, "kept because it was public"),
-- and `9fba190` then defined a *real* `M.zoom` below it -- a different
-- feature, on the same name, silently winning because it comes second. The
-- README claimed the alias still forwarded to `resize`; it had not since the
-- day the real zoom landed. `zoom_keys` is still folded into `resize_keys` by
-- `config.normalize`, which is the half of the rename anyone configures.

---@internal
--- Re-render the open hover with whatever `open` now says. The tail `zoom`
--- and `nav` both end in, and the same shape `resize` and `scroll` use: a
--- fresh generation so a slower answer cannot land afterwards, and the cache
--- bypassed because it is keyed by what a target *is*, not by which part of
--- it is on screen.
---
--- Takes the open hover rather than reading `_open`, and a target rather than
--- reading it back off that: both callers have just had `zoomable` confirm
--- the two are there, and re-reading a field that is typed nilable turns a
--- checked fact back into an unchecked one.
---@param open Hover.Open
---@param target Hover.Target
---@return boolean
local function rerender(open, target)
  _generation = _generation + 1
  local generation = _generation
  build(target, open.bufnr, current_preview_opts(), function(content)
    if generation ~= _generation or not content then
      return
    end
    present(content)
  end)
  return true
end

---@internal
--- The image a zoom would act on, or nil plus the reason it cannot.
---
--- Hands back the open hover and its target alongside the path, so a caller
--- holds all three as non-nil locals. Without that every caller re-reads
--- `_open`, which is nilable by declaration, and the checks below have to be
--- made again at each use -- twelve `need-check-nil` findings' worth, which
--- is how this shape was noticed.
---@return string|nil path
---@return string|nil why
---@return Hover.Open|nil open
---@return Hover.Target|nil target
local function zoomable()
  local open = _open
  if not (open and float.win()) then
    keys.release()
    _open = nil
    return nil, nil
  end
  local target = open.target
  local media = require("hover.preview.media")

  -- A rendered page, and the branch that has to come first because its source
  -- is not `target.path`: the picture is a PNG in this plugin's cache, found
  -- by URL. Everything after it is the same crop.
  if target and target.type == "url" then
    local doc = require("hover.preview.webpdf").cached(target)
    if doc then
      if not media.can_zoom_pdf() then
        return nil, "a sharp page needs pdfport.nvim new enough to rasterize a window of one"
      end
      return doc, nil, open, target
    end
    local png = require("hover.preview.shot").cached(target)
    if not png then
      return nil, "only a rendered page can be zoomed -- `:Hover links web shot` renders one"
    end
    if not media.can_zoom() then
      return nil, "zoom needs images.nvim with `images.convert.crop`, and ImageMagick on PATH"
    end
    return png, nil, open, target
  end

  -- The two halves of "can this be zoomed" are asked separately only so each
  -- can name its own reason; `can_magnify` above is the same test without the
  -- messages, for the borrow site that needs a boolean.
  if not (target and target.path and (target.type == "image" or target.type == "pdf")) then
    return nil, "only a picture or a PDF page can be zoomed"
  end
  if target.type == "pdf" then
    if not media.can_zoom_pdf() then
      return nil, "a sharp page needs pdfport.nvim new enough to rasterize a window of one"
    end
  elseif not media.can_zoom() then
    return nil, "zoom needs images.nvim with `images.convert.crop`, and ImageMagick on PATH"
  end
  return target.path, nil, open, target
end

--- Magnify a detail of the picture on screen, or step back out.
---
--- **This is not `resize`, and the difference is the whole point.** `resize`
--- changes the box and letterboxes the *whole* picture into it: the framing
--- never changes, and it costs no process at all. A zoom keeps the box and
--- cuts the source, so what is on screen is a smaller part of the picture,
--- larger. That needs a cropped file.
---
--- **Measured before it was built, and the number decided the shape.** On
--- Windows, 2026-09-02: a `magick` start is 71 ms, and cropping a 1920x1080
--- screenshot and fitting it costs **258 ms** -- a dense image of that size
--- 502 ms, a 4K source ~900 ms. No format or compression setting brought it
--- under ~150 ms, and batching crops into one process saved only the start.
--- So a zoom step is not a dial to hold down; it is a deliberate press,
--- answered through the same placeholder machinery as a PDF page, which it
--- happens to beat (1150 ms for one page, measured the same day).
---
--- The ceiling is capped rather than discovered, which is the opposite of how
--- `resize` finds its own: there only the terminal knows where the room ends,
--- here the limit is the source's own pixels and can be answered without
--- spending a `magick` run to find out.
---
--- **A PDF page is the same gesture on a different mechanism.** What is on
--- screen is a rasterization in this plugin's cache, not the file the target
--- names, so cropping it magnifies a bitmap that already holds every pixel it
--- ever will. The page is re-rendered instead: the DPI goes up by the same
--- factor the view narrows by, and only the visible window is rasterized.
--- Measured 2026-09-03 -- **120-600 ms a step at any depth**, against the
--- 3.3 s that had this parked as a decision rather than a feature, because
--- that number was for re-rendering the *whole* page. The ceiling is a DPI
--- rather than a pixel count: a vector page is sharp at any resolution, so
--- there is nothing to discover and the limit has to be chosen. See
--- `hover.preview.media.pdf`.
---@param delta integer positive magnifies, negative steps back out
---@return boolean asked
function M.zoom(delta)
  local path, why, open, target = zoomable()
  if not (path and open and target) then
    if why then
      require("hover.notify").info(why)
    end
    return false
  end

  local media = require("hover.preview.media")
  -- A link that answered with a PDF is a page like any other: re-rendered at a
  -- higher DPI rather than cropped. `_open.paged` is what `present` recorded
  -- from the content, so this needs no second type test.
  local is_page = target.type == "pdf" or (target.type == "url" and open.paged == true)

  -- A picture's ceiling is its own pixels, so they are read once and kept. A
  -- page has none -- it is re-rendered from the document at whatever DPI is
  -- asked for -- so there is nothing to measure and nothing to remember.
  local px
  if not is_page then
    px = open.zoom_px or media.pixel_size(path)
    if not px then
      require("hover.notify").info("cannot read this picture's size, so cannot zoom it")
      return false
    end
    open.zoom_px = px
  end

  local was = open.zoom or 0
  local level = math.max(0, was + delta)
  if level == was then
    return false
  end
  if level > was then
    if is_page then
      if not media.pdf_zoom_possible(level) then
        require("hover.notify").info("no more resolution worth rendering for this page")
        return false
      end
    elseif not media.zoom_possible(px, level) then
      require("hover.notify").info("no more detail in this picture")
      return false
    end
  end

  open.zoom = level
  if level == 0 then
    -- Back to the whole picture, and back to the middle: a centre kept from a
    -- zoomed view means nothing once the whole picture is on screen, and
    -- keeping it would make the next zoom start somewhere nobody chose.
    open.zoom_cx, open.zoom_cy = nil, nil
  end
  return rerender(open, target)
end

--- Move the magnified view, in fractions of what is currently visible.
---
--- A step is a quarter of the visible rectangle, so four of them cross the
--- view once: far enough to be worth a press at a quarter-second a move, near
--- enough that nothing is skipped over. The centre is kept as a fraction of
--- the source rather than in pixels, so it survives a zoom step -- going
--- deeper keeps looking at the same place. Both kinds of magnified view move
--- the same way; only what happens underneath differs (a crop for a picture,
--- a re-render for a page).
---@param dx integer -1 left, 1 right
---@param dy integer -1 up, 1 down
---@return boolean asked
function M.nav(dx, dy)
  local path, _, open, target = zoomable()
  if not (path and open and target) then
    return false
  end
  if (open.zoom or 0) <= 0 then
    -- The whole picture is on screen; there is nothing outside the view to
    -- move towards. Declining is honest, and the keys are not bound in that
    -- state anyway.
    return false
  end

  local step = 0.25 / (ZOOM_VIEW_STEP ^ (open.zoom or 0))
  local cx = math.max(0, math.min(1, (open.zoom_cx or 0.5) + dx * step))
  local cy = math.max(0, math.min(1, (open.zoom_cy or 0.5) + dy * step))
  if cx == (open.zoom_cx or 0.5) and cy == (open.zoom_cy or 0.5) then
    -- Already against that edge. `zoom_rect` clamps the rectangle inside the
    -- source anyway, so this only saves a `magick` run that would produce the
    -- picture already on screen.
    return false
  end

  open.zoom_cx, open.zoom_cy = cx, cy
  return rerender(open, target)
end

--- Put the hover on screen full screen, or take it back.
---
--- **This is not "make the window bigger", and everything about the feature
--- follows from that.** Every previewer renders against a budget --
--- `max_lines` and `max_width` decide how many lines are read, at what DPI a
--- PDF page is rasterized, how large a picture is drawn. A float that merely
--- opened larger would show the same twenty lines with a great deal of
--- margin. So zen replaces the *base* of that budget with the editor's own
--- size and builds the preview again against it, which is the same machinery
--- `resize` uses with a factor where this has a destination (`box`).
---
--- **It is why the screenshot preview is worth having at all**, and the
--- reason it was built first. Measured 2026-09-04: a page screenshot is
--- 1280x900 px, a default float 80x20 cells is roughly 640x340 -- fitting one
--- into the other is height-limited at about 0.38, which turns 16 px body
--- text into 6 px. Unreadable. The same problem exists in weaker form for
--- every picture, every PDF page and every office document, which is why this
--- applies to all of them rather than to pages.
---
--- **Two honest answers, the same pair `resize` gives.** A picture or a page
--- is drawn larger; a text preview shows *more lines*, because the font size
--- belongs to the terminal emulator. Twenty lines becomes fifty, which is
--- most of a screenful of the file being pointed at.
---
--- **Pinning, and why it is coupled but not fused.** The float is
--- `focusable = false` and the dismissal hangs on `CursorMoved`, so every key
--- that is not borrowed takes it away -- correct for a small annotation, and
--- absurd for a float filling the screen, which would close on the first `j`.
--- So `zen.pin` (on by default) pins on the way in, and leaving zen releases
--- that pin **only when zen was what took it**: a float the reader pinned
--- before going full screen stays pinned afterwards. `zen.pin = false` is for
--- anyone who wants the transient reading instead.
---
--- Declines for a position preview, and for the reason `resize` does: there
--- is no target to ask again, only an id, and its content was produced once
--- by the plugin that answered.
--- Returns the reason alongside the refusal rather than emitting it, the way
--- `why` and `status` already do (`ERR-04`): the three ways this declines are
--- not one answer, and only two of them are worth a message. "It is already
--- full screen" is what an explicit `:Hover zen on` twice means, and saying
--- so would be noise.
---@param on? boolean explicit state; omitted toggles
---@return boolean asked `false` when there is no hover this can act on. `true` says the re-render was started, not that the float grew.
---@return string|nil why present only where the refusal is worth reporting
function M.zen(on)
  -- The safety net `scroll` and `resize` carry: a mapping that outlived its
  -- float takes itself away rather than swallowing the key from then on.
  if not (_open and float.win()) then
    keys.release()
    _open = nil
    return false, "no hover to put full screen"
  end

  local open = _open
  local target = open.target
  if not target then
    return false, "a position preview has no target to render again, so no zen"
  end

  if on == nil then
    on = not (open.zen == true)
  end
  if on == (open.zen == true) then
    return false
  end

  open.zen = on or nil

  -- Before the re-render, not after: `present` reads `_open.pinned` to put the
  -- marker back on the window it is about to open, so the pin has to be
  -- decided by the time it draws.
  if on then
    if config.zen_pins() and not open.pinned then
      M.pin(true)
      open.zen_pinned = true
    end
  elseif open.zen_pinned then
    M.pin(false)
    open.zen_pinned = nil
  end

  return rerender(open, target)
end

--- Whether the hover on screen is full screen.
---@return boolean
function M.zenned()
  return (_open and _open.zen) == true
end

--- Close any open hover.
---
--- Bumps the generation counter as well: a PDF page still rasterizing when
--- this is called would otherwise land afterwards and open a float for a
--- hover that has already been closed.
---@return nil
function M.hide()
  if _open then
    _open.pinned = nil
  end
  keys.release()
  _open = nil
  _generation = _generation + 1
  float.close()
end

--- Close the hover on screen and keep it closed for as long as the cursor
--- stays on the same target.
---
--- **Why closing alone is not enough.** Under the `CursorHold` trigger the
--- event fires again after any keystroke followed by `'updatetime'` of quiet
--- -- cursor movement or not. A key bound to `hide()` would make the float
--- disappear and then bring it straight back, while the reader is still
--- standing on the path they wanted out of the way.
---
--- The suppression ends by itself: the next target the cursor resolves --
--- another path, or none at all -- clears it. That is the whole difference
--- between this and `set_mode("off")`, and why both exist. This one is for
--- "not now, I am reading this line"; the mode is for "not for a while", and
--- only the mode has to be remembered and undone.
---@return boolean dismissed false when no hover was open
function M.dismiss()
  if not _open then
    return false
  end
  -- A position preview carries its own identity, already built by
  -- `show_position`; a target's is derived from the target.
  if _open.position then
    _suppressed = _open.position
    M.hide()
    return true
  end
  _suppressed = identity(_open.target)
  M.hide()
  return true
end

--- Debounced entry point used by the trigger autocmds.
---@return nil
function M.trigger()
  if not config.is_auto() then
    return
  end

  local delay = config.get().delay_ms or 250
  -- Rebuilt when the delay changes, so `setup({ delay_ms = ... })` after the
  -- first hover is not silently ignored for the rest of the session.
  if not _debounced or _debounced_delay ~= delay then
    local ok, debounce = pcall(require, "lib.nvim.debounce")
    if ok and debounce and debounce.new then
      _debounced = debounce.new(function()
        M.show()
      end, delay)
    else
      -- Without lib.nvim.debounce, run undebounced rather than not at all.
      _debounced = {
        call = function()
          M.show()
        end,
        cancel = function() end,
      }
    end
    _debounced_delay = delay
  end
  _debounced.call()
end

-- ---------------------------------------------------------------------------
-- Switches
-- ---------------------------------------------------------------------------

--- The mode in effect right now.
---@return Hover.Mode
function M.mode()
  return config.mode()
end

--- Set the mode for the rest of the session.
---
--- Two things this has to do beyond writing the field:
---
---  * **Re-install the autocmds.** Going from "auto" to "manual" has to take
---    the triggers away from buffers that already have them, and going the
---    other way has to give them to buffers opened while there were none.
---    Flipping a flag alone would leave both halves silently wrong, which
---    reads as "the switch only half works".
---  * **Clear any dismissal.** A dismissal is scoped to "the target the
---    cursor is on right now", and throwing the session switch is not that.
---    Left standing, it would survive an off/on cycle as invisible state.
---@param mode Hover.Mode
---@return Hover.Mode|nil mode, string|nil err
function M.set_mode(mode)
  if mode ~= "auto" and mode ~= "manual" and mode ~= "off" then
    return nil, ("unknown mode %q (auto|manual|off)"):format(tostring(mode))
  end

  _suppressed = nil
  config.raw().mode = mode
  -- `vim.g` is where a user says this from a plugin spec, before anything
  -- loads. Keeping the two in step means one setting rather than two that
  -- can disagree.
  vim.g.hover_disable = (mode == "off") or nil

  require("hover.bindings.autocmds").detach_all()
  if mode == "off" then
    M.hide()
  else
    require("hover.bindings.autocmds").enable()
  end

  local note = mode == "auto" and "hover on (opens by itself)"
    or mode == "manual" and "hover manual (`:Hover show` or your own key)"
    or "hover off"
  require("hover.notify").info(note)

  return mode
end

--- Read or change which target types open a float by themselves.
---
--- `nil` reports and changes nothing; a type name toggles that one; `"all"`
--- and `"none"` set every one at once. Returns the sentence to show, so the
--- route does not compose one and this is testable without capturing
--- notifications.
---
--- **No cache reset here, unlike the switches.** The preview cache is keyed
--- by what a target *is*, and this changes nothing about how any target is
--- rendered — only whether the trigger asks. A cached preview stays exactly
--- as valid as it was, and dropping it would make the next explicit request
--- pay for a decision that was not about it.
---@param which string|nil `nil` reports, `"all"`/`"none"`, or one type name.
---@return string|nil report, string|nil err
function M.set_auto(which)
  local names = require("hover.config.auto_types")()
  local raw = config.raw()
  if type(raw.auto_hover) ~= "table" then
    -- The boolean forms are folded by `config.normalize` before they are
    -- stored, so this only happens to a caller that wrote the field directly.
    local all = raw.auto_hover == true
    raw.auto_hover = {}
    for _, name in ipairs(names) do
      raw.auto_hover[name] = all
    end
  end

  if which == nil then
    local on, off = {}, {}
    for _, name in ipairs(names) do
      table.insert(config.auto_hover_for(name) and on or off, name)
    end
    return ("opens by itself: %s  ·  only on request: %s"):format(
      #on > 0 and table.concat(on, ", ") or "nothing",
      #off > 0 and table.concat(off, ", ") or "nothing"
    )
  end

  if which == "all" or which == "none" then
    local value = which == "all"
    for _, name in ipairs(names) do
      raw.auto_hover[name] = value
    end
    return value and "every type opens by itself"
      or "nothing opens by itself (`:Hover show` still answers)"
  end

  if not vim.tbl_contains(names, which) then
    return nil,
      ("unknown type %q (%s, or all|none)"):format(tostring(which), table.concat(names, "|"))
  end

  local now = not config.auto_hover_for(which)
  raw.auto_hover[which] = now
  return ("%s %s by itself"):format(which, now and "opens" or "does not open")
end

--- Read or change the border style.
---
--- Cosmetic, and the only setting in this plugin that is. It earns its route
--- for a reason that is not taste: two of the styles have no name in Neovim
--- (`heavy`, `ascii`) and would otherwise be eight characters written by hand,
--- and a style is a thing you try rather than decide -- so it changes the
--- float that is already on screen instead of the next one.
---
--- A hand-written eight-character list stays valid in `setup()`; this route
--- only deals in names, because those are what can be typed.
---@param name string|nil `nil` reports, otherwise a name from `float.border_names()`.
---@return string|nil report, string|nil err
function M.set_border(name)
  local float_mod = require("hover.float")
  local names = float_mod.border_names()

  if name == nil then
    local current = config.get().border
    return ("border: %s  ·  available: %s"):format(
      type(current) == "string" and current or "custom",
      table.concat(names, ", ")
    )
  end

  if not vim.tbl_contains(names, name) then
    return nil, ("unknown border %q (%s)"):format(tostring(name), table.concat(names, "|"))
  end

  config.raw().border = name
  -- Shown now rather than at the next hover: see `float.set_border`.
  float_mod.set_border(name)
  return ("border: %s"):format(name)
end

--- Whether a hover would open at all right now -- true in both "auto" and
--- "manual", false only when it is switched off.
---@return boolean
function M.is_enabled()
  return config.is_enabled()
end

--- Turn the hover off for the rest of the session, or back on.
---
--- The coarse switch: "off" and back to "auto". `set_mode` is the one with
--- three positions.
---@param on? boolean explicit state; omitted flips the current one
---@return boolean on
function M.toggle(on)
  if on == nil then
    on = not config.is_enabled()
  end
  M.set_mode(on and "auto" or "off")
  return on
end

--- Turn one feature switch on, off, or over. Names come from
--- `hover.switches`: `links`, `web`, `fetch`, `paths`, `missing`, `images`,
--- `office`.
---@param name string
---@param on? boolean explicit state; omitted flips the current one
---@return boolean|nil on, string|nil err
function M.set(name, on)
  return switches.set(name, on)
end

--- Whether one feature switch is in effect, implications included.
---@param name string
---@return boolean
function M.enabled(name)
  return switches.enabled(name)
end

--- Everything that is on or off right now, for a statusline, a report, or
--- `:checkhealth`.
---
--- Three axes, because three different things can silence a hover and they
--- look identical from the outside: the mode, the feature switches, and
--- `auto_hover` -- which decides not *whether* a type hovers but whether it
--- does so unprompted. A report that carried only the first two answered
--- "everything is on" for a session where nothing opened by itself.
---
--- `auto` is a list rather than the map `config.auto_hover()` returns,
--- because every consumer of this prints it and a map has no order.
---@return { mode: Hover.Mode, switches: { name: string, label: string, enabled: boolean, flag: boolean, implies: string|nil, route: string[] }[], auto: { name: string, enabled: boolean }[] }
function M.status()
  local auto = {}
  for _, name in ipairs(require("hover.config.auto_types")()) do
    auto[#auto + 1] = { name = name, enabled = config.auto_hover_for(name) }
  end
  return { mode = config.mode(), switches = switches.status(), auto = auto }
end

return M
