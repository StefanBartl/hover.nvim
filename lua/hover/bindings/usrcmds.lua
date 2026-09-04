---@module 'hover.bindings.usrcmds'
---@brief The `:Hover` verb, generated from the switch table.
---@description
--- One compound command rather than a family of them (`UI-21`), and its
--- routes are *derived* from `hover.switches` rather than written out
--- (`UI-20`): adding an eighth switch adds its route, its `<Tab>`
--- completion, its description and its line in `:Hover status` at once,
--- because there is only one place any of that is written.
---
--- **Why a command and not a keymap for the switches.** A setting thrown a
--- few times a week, from wherever you happen to be, does not need to be one
--- keystroke away -- and a plugin other plugins depend on should not claim
--- keys on their behalf. The two things that *do* want a key have one: the
--- per-hover dismissal (borrowed only while a float is up) and
--- `keymaps.show`, which the user opts into.
---
--- **Why every switch takes `[on|off|toggle]` with a default.** Omitting the
--- state toggles, which is the common gesture; the enum is completed, so the
--- explicit form costs no typing either (`UI-22`).
---
---@see hover.switches
---@see hover.bindings.keymaps

local M = {}

local switches = require("hover.switches")

---@internal
--- Deferred back-reference; see the note in `hover.bindings.keymaps`.
---@return table
local function hover()
  local mod = require("hover")
  return mod
end

---@type string[] The state argument's closed value set, completed by composer.
local STATES = { "on", "off", "toggle" }

---@internal
--- Turn a completed state token into the boolean `set` wants. "toggle" is
--- `nil`, which is how every switch spells "flip it".
---@param state string|nil
---@return boolean|nil
local function to_bool(state)
  if state == "on" then
    return true
  elseif state == "off" then
    return false
  end
  return nil
end

---@internal
--- One `:Hover <feature> [on|off|toggle]` route.
---@param name string
---@return table
local function switch_route(name)
  local spec = switches.spec(name)
  return {
    path = switches.route(name),
    desc = spec and spec.desc or name,
    args = {
      {
        name = "state",
        enum = STATES,
        optional = true,
        default = "toggle",
      },
    },
    ---@param ctx table
    run = function(ctx)
      local state = ctx and ctx.args and ctx.args.state
      switches.set(name, to_bool(state))
    end,
  }
end

---@internal
--- The status as one message. The fallback, and the whole of what `:Hover
--- status` used to be -- kept for a lib.nvim without the UI kit, and for a
--- host that has swapped `vim.notify` for something it prefers.
---@param status table
---@return nil
local function notify_status(status)
  local lines = { ("mode: %s"):format(status.mode) }
  for _, s in ipairs(status.switches) do
    -- The route, not just the label: a reader who has only this form still
    -- gets the words to type. That gap is what the board was built for.
    lines[#lines + 1] = ("  %-22s %-4s :Hover %s"):format(
      s.label,
      s.enabled and "on" or "off",
      table.concat(s.route, " ")
    )
  end

  -- **The second axis, which this form used to leave out entirely.** The
  -- board (`hover.status_view`) has drawn it since it was built; this
  -- fallback listed the switches and stopped, so on a lib.nvim without the UI
  -- kit `:Hover status` could report every switch on and every float shut.
  -- The switches say what may hover; these say what opens *without being
  -- asked*, and a report of one half is what made `:Hover links web on` look
  -- broken.
  if type(status.auto) == "table" and #status.auto > 0 then
    local on, off = {}, {}
    for _, entry in ipairs(status.auto) do
      table.insert(entry.enabled and on or off, entry.name)
    end
    lines[#lines + 1] = ("opens by itself: %s"):format(
      #on > 0 and table.concat(on, ", ") or "nothing"
    )
    if #off > 0 then
      lines[#lines + 1] = ("  on request only: %s  --  :Hover auto <type>"):format(
        table.concat(off, ", ")
      )
    end
  end

  require("hover.notify").info(table.concat(lines, "\n"))
end

---@internal
--- The board first, the message if it cannot be drawn.
---
--- **Why a board and not a report.** Nine switches read as a message tell you
--- the state and then leave you to type a command at it -- and the command is
--- not the label you just read: `broken-target marker` is
--- `:Hover paths missing`, and `web links` is `:Hover links web`, which is
--- exactly the confusion that produced this. Acting on the line you are
--- already looking at is one step instead of two, and needs no translation.
---
--- It stays a *report* first: the same switches in the same order, plus the
--- mode and what opens by itself. Acting on them is the addition.
---@return nil
local function report_status()
  local ok, view = pcall(require, "hover.status_view")
  if ok and type(view) == "table" and view.open() then
    return
  end
  notify_status(hover().status())
end

