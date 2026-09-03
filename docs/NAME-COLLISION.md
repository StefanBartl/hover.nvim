# Module name collision

This plugin installs its Lua modules under `lua/hover/`. So does
[`lewis6991/hover.nvim`](https://github.com/lewis6991/hover.nvim). The
repository names do not collide; the module root does.

With both installed, `require("hover")` resolves to whichever of the two
directories comes first on the `runtimepath`. That order is decided by the
plugin manager's load order, not by either plugin, so which one answers is not
a setting — it is a side effect. The other one is then simply not there:
nothing is reported, nothing fails, and its commands and keys never appear.

Neither plugin can work around this from inside. Install one of them.
