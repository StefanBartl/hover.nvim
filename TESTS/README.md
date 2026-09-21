# TESTS/ — what is covered, and what is not

`TESTS/` is a [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)
busted-style suite. There is no framework-free harness here and none is
wanted — plenary is already a hard test dependency (see
`scripts/minimal_init.lua`), and every spec in this directory follows its
`describe`/`it`/`before_each`/`after_each` shape.

## Running it

```sh
bash scripts/test.sh                    # every spec
bash scripts/test.sh TESTS/foo_spec.lua # one file, same environment as the suite
```

`scripts/test.sh` resolves `lib.nvim` (hard dependency), `ui.nvim` (needed
because `TESTS/status_view_spec.lua` asserts the dashboard actually opens)
and `plenary.nvim` itself via `LIB_NVIM_DIR`/`UI_NVIM_DIR`/`PLENARY_DIR`, a
`.deps/<name>` checkout, or a sibling directory next to this repo — see the
comment at the top of `scripts/minimal_init.lua`. `images.nvim` is optional;
without it the zoom crop specs report `pending` rather than failing, and
`HOVER_ALLOW_PENDING=1` (what CI sets) is what keeps that from failing the
build while still printing every pending spec by name.

[`.github/workflows/ci.yml`](../.github/workflows/ci.yml) runs `stylua
--check`, `luacheck lua plugin` and the full suite on Ubuntu, Windows and
macOS on every push and PR to `main`.

`scripts/minimal_init.lua` sets `vim.g.lib_nvim_deps_disable_first_run`, so
no spec run opens lib.nvim's declared-tools popup — see the comment there.
A spec must not depend on which float happens to be on screen anyway, but
that popup in particular arrives on a later tick, only where a declared tool
is missing, and only in the first spec file of a run.

## Coverage map

One row per module under `lua/hover/**` (`@types`/`---@meta` files excluded
— see below). "Dedicated spec" means a spec file whose own `describe` block
is about that module specifically, as opposed to the module merely being
`require()`d as a supporting dependency by a spec about something else.

