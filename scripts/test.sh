#!/usr/bin/env bash
#
# Runs the plenary spec suite headlessly. Wraps scripts/minimal_init.lua --
# see that file for what it resolves and why.
#
#   scripts/test.sh                    every spec under TESTS/
#   scripts/test.sh TESTS/foo_spec.lua a single spec file
#
# Env vars (both optional -- see scripts/minimal_init.lua's own fallbacks):
#   LIB_NVIM_DIR   path to a lib.nvim checkout
#   PLENARY_DIR    path to a plenary.nvim checkout
#
# Fails loudly and with exit code 1 (NEW-40): a runner that reports success
# without having loaded its harness is worse than no runner at all.

set -euo pipefail

cd "$(dirname "$0")/.."

command -v nvim >/dev/null 2>&1 || {
  printf '\033[31m%s\033[0m\n' "nvim is not on PATH." >&2
  exit 1
}

target="${1:-TESTS/}"

# A single file runs *in this process*, not through `PlenaryBustedFile`, and
# the reason is an environment difference rather than speed.
#
# `PlenaryBustedFile` reaches `test_harness.test_file`, which calls the runner
# with **no options at all** -- so the child it spawns gets `--noplugin` and no
# `-u`, and therefore not this script's `minimal_init`. The directory branch
# below hands `minimal_init` over explicitly, so the two branches ran the same
# spec in two different environments: measured 2026-09-02, images.nvim was on
# the runtimepath for a directory run of `zoom_spec.lua` and absent for a
# single-file run of the same file.
#
# That is worse than a slow runner. A spec that skips when run alone and runs
# in the suite -- or the reverse -- makes both results untrustworthy, and it is
# how the zoom crop check stayed invisible: it reported *pending* to everyone
# who ran it by itself.
#
# `plenary.busted.run` executes the file here, in the nvim that `-u` has
# already configured, so a single-file run is by construction the same
# environment as the whole suite.
if [[ "$target" == *.lua ]]; then
  cmd="lua require('plenary.busted').run(vim.fn.fnamemodify('$target', ':p'))"
else
  cmd="PlenaryBustedDirectory $target { minimal_init = 'scripts/minimal_init.lua', sequential = true }"
fi

# A pending spec is invisible in the summary, and there are two shapes of it.
# Both measured here on 2026-09-03 rather than assumed:
#
#   `pending("...")` at describe level -- prints a Pending line and is *not*
#   counted anywhere. The only trace is a Success total that got smaller,
#   which reads as "nobody added a spec", not as "one stopped running".
#
#   `pending("...")` *inside* an `it`, which is what a guarded spec does --
#   prints a Pending line **and still counts the `it` as a Success**. Measured
#   on zoom_spec: 24 `it` blocks, "Success: 24", one of which asserted
#   nothing. So the summary does not merely omit a skipped spec, it reports it
#   as green.
#
# Neither shape touches the exit code. That is how the zoom crop check stayed
# invisible for as long as it did, and no amount of reading the totals would
# have caught it.
#
# So the runner counts them itself. `tee` rather than a capture-then-print,
# because a suite that only speaks at the end is worse to wait on, and
# PIPESTATUS rather than $? because the pipeline's status is `tee`'s.
#
# HOVER_ALLOW_PENDING=1 is the way to have a deliberate `pending()` marker: it
# stays visible in the output and stops failing the run. Silence was never the
# problem; unnoticed silence was.
log="$(mktemp)"
trap 'rm -f "$log"' EXIT

nvim --clean --headless -u scripts/minimal_init.lua -c "$cmd" 2>&1 | tee "$log"
status=${PIPESTATUS[0]}

# Strip the colour codes before counting: plenary writes "Pending" in yellow.
pending=$(sed 's/\x1b\[[0-9;]*m//g' "$log" | grep -c '^Pending' || true)

# Named always, fatal only where it can be. On a CI runner the crop check is
# *deliberately* pending -- there is no images.nvim and no ImageMagick to prove
# it with -- so failing there would only teach everyone to ignore the message.
# Printing there still costs nothing and is the whole point: a *new* pending
# shows up in the log even where it cannot stop the build.
if [[ "$pending" -gt 0 ]]; then
  printf '\033[31m%s\033[0m\n' "$pending pending spec(s) -- a guarded one still counts as green above:" >&2
  sed 's/\x1b\[[0-9;]*m//g' "$log" | grep '^Pending' | sed 's/^/  /' >&2
  if [[ -z "${HOVER_ALLOW_PENDING:-}" ]]; then
    printf '%s\n' "Set HOVER_ALLOW_PENDING=1 where one is expected (CI does)." >&2
    printf '%s\n' "Locally this usually means images.nvim was not found: set IMAGES_NVIM_DIR." >&2
    exit 1
  fi
fi

exit "$status"
