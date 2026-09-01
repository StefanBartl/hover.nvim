---@meta
---@module 'hover.bindings.@types'
---@brief Types for the binding surfaces.
---@description
--- `Hover.BoundKey`, `Hover.Keymaps` and `Hover.ScrollKeys` are declared in
--- `hover.@types` alongside the rest, for the reason given there: an alias
--- name is global, so a second declaration collides rather than scoping
--- (`LLS-22`).
---
--- The composer route and context types belong to
--- `lib.nvim.bindings.usercmd.composer` and are deliberately not restated
--- here -- a parallel name with identical fields can never be assigned from
--- the original (`LLS-20`).
---
---@see hover.@types
---@see lib.nvim.bindings.usercmd.composer

return {}