--- Every `:Hover` route, in the shape `composer.verb` expects. Public so a
--- host can fold them into its own verb instead of installing a second
--- top-level command.
---@return table[]
function M.routes()
  local routes = {
    {
      path = { "show" },
      desc = "Show the hover for whatever is under the cursor, ignoring every volume switch",
      run = function()
        hover().show({ force = true })
      end,
    },
    {
      path = { "zoom" },
      -- The primary way in, and deliberately the *only* one by default: a
      -- step costs about a quarter of a second (see `hover.zoom`), which
      -- makes it a deliberate operation rather than a dial, and deliberate
      -- operations live on this verb. `hover.zoom(delta)` is public for
      -- anyone who wants a key of their own.
      --
      -- Not to be confused with `:Hover resize`, which was called `zoom`
      -- until `8ec5b40`: resize changes the *box* and letterboxes the whole
      -- picture into it, this cuts the source. The rename is what made the
      -- word free for the operation it actually describes.
      desc = "Magnify a detail of the picture on screen, or step back out",
      args = {
        {
          name = "direction",
          enum = { "in", "out", "reset" },
          optional = true,
          -- Bare `:Hover zoom` goes in. A step has no "toggle" reading, and
          -- `out` undoes a wrong guess in one press.
          default = "in",
        },
      },
      ---@param ctx table
      run = function(ctx)
        local direction = (ctx and ctx.args and ctx.args.direction) or "in"
        local h = hover()
        if direction == "reset" then
          -- A single large step out. `zoom` clamps at 0, so any number past
          -- the current level lands on "the whole picture" exactly.
          if not h.zoom(-math.huge) then
            require("hover.notify").info("nothing is zoomed")
          end
          return
        end
        h.zoom(direction == "out" and -1 or 1)
      end,
    },
    {
      path = { "nav" },
      -- The keyboard counterpart to `nav_keys`, which are borrowed only
      -- while the hover is zoomed. This exists for the same reason the
      -- resize route does: the keys are a borrow, so someone who has never
      -- had a magnified picture up cannot discover them.
      --
      -- `nav` rather than `pan`: `pan` is the more precise word for the
      -- operation and the wrong one for a verb someone types, and the name
      -- was one day old. Renamed rather than aliased -- an alias for a
      -- renamed operation is what produced `bd72836`.
      desc = "Move the magnified view",
      args = {
        {
          name = "direction",
          enum = { "left", "right", "up", "down" },
          optional = false,
        },
      },
      ---@param ctx table
      run = function(ctx)
        local dirs = {
          left = { -1, 0 },
          right = { 1, 0 },
          up = { 0, -1 },
          down = { 0, 1 },
        }
        local d = dirs[(ctx and ctx.args and ctx.args.direction) or ""]
        if not d then
          require("hover.notify").warn("which way: left, right, up or down")
          return
        end
        if not hover().nav(d[1], d[2]) then
          require("hover.notify").info("nothing is zoomed, so there is nothing to move")
        end
      end,
    },
    {
      path = { "mode" },
      desc = "Set the mode: auto opens by itself, manual only on request, off not at all",
      args = {
        {
          name = "mode",
          enum = { "auto", "manual", "off" },
          optional = true,
        },
      },
      ---@param ctx table
      run = function(ctx)
        local mode = ctx and ctx.args and ctx.args.mode
        if not mode then
          require("hover.notify").info(("mode: %s"):format(hover().mode()))
          return
        end
        local _, err = hover().set_mode(mode)
        if err then
          require("hover.notify").warn(err)
        end
      end,
    },
    {
      path = { "auto" },
      desc = "Which target types open by themselves; a type toggles it, `all`/`none` set every one",
      args = {
        {
          name = "type",
          -- Completed from the same list `auto_hover` is validated against,
          -- so a new target type appears here without an edit. `all` and
          -- `none` are the two ends of the axis, spelled rather than
          -- expressed as eleven presses.
          enum = (function()
            local names = require("hover.config.auto_types")()
            local out = { "all", "none" }
            for _, name in ipairs(names) do
              out[#out + 1] = name
            end
            return out
          end)(),
          optional = true,
        },
      },
      ---@param ctx table
      run = function(ctx)
        local which = ctx and ctx.args and ctx.args.type
        local result, err = hover().set_auto(which)
        if err then
          require("hover.notify").warn(err)
          return
        end
        require("hover.notify").info(result)
      end,
    },
    {
      path = { "border" },
      desc = "Border style: rounded, single, double, heavy, ascii, dashed, block, solid, shadow, none",
      args = {
        {
          name = "style",
          -- Read from `float.border_names()`, which is also what the setter
          -- validates against -- one list, two consumers.
          enum = require("hover.float").border_names(),
          optional = true,
        },
      },
      ---@param ctx table
      run = function(ctx)
        local style = ctx and ctx.args and ctx.args.style
        local report, err = hover().set_border(style)
        if err then
          require("hover.notify").warn(err)
          return
        end
        require("hover.notify").info(report)
      end,
    },
    {
      path = { "toggle" },
      desc = "Turn the hover off for this session, or back on",
      run = function()
        hover().toggle()
      end,
    },
    {
      path = { "status" },
      desc = "Report the mode and every switch in one message",
      run = report_status,
    },
    {
      path = { "pin" },
      desc = "Keep this hover on screen while the cursor goes elsewhere",
      run = function()
        local h = hover()
        if not h.pin then
          return
        end
        local was = h.pinned()
        local now = h.pin()
        if now == was and not now then
          require("hover.notify").info("no hover to pin")
        else
          require("hover.notify").info(now and "hover pinned" or "hover released")
        end
      end,
    },
    {
      path = { "zen" },
      -- Beside the borrowed `F` rather than instead of it, which is the house
      -- rule: a borrow is undiscoverable until it has been seen once, and
      -- `:Hover` completion is where the rest of this plugin is met. The same
      -- argument `:Hover resize` and `:Hover nav` are here on.
      desc = "Put the hover on screen full screen, or take it back",
      args = {
        {
          name = "state",
          enum = STATES,
          optional = true,
          -- Toggling is the gesture; the explicit form costs no typing
          -- either, since the enum completes.
          default = "toggle",
        },
      },
      ---@param ctx table
      run = function(ctx)
        -- `zen` declines for three different situations and hands back the
        -- reason for the two worth naming; the third is "it is already in
        -- that state", which is what an explicit `on` twice means.
        local _, why = hover().zen(to_bool(ctx and ctx.args and ctx.args.state))
        if why then
          require("hover.notify").info(why)
        end
      end,
    },
    {
      path = { "resize" },
      -- The keys are the primary way in (`+` / `-`, borrowed while a picture
      -- is on screen). This route exists for two reasons: those keys are a
      -- *borrow* and are bound only while a drawn hover is open, so a reader
      -- who has not seen them cannot discover the feature -- and they are
      -- deliberately not bound for a text hover, where this route is the
      -- keyboard way in.
      --
      -- Reachable in practice because entering the command line moves no
      -- cursor: the float's dismissal hangs on CursorMoved, InsertEnter,
      -- BufLeave and WinScrolled, and typing `:` fires none of them.
      desc = "Make the hover on screen bigger or smaller",
      args = {
        {
          name = "direction",
          enum = { "bigger", "smaller" },
          optional = true,
          -- Bare `:Hover resize` makes it bigger. There is no "toggle"
          -- reading for a step, and the common direction is the useful
          -- default -- one that `smaller` undoes, so guessing wrong costs one
          -- keypress.
          default = "bigger",
        },
      },
      ---@param ctx table
      run = function(ctx)
        local direction = (ctx and ctx.args and ctx.args.direction) or "bigger"
        if not hover().resize(direction == "smaller" and -1 or 1) then
          require("hover.notify").info("no hover to resize")
        end
      end,
    },
    {
      path = { "next" },
      -- The keyboard way in, and the discoverable one: `<M-n>` is a *borrow*,
      -- bound only while a position hover with more than one possible answer
      -- is open, so nobody meets it by accident. `:Hover` completion is where
      -- the rest of this plugin is met.
      desc = "Step to the next plugin with something to say about this place",
      run = function()
        if not hover().next_position() then
          return
        end
      end,
    },
    {
      path = { "why" },
      -- The counterpart to `status`: that one says what is configured, this
      -- one says what happened *here*. A hover that does not open is silent
      -- by design and has seven possible reasons, which look identical from
      -- the outside.
      desc = "Say why nothing hovered at the cursor",
      run = function()
        require("hover.notify").info(table.concat(hover().why(), "\n"))
      end,
    },
  }

  for _, name in ipairs(switches.names()) do
    routes[#routes + 1] = switch_route(name)
  end

  return routes
end

---@type boolean Module-local guard, so a second `enable()` does not re-register.
local _installed = false

--- Register `:Hover`.
---
--- Installed even when the hover is switched off, and deliberately so:
--- `:Hover mode auto` has to be reachable from the state where nothing is
--- on, which is also the state a user typing it is most likely to be in.
---@return nil
function M.setup()
  if _installed then
    return
  end
  local ok, composer = pcall(require, "lib.nvim.bindings.usercmd.composer")
  if not ok or type(composer.verb) ~= "function" then
    return
  end
  _installed = true

  composer.verb("Hover", {
    desc = "Preview whatever the cursor is resting on, and switch the parts of it on and off",
    notify_prefix = "[hover.nvim]",
    routes = M.routes(),
  })
end

return M
