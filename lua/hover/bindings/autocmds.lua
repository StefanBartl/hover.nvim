---@module 'hover.bindings.autocmds'
---@brief What wakes the hover, and which buffers it wakes in.
---@description
--- **Why the plugin installs its own trigger.** While this framework lived
--- inside `lib.nvim`, the only thing that turned it on was markdown.nvim's
--- own `FileType` autocmd -- and that plugin is lazy-loaded on markdown
--- filetypes. Open a `.txt` in a fresh session and markdown.nvim never
--- loads, so nothing ever attached: the hover worked in other filetypes only
--- after some markdown file had been opened first, which reads as "it
--- randomly doesn't work". A feature that is explicitly not about markdown
--- cannot have its trigger gated on a markdown plugin loading.
---
--- **Two triggers, and the difference matters.** `CursorHold` follows
--- `'updatetime'` -- a global usually set for something else entirely -- and
--- fires after *any* keystroke followed by quiet, cursor movement or not.
--- That is also the root of why the dismissal has to suppress rather than
--- close: a float dismissed with `hide()` comes straight back while the
--- reader stands still. The `"cursor"` trigger is `CursorMoved` plus this
--- plugin's own debounce, so `delay_ms` means what it says and nothing fires
--- while the cursor does not move.
---
---@see hover.config
---@see hover.bindings.keymaps

local M = {}

local api = vim.api
local autocmd = require("lib.nvim.bindings.autocmd")

---@internal
--- Deferred back-reference; see the note in `hover.bindings.keymaps`.
---@return table
local function hover()
  -- Bound first: `require` returns the module *and* the loader value, and
  -- returning the call directly would declare a one-value function that
  -- yields two (`ERR-64`).
  local mod = require("hover")
  return mod
end

--- Whether anything installed could actually produce a hover.
---
--- hover.nvim can be installed with none of its optional contributors, so a
--- user must not pay for autocmds that can never show anything. Two ways to
--- be useful, and at least one has to hold:
---
---  * a registered source (markdown.nvim's link scanner), or
---  * bare-path detection, which needs nothing installed at all.
---
--- Previews are deliberately *not* checked. Every target type has a built-in
--- answer here -- a file gets its first lines, a directory its entries, an
--- image without any drawing provider still gets its dimensions and size
--- from `preview.media`'s metadata path. A missing images.nvim or pdfport
--- degrades a picture to a description; it never makes the hover useless.
---@return boolean
function M.anything_to_show()
  local config = require("hover.config")
  if config.paths_enabled() then
    return true
  end
  local registry = require("hover.registry")
  if registry.has_sources() then
    return true
  end
  -- A position preview answers without a target, so a buffer where nothing
  -- else could is still worth waking for -- as long as the class is on.
  -- Missing this is how the whole kind would silently do nothing in exactly
  -- the configuration someone would build to try it out.
  return config.positions_enabled() and registry.has_positions()
end

--- Install the hover autocmds for `bufnr`.
---
--- The hover attaches on every filetype by default (a path is not a markdown
--- phenomenon), so the buffers that must be excluded are excluded here
--- rather than by pattern: a picker, a file tree, a terminal or a dashboard
--- has no document to hover in, and a float opening over one is always
--- wrong. A non-empty `'buftype'` catches all of them in one check, which a
--- filetype blocklist could never keep up with.
---@param bufnr integer
---@return nil
function M.attach(bufnr)
  local config = require("hover.config")
  if not config.is_enabled() then
    return
  end
  if not require("lib.nvim.safe_api").is_valid_buffer(bufnr) then
    return
  end
  if vim.bo[bufnr].buftype ~= "" then
    return
  end
  -- Nothing registered and bare paths off: no autocmd at all, rather than
  -- one that wakes on every CursorHold to find there is nothing it can
  -- answer with.
  if not M.anything_to_show() then
    return
  end

  local group = autocmd.group("HoverBuf" .. bufnr, true)

  -- `mode = "manual"` gets the hide autocmds below and no trigger: an
  -- explicit `show({ force = true })` still answers in full, and nothing
  -- opens a float on its own. That is the whole mode.
  if config.is_auto() then
    local triggers = config.get().trigger or { "CursorHold" }

    if vim.tbl_contains(triggers, "CursorHold") then
      autocmd.create("CursorHold", function()
        hover().trigger()
      end, {
        group = group,
        buffer = bufnr,
        desc = "[hover.nvim] show the target under the cursor on CursorHold",
      })
    end

    if vim.tbl_contains(triggers, "cursor") then
      autocmd.create("CursorMoved", function()
        hover().trigger()
      end, {
        group = group,
        buffer = bufnr,
        desc = "[hover.nvim] show the target under the cursor, debounced by delay_ms",
      })
    end

    if vim.tbl_contains(triggers, "mouse") then
      -- Mouse hovering needs 'mousemoveevent'; it is a global user setting
      -- and is deliberately NOT set here (see the README) -- without it this
      -- autocmd simply never fires.
      autocmd.create("CursorMoved", function()
        hover().trigger()
      end, {
        group = group,
        buffer = bufnr,
        desc = "[hover.nvim] show the target under the mouse (needs 'mousemoveevent')",
      })
    end
  end

  autocmd.create({ "BufLeave", "InsertEnter" }, function()
    -- Not `hide()`: leaving the buffer and entering insert are exactly the
    -- moments someone pinned a float *for*.
    hover().hide_unless_pinned()
  end, {
    group = group,
    buffer = bufnr,
    desc = "[hover.nvim] hide when leaving the buffer or entering insert",
  })
end

--- Switch the hover on globally: install the `FileType` autocmd that
--- attaches it to every matching buffer, and attach it to the buffers that
--- are already open.
---
--- Idempotent -- the augroup is cleared on each call, so calling it from two
--- plugins leaves one autocmd, not two. Already-open buffers are attached
--- directly, because `FileType` has long since fired for them and would
--- otherwise leave the very buffer the user is sitting in without a hover
--- until they reopen it.
---@return nil
function M.enable()
  local config = require("hover.config")
  if not config.is_enabled() then
    return
  end

  local group = autocmd.group("HoverEnable", true)
  autocmd.create("FileType", function(ev)
    M.attach(ev.buf)
  end, {
    group = group,
    pattern = config.get().filetypes or "*",
    desc = "[hover.nvim] attach the path/link hover to this buffer",
  })

  for _, buf in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(buf) then
      pcall(M.attach, buf)
    end
  end
end

--- Remove every autocmd this module installed, in every buffer.
---
--- Needed by the mode switch: going from "auto" to "manual" has to take the
--- triggers away from buffers that already have them, and re-`enable()`
--- alone only re-registers -- `autocmd.group(..., true)` clears the group it
--- is given, and the per-buffer groups are not that one.
---@return nil
function M.detach_all()
  pcall(autocmd.group, "HoverEnable", true)
  for _, buf in ipairs(api.nvim_list_bufs()) do
    pcall(autocmd.group, "HoverBuf" .. buf, true)
  end
end

return M