| Module | Spec | Notes |
| --- | --- | --- |
| `bare_git.lua` | `bare_git_spec.lua` | |
| `bare_path.lua` | `bare_path_spec.lua` | |
| `bare_url.lua` | `bare_url_spec.lua` | added by the 2026-09-18 audit (see below) |
| `bindings/autocmds.lua` | `registry_spec.lua` | `attach`/`anything_to_show`/`detach_all` all directly exercised, including that a wiped buffer and `detach_all` take back the records and the group (`taking it back`) |
| `bindings/init.lua` | — | three-line aggregator, no branching of its own; each of the three `setup()`s it calls is covered where it is used directly |
| `bindings/keymaps.lua` | `playback_spec.lua`, `resize_spec.lua`, `zen_spec.lua`, `zoom_spec.lua`, `office`/`shot` via others | borrow/release behaviour asserted directly in each |
| `bindings/usrcmds.lua` | `docs_spec.lua`, `resize_spec.lua`, `switches_spec.lua`, `zen_spec.lua`, `zoom_spec.lua` | route table cross-checked against `docs/commands.md` in `docs_spec.lua` |
| `cache.lua` | `shot_spec.lua`, `switches_spec.lua`, `url_spec.lua`, `webpdf_spec.lua` | |
| `classify.lua` | `classify_spec.lua` | added by the 2026-09-18 audit — previously reached only incidentally, with an already-existing path handed to it |
| `config/auto_types.lua` | `switches_spec.lua` | one function, one branch (append `"position"`, sort); exercised as a dependency |
| `config/DEFAULTS.lua` | — | data only, see below |
| `config/init.lua` | `config_spec.lua` | |
| `float.lua` | `registry_spec.lua`, `resize_spec.lua`, `zen_spec.lua`, `zoom_spec.lua`, `video_spec.lua` | the most heavily exercised module in the suite; every sizing/positioning path is driven through a real float |
| `formats.lua` | `video_spec.lua` | data table + three lookups; no dedicated file needed |
| `health.lua` | `health_spec.lua` | added by the 2026-09-18 audit — had zero coverage before it; see below |
| `init.lua` | nearly every spec | `require("hover")` is the plugin's own public surface; exercised end to end throughout |
| `notify.lua` | — | a one-line re-export of `lib.nvim.notify`; nothing of its own to test |
| `persist.lua` | `persist_spec.lua` | |
| `preview/align_win.lua` | — | excluded, see below |
| `preview/binary.lua` | `binary_spec.lua` | added by the 2026-09-18 audit |
| `preview/external.lua` | `external_spec.lua` | |
| `preview/git.lua` | `git_spec.lua` | added by the 2026-09-18 audit |
| `preview/media.lua` | `resize_spec.lua`, `zoom_spec.lua`, `window_spec.lua`, `office_spec.lua` (stubbed) | |
| `preview/monitor.lua` | `monitor_spec.lua` | added by the 2026-09-18 audit; the OS scripts themselves are excluded, see below |
| `preview/office.lua` | `office_spec.lua` | added by the 2026-09-18 audit — the module exported `M.reset()` with a doc comment saying it exists for tests, and had none |
| `preview/playback.lua` | `playback_spec.lua` | |
| `preview/shot.lua` | `shot_spec.lua` | |
| `preview/text.lua` | `bare_path_spec.lua`, `registry_spec.lua` | |
| `preview/url.lua` | `url_spec.lua` | |
| `preview/video.lua` | `video_spec.lua` | |
| `preview/webpdf.lua` | `webpdf_spec.lua` | |
| `preview/window.lua` | `window_spec.lua` | |
| `registry.lua` | `registry_spec.lua` | |
| `scope.lua` | `scope_spec.lua` | |
| `status_view.lua` | `status_view_spec.lua` | |
| `switches.lua` | `switches_spec.lua` | |

## Deliberately not covered, and why

- **`@types/init.lua` (top-level, `bindings/`, `config/`, `preview/`)** —
  LuaLS annotations only, no runtime code.
