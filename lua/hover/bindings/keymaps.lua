---@module 'hover.bindings.keymaps'
---@brief The keys a hover borrows while it is on screen, and the one it may own.
---@description
--- Two unrelated jobs that both happen to be keymaps.
---
--- **Borrowed keys** (`borrow`/`release`) exist only for as long as one
--- float is up. They are global rather than buffer-local because the float
--- is `focusable = false`: it never receives a keystroke and can never hold
--- a mapping of its own, and a buffer-local mapping on the *document* would
--- leak into buffers with no hover open.
---
--- Restoring rather than deleting is not a nicety. `<C-Up>` and `q` are keys
--- a user may well have mapped, and a hover that takes one for a single
--- float has to give it back -- so what was there is captured with
--- `maparg(..., true)` before the mapping is set, and put back with
--- `mapset` after.
---
--- **Owned keys** (`setup`) are the user's own configuration, bound once and
--- kept. There is exactly one, `keymaps.show`, and it is `false` by default:
--- a plugin that other plugins depend on has no business claiming a key on
--- their behalf.
---
---@see hover.config

local M = {}

---@internal
--- Deferred back-reference. `hover` requires this module, so requiring it
--- back at file scope is a load-time cycle -- resolvable only by taking the
--- reference inside a function body, where the parent module is already in
--- `package.loaded`.
---@return table
local function hover()
  -- Bound first: `require` returns the module *and* the loader value, and
  -- returning the call directly would declare a one-value function that
  -- yields two (`ERR-64`).
  local mod = require("hover")
  return mod
end

---@type Hover.BoundKey[] Keys currently held for the float on screen.
local _held = {}

--- Normalize one configured key list. A bare string is a single key; `false`,
--- `nil` and the empty list are all "no key at all", which is how a user
--- turns one direction -- or the whole binding -- off.
---@param v string|string[]|false|nil
---@return string[]
function M.keylist(v)
  if type(v) == "string" then
    return { v }
  elseif type(v) == "table" then
    return v
  end
  return {}
end

--- Hand back every key currently held, restoring whatever each displaced.
---@return nil
function M.release()
  for _, k in ipairs(_held) do
    pcall(vim.keymap.del, "n", k.lhs)
    if k.saved then
      pcall(vim.fn.mapset, "n", false, k.saved)
    end
  end
  _held = {}
end

---@internal
--- Take one key, remembering the mapping it displaced.
---@param seen table<string, boolean> keys already taken in this pass
---@param lhs any
---@param rhs fun()
---@param desc string
---@return nil
local function take(seen, lhs, rhs, desc)
  -- The same key listed twice -- both scroll directions, or a dismiss key
  -- that is also a scroll key -- would, on release, restore one of our own
  -- mappings as if it had been the user's, and then it would outlive the
  -- float forever.
  if type(lhs) ~= "string" or lhs == "" or seen[lhs] then
    return
  end
  seen[lhs] = true

  local raw = vim.fn.maparg(lhs, "n", false, true)
  -- A separate local, not an overwrite of `raw`: `maparg`'s dict form is
  -- typed as a table, and nilling that same variable is a type change rather
  -- than a narrowing (`LLS-30`).
  ---@type table|nil
  local saved = (type(raw) == "table" and raw.lhs ~= nil) and raw or nil

  local ok = pcall(vim.keymap.set, "n", lhs, rhs, { desc = desc, nowait = true, silent = true })
  if ok then
    _held[#_held + 1] = { lhs = lhs, saved = saved }
  end
end

--- Bind the keys the hover on screen borrows: the dismiss keys always, the
--- scroll keys only when there is something to scroll.
---
--- The asymmetry is the point. Every hover can be waved away, so `q` and
--- `<Esc>` are bound for all of them -- including a picture, which has
--- nothing to scroll. Scrolling an image, or a file that already fits in the
--- float, is meaningless, so those keys are left alone entirely and keep
--- whatever they mean elsewhere.
---@param content Hover.Content|nil
---@param rerender fun(delta: integer)
---@return nil
function M.borrow(content, rerender)
  M.release()

  local cfg = require("hover.config").get()
  local seen = {}

  -- Dismiss first, so a key configured for both wins as a dismissal: the one
  -- that always works beats the one that only sometimes applies.
  for _, lhs in ipairs(M.keylist(cfg.dismiss_keys)) do
    take(seen, lhs, function()
      hover().dismiss()
    end, "hover: dismiss this hover")
  end

  local s = content and content.scroll
  -- Nothing below and nothing above: not scrollable in either direction.
  local at_start = s and (s.offset or 0) == 0 and (s.page or 1) == 1
  if s and (s.more or not at_start) then
    local sk = type(cfg.scroll_keys) == "table" and cfg.scroll_keys or {}
    for _, lhs in ipairs(M.keylist(sk.down)) do
      take(seen, lhs, function()
        rerender(1)
      end, "hover: scroll preview down")
    end
    for _, lhs in ipairs(M.keylist(sk.up)) do
      take(seen, lhs, function()
        rerender(-1)
      end, "hover: scroll preview up")
    end
  end
end

--- Whether any key is currently held. Read by `:checkhealth hover`, which
--- would otherwise have to guess.
---@return boolean
function M.is_borrowing()
  return #_held > 0
end

---@type boolean Guard for an idempotent `setup()`; module-local, not global.
local _owned = false

--- Bind the keymaps the user configured this plugin to own.
---
--- Idempotent, and every entry is individually disableable through
--- `keymaps.<name> = false` -- which is also the default, so a plugin that
--- never asked for a key never gets one.
---@return nil
function M.setup()
  if _owned then
    return
  end
  local keymaps = require("hover.config").get().keymaps
  if type(keymaps) ~= "table" then
    return
  end
  _owned = true

  for _, lhs in ipairs(M.keylist(keymaps.show)) do
    pcall(vim.keymap.set, "n", lhs, function()
      -- `force`, because a key pressed on purpose is not the volume problem
      -- the switches exist to solve: it answers for a web link with the web
      -- switch off, and in `mode = "manual"`, which is the mode it is for.
      hover().show({ force = true })
    end, { desc = "Hover: show what is under the cursor" })
  end
end

--- Drop the owned keymaps, so a re-`setup()` binds them afresh. Paired with
--- `setup()` for a teardown-then-setup cycle (`PRIN-01`: the flag is
--- module-local, never a global).
---@return nil
function M.teardown()
  if not _owned then
    return
  end
  local keymaps = require("hover.config").raw().keymaps
  for _, lhs in ipairs(M.keylist(type(keymaps) == "table" and keymaps.show or nil)) do
    pcall(vim.keymap.del, "n", lhs)
  end
  _owned = false
end

return M
