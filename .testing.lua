-- .testing.lua -- configuration of testing.nvim for this project.
-- Written by `testing migrate`; edit freely (it is never overwritten). Every key is optional; the
-- keys are documented in testing.nvim's docs/CONFIG.md. Loading this file executes it (same trust
-- as running the specs).
return {
  -- Lua module root of the project.
  plugin = "hover",
  -- How the spec files are run: "auto" = sniffed per file, "h" = on the project's own TESTS/harness.lua,
  -- "script" = a self-running script in its own process.
  dialect = "auto",
  -- Dependencies (directory names) put on the runtimepath: $<NAME>_DIR, .deps/<name>, ../<name>,
  -- stdpath('data')/lazy/<name>. images.nvim is optional and NOT listed: TESTS/minimal_init.lua adds
  -- it only when it finds one, so a runner without it skips the zoom crop check instead of failing.
  deps = { "lib.nvim", "ui.nvim" },
  -- "none" = all specs in one nvim, "file" = one nvim per spec file
  -- (nothing leaks from one file into the next).
  isolated = "file",
  -- "c" = child started from a -c command (v:vim_did_enter is 0, <cword> works),
  -- "l" = `nvim -l`.
  host = "c",
  -- Environment variables the specs read; a child editor inherits an allowlist only (never secrets).
  env_allow = { "MAGICK_*" },
  -- The old runner let a case without assertions pass. Two cases in monitor_spec.lua
  -- ("parses a well-formed line ..." and "reports no screen index ...") return early when this
  -- Neovim build has no detectable platform, which is deliberate there, so they stay a warning.
  assertions = "warn",
  guards = {
    -- Measured clean over the whole suite (0 findings): these nets stay strict.
    fs = "error",
    scheduled_error = "error",
    prompt = "error",
    deprecation = "error",
    -- Every spec file runs in its own child (isolated = "file"), so what setup() leaves behind
    -- (HoverEnable / HoverPersist / HoverPlayback autocmds, :Hover, the lib.nvim toast autocmd,
    -- the ui.nvim :KitPreview command) dies with the file. Between the cases of one file it is
    -- intended (setup() is idempotent), and the syntax / dependency highlight groups a spec
    -- loads (css*, lua*, Kit*, ImagesBlock_*) are the runtime's. Measured: 130 warnings of that
    -- kind and nothing else, so the guard is off rather than allowlisted case by case.
    state = "off",
    -- Processes are watched; the three below are the legitimate ones (see guard_allow).
    process_net = "error",
  },
  guard_allow = {
    spawn = {
      -- bare_git_spec.lua: "starts git when the request is explicit" runs real `git cat-file` / `git show`.
      "git",
      -- zoom_spec.lua: the crop check cuts a generated picture with the real ImageMagick (only with images.nvim).
      "magick",
      -- external_spec.lua: the argv handed to the player is asserted (the spec stubs vim.system, vlc is never needed).
      "vlc",
    },
  },
}
