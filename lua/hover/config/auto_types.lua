---@module 'hover.config.auto_types'
---@brief Every name `auto_hover` accepts, in one place.
---@description
--- The target types `classify` can produce, plus `"position"` — which is not
--- a target at all but a plugin answering for the place the cursor is in, and
--- therefore the one thing in this list that has no `Hover.Target.type`.
---
--- A module of its own, and one function rather than a table, for two
--- reasons. `config/DEFAULTS.lua` is data and may require nothing, so the
--- list cannot live beside the defaults it describes; and `hover.classify`
--- pulls in the classifier, which the completion for `:Hover auto` has no
--- other use for, so loading it lazily keeps a `<Tab>` press from being the
--- thing that first reads a file.
---
--- Sorted, because every consumer prints it: the route's completion, the
--- `:checkhealth` line, and `:Hover auto` with no argument.

---@return string[]
return function()
  local types = vim.deepcopy(require("hover.classify").TYPES)
  types[#types + 1] = "position"
  table.sort(types)
  return types
end
