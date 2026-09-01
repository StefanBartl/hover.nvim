---@module 'hover.bindings'
---@brief Aggregator for the three binding surfaces.
---@description
--- Keymaps, user commands and autocmds each own their own file; this is the
--- one door that installs all three, so a caller does not have to know how
--- many there are. `hover.enable()` is the normal way in and calls the same
--- three -- this exists for a host that wants the bindings without the
--- configuration merge.
---
---@see hover.bindings.keymaps
---@see hover.bindings.usrcmds
---@see hover.bindings.autocmds

local M = {}

M.keymaps = require("hover.bindings.keymaps")
M.usrcmds = require("hover.bindings.usrcmds")
M.autocmds = require("hover.bindings.autocmds")

--- Install every binding this plugin owns. Idempotent, in all three.
---@return nil
function M.setup()
  M.usrcmds.setup()
  M.keymaps.setup()
  M.autocmds.enable()
end

return M
