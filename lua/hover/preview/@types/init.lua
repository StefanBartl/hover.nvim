---@meta
---@module 'hover.preview.@types'
---@brief Types for the previewers.
---@description
--- `Hover.PreviewOpts`, `Hover.Content`, `Hover.Scroll`, `Hover.Canvas` and
--- `Hover.Preview.Dims` are declared in `hover.@types`, grouped by the file
--- each describes. They live there rather than here because an alias name is
--- global to LuaLS and a second declaration would collide (`LLS-22`).
---
--- `Hover.Preview.Dims` is the one stand-in for a foreign type in this
--- plugin: images.nvim is a `pcall(require, ...)` soft dependency, so its
--- `Images.Scale.Dims` is not on the checking workspace's library path. It
--- declares only the two fields this plugin reads (`LLS-23`).
---
---@see hover.@types

return {}
