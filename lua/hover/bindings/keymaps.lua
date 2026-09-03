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

---@internal
--- Whether the mouse pointer is over the float on screen.
---
--- Asked only for the wheel, and only because a wheel *points*: `+` acts on
--- the one float there is, wherever the pointer happens to be, and a wheel
--- has to act on what it is aimed at or it is not a wheel.
---
--- `getmousepos()` is used for its coordinates and **not** for its `winid`:
--- the float is `focusable = false`, and a non-focusable float is invisible
--- to that field -- measured 2026-09-02, it names the window underneath. The
--- rectangle test lives in `hover.float`, which owns that geometry.
---@return boolean
local function pointer_over_float()
  local ok, pos = pcall(vim.fn.getmousepos)
  if not ok or type(pos) ~= "table" then
    return false
  end
  return require("hover.float").contains(pos.screenrow, pos.screencol)
end

--- Bind the keys the hover on screen borrows: the dismiss keys always, the
--- scroll keys only when there is something to scroll, `+` / `-` only when
--- there is a picture, and the resize wheel for anything at all.
---
--- The asymmetry is the point. Every hover can be waved away, so `q` and
--- `<Esc>` are bound for all of them -- including a picture, which has
--- nothing to scroll. Scrolling an image, or a file that already fits in the
--- float, is meaningless, so those keys are left alone entirely and keep
--- whatever they mean elsewhere.
---
--- **Navigating is the narrowest condition of them all, and the best argued.**
--- `nav_keys` are bound only while the hover is *zoomed in* -- not merely
--- drawn. They are motions, like `+` and `-`, but with one difference that
--- settles it: the thing `h` would otherwise do over a float is move the
--- cursor, and the dismissal hangs on `CursorMoved`, so the unbound key takes
--- the picture away. Nobody presses `h` at a magnified picture meaning that.
---
--- **Resize is bound on two different conditions, and the split is about
--- what a key costs.** `+` and `-` are real motions in normal mode; taking
--- them over a picture is worth it, taking them over every float that happens
--- to be up is not. So they stay on `content.canvas` -- what a drawn hover has
--- and a text one does not. The wheel costs nobody anything and applies to any
--- hover, and `:Hover resize` costs no key at all.
--- **Why the handlers arrive in a table.** This started with one condition
--- and one callback, grew a second, and the third is where a positional
--- argument stops being readable -- `borrow(c, f, g, h, true)` says nothing
--- about which of them pans. A fourth condition is one key here.
---@param content Hover.Content|nil
---@param handlers { next_answer?: fun(), has_answers?: boolean, scroll?: fun(delta: integer), resize?: fun(delta: integer), nav?: fun(dx: integer, dy: integer), zoom?: fun(delta: integer), zoomed?: boolean, zoomable?: boolean }
---@return nil
function M.borrow(content, handlers)
  handlers = handlers or {}
  local rerender, resize = handlers.scroll, handlers.resize
  local nav, zoom = handlers.nav, handlers.zoom
  local next_answer = handlers.next_answer
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

  -- Before the scroll keys, so a key configured for both opens rather than
  -- scrolls: opening is the action a reader means by pressing something, and
  -- scrolling has two keys of its own either way.
  for _, lhs in ipairs(M.keylist(cfg.open_keys)) do
    take(seen, lhs, function()
      hover().open()
    end, "hover: open what this hover is showing")
  end

  local s = content and content.scroll
  -- Nothing below and nothing above: not scrollable in either direction.
  local at_start = s and (s.offset or 0) == 0 and (s.page or 1) == 1
  -- `rerender and` for the same reason `resize and` and `nav and` appear
  -- below: every handler is optional, and this was the one branch that did
  -- not say so. A caller handing over `resize` but no `scroll` for scrollable
  -- content would have bound a key that calls nil.
  if rerender and s and (s.more or not at_start) then
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

  local rk = type(cfg.resize_keys) == "table" and cfg.resize_keys or {}

  -- After the scroll keys, so a key configured for both keeps the older
  -- meaning. A PDF page is the one content that has both, and paging is what
  -- its keys have always done.
  if resize and content and content.canvas then
    for _, lhs in ipairs(M.keylist(rk.larger)) do
      take(seen, lhs, function()
        resize(1)
      end, "hover: make the picture bigger")
    end
    for _, lhs in ipairs(M.keylist(rk.smaller)) do
      take(seen, lhs, function()
        resize(-1)
      end, "hover: make the picture smaller")
    end
  end

  -- The wheel, for *any* hover, gated on where it points. Silence when it
  -- points elsewhere is the correct answer rather than a missing one: the
  -- chord means nothing else while a float is up, and resizing a float the
  -- pointer is nowhere near would be the surprising half.
  if resize and content then
    for _, lhs in ipairs(M.keylist(rk.wheel_larger)) do
      take(seen, lhs, function()
        if pointer_over_float() then
          resize(1)
        end
      end, "hover: bigger, where the pointer is")
    end
    for _, lhs in ipairs(M.keylist(rk.wheel_smaller)) do
      take(seen, lhs, function()
        if pointer_over_float() then
          resize(-1)
        end
      end, "hover: smaller, where the pointer is")
    end
  end

  -- The zoom, on "this hover *can* be zoomed" rather than "is zoomed".
  --
  -- Wider than the navigation borrow below on purpose, and the difference is
  -- what the keys cost. `>` and `=` are operators rather than motions, so
  -- binding `out` and `reset` while nothing is zoomed costs a reader nothing
  -- and they simply decline. Binding them only *after* a successful zoom
  -- would make the pair appear and disappear under the reader's hands for no
  -- gain.
  --
  -- **After the resize keys, and that ordering is load-bearing now that both
  -- lists hold plain characters.** A key in both is taken once, for resize --
  -- and since every hover reaching here has a picture, an overlap is total
  -- rather than occasional. `-` is the one that invites it, being the obvious
  -- partner for a `_`; `hover.health` reports the clash rather than leaving a
  -- key that resizes where a zoom was asked for.
  if zoom and handlers.zoomable then
    local zk = type(cfg.zoom_keys) == "table" and cfg.zoom_keys or {}
    for _, spec in ipairs({
      { zk.into, 1, "in" },
      { zk.out, -1, "out" },
      -- `zoom` clamps at level 0, so any step past the current one lands on
      -- "the whole picture" exactly -- the same trick `:Hover zoom reset`
      -- uses, rather than a second entry point.
      { zk.reset, -math.huge, "back out entirely" },
    }) do
      local delta = spec[2]
      for _, lhs in ipairs(M.keylist(spec[1])) do
        take(seen, lhs, function()
          zoom(delta)
        end, "hover: zoom " .. spec[3])
      end
    end
  end

  -- Only for a position hover, and only where a second contribution could
  -- exist. `has_answers` counts registrations rather than answers on purpose:
  -- finding out who *would* answer means calling all of them on every hover,
  -- which is the cost `on_request` exists to avoid. A key bound where nothing
  -- further answers costs one press and a message.
  if next_answer and handlers.has_answers then
    local pk = type(cfg.position_keys) == "table" and cfg.position_keys or {}
    for _, lhs in ipairs(M.keylist(pk.next)) do
      take(seen, lhs, function()
        next_answer()
      end, "hover: the next plugin with something to say here")
    end
  end

  -- Last, and on the narrowest condition there is: only while the hover is
  -- actually magnified. Nothing to move towards otherwise, and unlike the
  -- chords above these are motions -- the one kind of key worth handing back
  -- the instant it stops earning its place.
  if nav and handlers.zoomed then
    local nk = type(cfg.nav_keys) == "table" and cfg.nav_keys or {}
    for _, spec in ipairs({
      { nk.left, -1, 0, "left" },
      { nk.right, 1, 0, "right" },
      { nk.up, 0, -1, "up" },
      { nk.down, 0, 1, "down" },
    }) do
      local dx, dy = spec[2], spec[3]
      for _, lhs in ipairs(M.keylist(spec[1])) do
        take(seen, lhs, function()
          nav(dx, dy)
        end, "hover: move the magnified view " .. spec[4])
      end
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
