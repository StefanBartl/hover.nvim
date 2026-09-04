# Commands

One compound verb, `:Hover`, `<Tab>`-completed at every level. The state argument may be
omitted, which toggles.

`:Hover` is registered from `plugin/hover.lua`, so it exists before `setup()` runs and
even in a session where nothing turned the hover on. That is the point: `:Hover mode auto`
has to be reachable from exactly the state where someone is most likely to type it. If
`:Hover` itself does not exist, the plugin is not on `'runtimepath'` at all — check the
plugin manager before anything else.

---

## Asking for a hover

| Command | Does |
| --- | --- |
| `:Hover show` | one hover, here, now, ignoring every volume switch |
| `:Hover why` | why nothing hovered *here* — which of the gates refused, and what to type about it |
| `:Hover pin` | take this float out of the cursor's hands. While pinned the trigger opens nothing; `:Hover show` replaces it, `q`/`<Esc>` take it away. Again releases it |
| `:Hover next` | step to the next plugin with something to say about this place. Wraps past the last one, and says so when there is only one |

`:Hover why` is the sharper tool whenever a hover fails to appear for one specific thing
rather than for everything — it names the gate that declined, instead of leaving you to
guess between twelve switches, a mode and a target type.

## Acting on the float on screen

| Command | Does |
| --- | --- |
| `:Hover zen [on\|off\|toggle]` | the float on (almost) the whole editor, and back. Not a larger window: the previewer's own budget becomes the screen and the preview is built again against it. Pins by default, because a full-screen float would otherwise close on the first `j` — see [ZEN.md](FEATURES/ZEN.md) |
| `:Hover resize [bigger\|smaller]` | make the hover on screen bigger or smaller — a picture is drawn larger, a text preview shows *more lines*. Omitted, bigger. Declines for a *position* preview, which cannot be asked again at another size |
| `:Hover zoom [in\|out\|reset]` | magnify a detail of the picture or PDF page on screen, or step back out. Omitted, in. A picture is cropped, a page re-rendered at a higher DPI |
| `:Hover nav {left\|right\|up\|down}` | move the magnified view |
| `:Hover border [<style>]` | the frame's look: `rounded` `single` `double` `heavy` `ascii` `dashed` `block` `solid` `shadow` `none`. Omitted, it reports the current one and lists the rest |

Each of these has borrowed keys too — see [BINDINGS.md](BINDINGS.md). The routes exist
beside them because a borrow is undiscoverable until it has been seen once, and because
`+` and `-` are deliberately not bound over a text hover, where `:Hover resize` is the
only keyboard way in. `:Hover border` changes the float already on screen, so a style can
be tried rather than decided.

## Volume

| Command | Does |
| --- | --- |
| `:Hover mode [auto\|manual\|off]` | set the mode; omitted, it reports the current one |
| `:Hover toggle` | off if it is on, back to `auto` if it is off |
| `:Hover auto [<type>\|all\|none]` | which target types open by themselves. A type toggles it; omitted, it lists what does and what waits to be asked |
| `:Hover status` | the mode, every switch and what opens by itself — as a board where `<CR>` toggles the row under the cursor, `?` lists its keys, and every row carries the command that acts on it. One message where lib.nvim has no UI kit |

The type names `:Hover auto` takes are `image`, `pdf`, `office`, `markdown`, `file`,
`directory`, `url`, `anchor`, `missing` and `git`, plus `position` for a plugin answering
about the place the cursor is in. See
[configuration.md](configuration.md#what-opens-by-itself).

## The twelve switches

| Command | Does |
| --- | --- |
| `:Hover links [on\|off\|toggle]` | whether link syntax hovers at all |
| `:Hover links web [on\|off\|toggle]` | whether http(s) links hover. Implies `links on` |
| `:Hover links web fetch [on\|off\|toggle]` | fetch a link for its status code, page title and — for an HTML page — what the page says. Implies `links web on` |
| `:Hover links web fetch pdf [on\|off\|toggle]` | a link that answers `application/pdf` is downloaded and shown as its **first page**, paged and zoomable like a local one. Implies `links web fetch on` — the content type is what identifies it, and only a fetch produces one |
| `:Hover links web shot [on\|off\|toggle]` | render a hovered link in a headless browser and draw the page into the float. Implies `links web on` — and deliberately **not** `fetch`: a fetch is one `curl` GET, this *executes* the page |
| `:Hover links web shot eager [on\|off\|toggle]` | let the automatic trigger do that, not only `:Hover show`. Implies `links web shot on`. Off because fifty links scrolled past is fifty browser starts |
| `:Hover paths [on\|off\|toggle]` | whether a path written in prose hovers |
| `:Hover paths missing [on\|off\|toggle]` | whether a path resolving to nothing is marked broken |
| `:Hover paths code [on\|off\|toggle]` | whether a bare path hovers inside executable code, not just comments and strings. Implies `paths on` |
| `:Hover positions [on\|off\|toggle]` | whether a registered plugin may answer for a cursor position that points at nothing |
| `:Hover images [on\|off\|toggle]` | whether pictures are drawn into the float, or described |
| `:Hover office [on\|off\|toggle]` | whether office documents render through a PDF |

**Implication runs upward only.** `fetch` turns on `web`, which turns on `links` —
fetching with no float to show it in would do the disclosure and none of the good.
Switching `links` *off* silences web links without clearing their flag, so turning `links`
back on restores what you had rather than quietly demoting it.

**`links off` is about how a target was found, not what it is.** If the same text is also
a resolvable bare path, `paths` decides it. `:Hover status` shows both.

**Every switch is announced when it changes**, because "off" is otherwise invisible:
nothing on screen tells a switched-off preview apart from a line that simply has no target
on it, and a switch whose state you cannot see gets reported as a broken feature a week
later. Every change also drops the preview cache, which is keyed by what a target *is*
rather than by how it was rendered.

Their configured counterparts, and what each one costs when it is on, are in
[configuration.md](configuration.md#the-twelve-switches); why the defaults fall where they
do is in [FEATURES/QUIET.md](FEATURES/QUIET.md).

| Summary | Names |
| --- | --- |
| Twelve runtime switches | `links`, `links web`, `links web fetch`, `links web fetch pdf`, `links web shot`, `links web shot eager`, `paths`, `paths missing`, `paths code`, `positions`, `images`, `office` |

---

## The routes are generated, not written out

Dispatch, `<Tab>` completion, the descriptions above, `:Hover status` and the
`:checkhealth hover` section all read `hover.switches` — one table. A tenth switch is one
entry there and nothing else, and the five copies cannot drift apart because there is only
one of them.

That claim was not quite true until the eighth switch proved it: `usrcmds.route_path` was
a hand-written mapping of which switches nest under which, so `code` landed as a bare
top-level route rather than under `paths`, and nothing failed. It reads `implies` now. The
same failure in the *documents* is why `TESTS/docs_spec.lua` exists — every claim a
document makes that the source can be asked about is now asked, in both directions, and
this page is one of the three it holds a complete route table against.

## No range support, deliberately

Every route acts on the cursor position or on a session-wide switch. Neither has a
meaningful reading over a line range, and a `:'<,'>Hover links on` that silently ignored
its range would be worse than one that does not accept it.

No keymap is offered for these either. A setting thrown a few times a week, from wherever
you happen to be, does not need to be one keystroke away — the one binding worth having is
`keymaps.show`.
