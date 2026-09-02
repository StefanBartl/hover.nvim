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

exec nvim --clean --headless -u scripts/minimal_init.lua -c "$cmd"
