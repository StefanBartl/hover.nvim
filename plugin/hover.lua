-- Registers `:Hover` and nothing else.
--
-- The command has to exist before `setup()` runs, for one reason: `:Hover
-- mode auto` must be reachable from a session where nothing turned the hover
-- on -- which is exactly the session someone typing it is in. Everything the
-- command can actually do still goes through `hover.enable()`/`setup()`.
--
-- No autocmd, no keymap, no preview machinery: this file must stay cheap,
-- because it runs at startup in every session whether or not the hover is
-- ever used. `hover.bindings.usrcmds` only requires the composer.
if vim.g.loaded_hover then
  return
end
vim.g.loaded_hover = true

pcall(function()
  require("hover.bindings.usrcmds").setup()
end)
