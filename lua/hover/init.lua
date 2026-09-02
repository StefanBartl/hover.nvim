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

-- ---------------------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------------------

--- Configure the hover. Merged over the current values, so a host can set
--- only what it cares about, and calling it twice does not reset the rest.
---
--- The pre-move option names (`enabled`, `bare_paths`, `url = { ... }`) are
--- still accepted and normalized -- see `hover.config`.
---@param opts? Hover.Config
---@return Hover.Config
function M.setup(opts)
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
    config.setup(opts)
  end
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
---@param run fun(on_result: fun(content: Hover.Content)): Hover.Content
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
    emit(require("hover.preview.media").image(target, opts))
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
    if opts.url_fetch then
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
--- Put `content` on screen: open the float, draw a picture into it if there
--- is one, and take the keys this hover borrows.
---@param content Hover.Content|nil
---@return nil
local function present(content)
  if not content then
    return
  end
  local c = config.get()

  float.open(content.lines, {
    title = content.title,
    filetype = content.filetype,
    canvas = content.canvas,
    highlight = content.highlight,
    max_width = c.max_width or 80,
    max_height = c.max_lines or 20,
    border = c.border,
    -- The float dismisses itself on the next cursor move, through an autocmd
    -- this module never hears about. Without a hook there, the keys it
    -- borrowed would stay bound until the next trigger -- up to 'updatetime'
    -- in which `q` records no macro and `<Esc>` does nothing, long after the
    -- float they belonged to is gone.
    on_close = keys.release,
  })

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

  keys.borrow(content, M.scroll)
end

-- ---------------------------------------------------------------------------
-- Showing, hiding, scrolling
-- ---------------------------------------------------------------------------

--- Show the hover for the target under the cursor. No-op when there is none.
---@param opts? { force?: boolean } `force` ignores every volume switch.
---@return boolean shown
function M.show(opts)
  opts = opts or {}
  if not opts.force and not config.is_enabled() then
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
  _open = { target = target, bufnr = bufnr, offset = 0, page = 1 }

  -- Deliberately not widened by `force`. Volume gates open for an explicit
  -- request; the fetch does not, because a keypress asking "what is this"
  -- is not consent to tell the link's host about it.
  local preview_opts = config.preview_opts()
  -- `init.lua:42` out of a log or a stack trace: show line 42, not the
  -- file's first twenty lines, which are almost never the ones being asked
  -- about. Sources that name no line leave this nil and nothing changes.
  preview_opts.line = found.line
  preview_opts.line_end = found.line_end

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
  if not require("hover.registry").has_positions() then
    return false
  end
  if not opts.force and not config.positions_enabled() then
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
  _open = { position = id, bufnr = bufnr, row = row }
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
  local preview_opts = config.preview_opts()

  -- Paged, not scrolled: a PDF, and an office document, which *is* a PDF by
  -- the time anything is drawn -- the conversion is cached, so paging
  -- through a `.docx` costs one rasterize per page and no second LibreOffice
  -- start.
  if target.type == "pdf" or target.type == "office" then
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
---@return { mode: Hover.Mode, switches: { name: string, label: string, enabled: boolean, implies: string|nil }[] }
function M.status()
  return { mode = config.mode(), switches = switches.status() }
end

return M
