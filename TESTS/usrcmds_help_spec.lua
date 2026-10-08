---@diagnostic disable: need-check-nil
-- The test body is the guard; see the note in TESTS/bare_path_spec.lua
-- (`LLS-42`).

-- TESTS/usrcmds_help_spec.lua -- every positional argument of `:Hover` has a line in the option
-- float.
--
-- lib.nvim's help float (the option cheatsheet on the command line) shows one line for the next
-- positional argument, taken from the argument's own `desc` or -- for a closed set -- from
-- `enum_desc`. The routes are generated (one `[on|off|toggle]` route per switch), so a switch added
-- to `hover.switches` gets its line from the same place its route does; this pins that no route
-- ships an argument without one, and that the lines keep the float's house style: one short line,
-- no trailing full stop. A value text for a value the argument does not offer shows nowhere, so
-- that is pinned too.
--
-- Skipped on a lib.nvim without `help.undocumented` / `arg_desc` (older than the argument texts).

local composer = require("lib.nvim.bindings.usercmd.composer")
local ok_entries, entries = pcall(require, "lib.nvim.bindings.usercmd.composer.help.entries")

local supported = type(composer.help) == "table"
  and type(composer.help.undocumented) == "function"
  and ok_entries
  and type(entries.arg_desc) == "function"

---@param text any
---@return boolean
local function house_style(text)
  return type(text) == "string"
    and text ~= ""
    and not text:find("\n", 1, true)
    and #text <= 80
    and not text:find("%.$")
end

describe("the option float of :Hover", function()
  if not supported then
    it("needs a lib.nvim with argument texts", function()
      pending("lib.nvim has no help.undocumented / entries.arg_desc")
    end)
    return
  end

  before_each(function()
    require("hover.bindings.usrcmds").setup()
  end)

  it("leaves no flag and no positional argument without a text", function()
    local missing = {}
    for _, m in ipairs(composer.help.undocumented("Hover", { args = true })) do
      missing[#missing + 1] = ("%s %s %s"):format(m.route, m.kind, m.name)
    end
    assert.are.equal("", table.concat(missing, ", "))
  end)

  it("keeps every text to one short line without a trailing full stop", function()
    local handle = composer.registry().Hover
    assert.is_truthy(handle, ":Hover is registered")
    local walked, bad = 0, {}
    for _, route in ipairs(handle:spec().routes or {}) do
      for _, arg in ipairs(route.args or {}) do
        walked = walked + 1
        local label = (":Hover %s {%s}"):format(table.concat(route.path, " "), arg.name)
        if not house_style(entries.arg_desc(arg)) then
          bad[#bad + 1] = label
        end
        for value, text in pairs(arg.enum_desc or {}) do
          if not house_style(text) then
            bad[#bad + 1] = label .. " = " .. value
          end
          if not vim.tbl_contains(arg.enum or arg.values or {}, value) then
            bad[#bad + 1] = label .. " = " .. value .. " (not one of its values)"
          end
        end
      end
    end
    assert.is_true(walked > 0, "the routes' arguments were actually walked")
    assert.are.equal("", table.concat(bad, "\n"))
  end)

  it("names the switch in the line of its [on|off|toggle] argument", function()
    local switches = require("hover.switches")
    local handle = composer.registry().Hover
    local seen = 0
    for _, name in ipairs(switches.names()) do
      local path = table.concat(switches.route(name), " ")
      for _, route in ipairs(handle:spec().routes or {}) do
        if table.concat(route.path, " ") == path then
          seen = seen + 1
          local label = switches.spec(name).label
          assert.is_truthy(
            route.args[1].desc:find(label, 1, true),
            (":Hover %s describes the %s switch"):format(path, label)
          )
        end
      end
    end
    assert.are.equal(#switches.names(), seen)
  end)
end)
