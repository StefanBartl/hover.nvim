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
--- The route path for one switch: the implication chain, read as a command
--- tree. `fetch` implies `web` implies `links`, so it is
--- `:Hover links web fetch`; `code` and `missing` both imply `paths`, so they
--- are `:Hover paths code` and `:Hover paths missing`.
---
--- **Derived rather than written down.** This was a hand-maintained
--- `if name == "web" then ... elseif ...` chain, and it broke the moment a
--- switch was added without a matching branch: `hover.switches` says a new
--- switch is one table entry and nothing else, and that was true of dispatch,
--- completion, `status` and `:checkhealth` but quietly not of this. The
--- eighth switch landed as a bare top-level `code` route rather than under
--- `paths`, with nothing failing to say so. Reading `implies`
--- gives exactly the same paths for every switch that existed before, and
--- cannot fall behind the table it now reads from.
---
--- The `seen` guard is for a chain that points at itself. Nothing in
--- `SWITCHES` does today; a cycle here would hang the command registration at
--- startup, which is a bad way to find out.
---@param name string
---@return string[]
local function route_path(name)
  local path = { name }
  local seen = { [name] = true }
  local cursor = switches.spec(name)

  while cursor and cursor.implies and not seen[cursor.implies] do
    table.insert(path, 1, cursor.implies)
    seen[cursor.implies] = true
    cursor = switches.spec(cursor.implies)
  end

  return path
end

---@internal
--- One `:Hover <feature> [on|off|toggle]` route.
---@param name string
---@return table
local function switch_route(name)
  local spec = switches.spec(name)
  return {
    path = route_path(name),
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
--- Report everything that is on or off, in one message rather than seven.
---@return nil
local function report_status()
  local status = hover().status()
  local lines = { ("mode: %s"):format(status.mode) }
  for _, s in ipairs(status.switches) do
    lines[#lines + 1] = ("  %-22s %s"):format(s.label, s.enabled and "on" or "off")
  end
  require("hover.notify").info(table.concat(lines, "\n"))
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
