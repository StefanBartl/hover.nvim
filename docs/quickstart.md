# Quickstart

Nothing else is required. Rest the cursor on a path, and a float appears.

When one does not, that is the question `:Hover why` exists to answer:

```vim
:Hover show            " one hover, here, now, ignoring every volume switch
:Hover why              " which gate refused, and what to type about it
:Hover dashboard        " the mode and every switch, as a board you can toggle
```

No key is claimed by default — a plugin that other plugins depend on has no
business taking one on their behalf. `keymaps = { show = "<leader>k" }` is the
one worth setting, and `:checkhealth hover` says so when `mode = "manual"` is
configured without it.

Verify your setup any time with:

```vim
:checkhealth hover
```

See [health.md](health.md) for what each section of that report means, and
[what-you-get.md](what-you-get.md) for the rest of the day-one command table.
