---@meta
---@module 'hover.config.@types'
---@brief Types for the configuration layer.
---@description
--- `Hover.Config` and everything it nests are declared once, in
--- `hover.@types` -- an alias name is global to LuaLS, so declaring
--- `Hover.Config` a second time here would be a `duplicate-doc-alias` rather
--- than a second opinion (`LLS-22`).
---
--- This file exists because every level carries one (`NEW-09`), and because
--- it is where a type belonging *only* to the config layer would go. There
--- is none today.
---
---@see hover.@types

return {}
