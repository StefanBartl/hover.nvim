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
    local target, extra = require("hover.registry").source_at(bufnr, row, col)
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

  -- Nothing claimed it: the text may be a path carrying no link syntax at
  -- all. Same target shape, so everything downstream is unchanged.
  if not (force or config.paths_enabled()) then
    return nil
  end
  return require("hover.bare_path").under_cursor(bufnr, {
    -- Forced, the broken-target marker is wanted: "there is nothing here"
    -- is the answer someone asking about this exact text came for.
    missing = force or config.missing_enabled(),
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

  local bufnr = api.nvim_get_current_buf()
  local found = M.target_under_cursor(bufnr, { force = opts.force })
  if not found then
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
  local target = classify.classify(found.target, source ~= "" and source or nil)

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

  local target = _open.target
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