- **`config/DEFAULTS.lua`** — data only by its own doc comment ("Nothing
  here reads the editor, calls an API, or depends on another module"); every
  value in it is exercised indirectly by whichever spec depends on that
  default, and `switches_spec.lua`/`docs_spec.lua` already cross-check its
  shape against `classify.TYPES` and the vimdoc.
- **`notify.lua`** — a one-line re-export; the implementation it forwards to
  is `lib.nvim.notify`'s to test.
- **`preview/align_win.lua`** — `M.try_centre_new_window()` writes a
  disposable PowerShell/AppleScript/bash script to `stdpath("cache")` and
  runs it to move a *real OS window* it does not control. Its own module doc
  states the contract outright: "never blocks, never raises, never reports
  back" — there is no return value, no callback and no observable effect
  from Lua once the process is launched, only whatever actually happens on
  screen. `TESTS/external_spec.lua` already asserts that this function gets
  *called* at the right moment (`"still asks align_win to centre the window
  after a known player launch"`); asserting anything about the generated
  script text itself would be testing embedded PowerShell with Lua string
  assertions, not testing behaviour.
- **`preview/monitor.lua`'s OS scripts** — `script_windows`/`script_macos`/
  `script_linux` generate the PowerShell/AppleScript/bash bodies that query a
  real window manager; `TESTS/monitor_spec.lua` covers everything else in
  this module (`M.detect`'s stdout-parsing branches, via a stubbed
  `vim.system`) but not the script bodies themselves — the CI workflow
  documents this whole family as "evidenced only by hand," and that stance
  is unchanged by this audit.
- **Real external processes in general** — `pdftoppm`/`ffmpeg`/`soffice`/
  `mpv` actually rasterizing, transcoding or playing something, and real
  network requests, are exercised nowhere in this suite; `webpdf_spec.lua`
  and `office_spec.lua` both test everything *around* those calls (caching,
  eviction, refusal, error shaping) with the call itself stubbed.
- **UI that needs a real live backend** — `images.nvim` actually drawing a
  picture, and the ImageMagick-backed zoom crop check, report `pending` in
  CI rather than being skipped silently (`HOVER_ALLOW_PENDING=1`); see
  `scripts/test.sh`'s own comment for why a silent skip was rejected
  (`zoom_spec.lua`'s crop check went unnoticed for a period specifically
  because a `pending()` inside an `it()` still counts as a `Success` in
  plenary's own summary).

## The 2026-09-18 audit

This repository had never had a full audit round in the cross-repo
test-coverage campaign — it was spot-checked once via a file-count proxy (40
`lua` files vs. 38 spec files) and marked "already looks good" on that ratio
alone. This was the first real one.

**What it found:** the existing 19 spec files (474 assertions) were all
real, assertion-based specs — no smoke-test-only files, no padding. Six
modules had never been reached by a dedicated spec at all:
`hover.classify`, `hover.bare_url`, `hover.health`, `hover.preview.binary`,
`hover.preview.git` and `hover.preview.office`; a seventh,
`hover.preview.monitor`, had its own result-parsing logic untested even
though the module existed. All seven now have one (`classify_spec.lua`,
`bare_url_spec.lua`, `health_spec.lua`, `binary_spec.lua`, `git_spec.lua`,
`office_spec.lua`, `monitor_spec.lua` — 98 new assertions).

**No behavioural bug was found or needed fixing.** The audit paid specific
attention to four patterns a related campaign has repeatedly found across
nearly thirty other repositories, and checked each one against this code
rather than assuming it clean:

1. A `health.lua` whose "dependency is missing" branch calls on into the
   missing dependency anyway. `hover/health.lua`'s own doc comment already
   names this exact failure mode ("Checks truth, not presence") and its
   `check_lib()`/`soft()` helpers already guard against it correctly —
   `health_spec.lua`'s first two tests exercise the missing-hard-dependency
   and missing-optional-dependency paths with `M.check()` itself wrapped in
   `pcall`, and both confirm it degrades to a warning/error rather than
   raising.
2. An augroup created without clearing on a second `setup()`.
   `bindings/autocmds.lua`'s `M.enable()`/`M.attach()` already clear their
   groups (`autocmd.group(name, true)`) and `registry_spec.lua` already
   exercises `detach_all()`/re-`attach()` directly; nothing new was found.
3. Byte-offset vs. display-column confusion in cursor-position logic. Every
   position-comparison path in this plugin (`bare_path.lua`, `bare_url.lua`,
   `init.lua`'s `target_under_cursor`/`show_position`) consistently uses the
   byte-based column `nvim_win_get_cursor` returns, with no
   `strdisplaywidth`/`charidx` mixed in anywhere along that path.
   `bare_url_spec.lua` pins this explicitly for the module doing the most
   arithmetic on it — spans reported in the same 0-based byte units the
   cursor API uses, asserted at both the start and the inclusive end of a
   span.
4. Windows path/drive-letter bugs. `classify.lua` already guards the exact
   collision (`C:\Users\...` read as a two-character-minimum URL scheme)
   with `raw:match("^%a[%w+.-]*:") and not raw:match("^%a:[\\/]")`, and
   `bare_url.lua` requires the same two-character minimum independently.
   Both guards are now pinned by a dedicated test
   (`classify_spec.lua`/`bare_url_spec.lua`) rather than only readable by
   inspection, and both were verified empirically on this Windows machine,
   not merely by reading the pattern.

**Before/after:** 19 → 26 spec files, 474 → 572 assertions, 0 failures/
errors/pending in both counts, confirmed stable across two consecutive runs
before and after. `stylua --check` and `luacheck lua plugin` — the exact
commands `.github/workflows/ci.yml` runs — are clean.
