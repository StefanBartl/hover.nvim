# What it does and what not

```
See ./docs/architecture.md#modules for details.
    └──────── hover here ────────┘

┌ architecture.md ──────────────────┐
│ ## Modules                        │
│                                   │
│ Every module owns one directory   │
│ with an `init.lua` …              │
└───────────────────────────────────┘
```

A reference in prose is a promise that something exists somewhere else.
Following it costs a jump, a look, and a jump back — enough friction that most
of the time you do not, and read on with a guess instead. hover.nvim answers
the reference in place.

What it can answer depends on the target:

| Target | Float shows |
| --- | --- |
| A text file | Its first lines, syntax-highlighted |
| A markdown file with `#heading` | That section (needs markdown.nvim) |
| A directory | Its entries, as a mini filetree — navigable with `nav_keys` and a left click |
| An image | The picture (needs a drawing provider), else format, dimensions, size |
| A PDF | Page 1, rendered (needs pdfport.nvim), else size and why not |
| An office document | A badge, or its first page once `:Hover office on` |
| A video | A still from it (needs media.nvim + ffmpeg), the paging keys step through the file, and `<CR>` plays it with sound |
| A file with no text in it | A badge naming the format, not a screen of bytes |
| An `http(s)` link | Host, path and decoded query; plus status code and title with fetching on |
| A git object id | What that commit did (`git show --stat`) — only on `:Hover show` |
| A target that does not exist | That — often the most useful answer of all |

**Pictures and PDF pages open by themselves; everything else waits to be
asked.** That is the default, and it is not a limitation to work around: a
picture is the only thing this plugin shows that cannot be read off the line
the cursor is already on. `:Hover show` answers for every type regardless, and
`:Hover auto <type>` adds a type to what opens unprompted.

hover.nvim itself draws one float and knows almost nothing. Nearly everything
interesting in it is somebody else's job, done by a sibling plugin that may or
may not be installed — every one optional, reached through a `pcall` or
through the registry, and none of them named in its source. Who reaches whom,
and what degrades when a plugin is absent, is in
[integrations.md](integrations.md); why each preview class behaves the way it
does is one page per decision under [FEATURES/](FEATURES/README.md).
