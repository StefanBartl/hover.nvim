-- TESTS/external_spec.lua -- <CR> handing a video to whatever plays it
-- without mpv: `media.play()`, the same call `gf` already makes.
--
-- What matters here is not the launch itself (that is media.nvim's own
-- surface, and its own suite's job) but the one thing only this module adds:
-- nothing here holds a handle to close first, unlike `preview.window`, so a
-- resize re-rendering the same still-open hover must not spawn a second copy
-- of the same file. `M.open` being idempotent per path is the whole of the
-- guarantee, and every test below is really testing that one property from a
-- different angle.

local external = require("hover.preview.external")

describe("hover.preview.external", function()
  before_each(function()
    external.reset()
    package.loaded["media"] = nil
    package.loaded["hover.preview.align_win"] = nil
  end)

  it("hands the path to media.play and reports success", function()
    local played = {}
    package.loaded["media"] = {
      play = function(path)
        played[#played + 1] = path
        return true
      end,
    }
    assert.is_true(external.open("/tmp/clip.mp4"))
    assert.same({ "/tmp/clip.mp4" }, played)
  end)

  it("is a no-op for the same path while still open", function()
    -- The failure this guards: a resize or zoom re-renders the hover with
    -- the same `opts.play = true`, and without this a second `media.play()`
    -- would open a second copy of the file nothing here can tell apart from
    -- the first.
    local calls = 0
    package.loaded["media"] = {
      play = function()
        calls = calls + 1
        return true
      end,
    }
    assert.is_true(external.open("/tmp/clip.mp4"))
    assert.is_true(external.open("/tmp/clip.mp4"))
    assert.equals(1, calls)
  end)

  it("opens again for the same path once reset", function()
    local calls = 0
    package.loaded["media"] = {
      play = function()
        calls = calls + 1
        return true
      end,
    }
    assert.is_true(external.open("/tmp/clip.mp4"))
    external.reset()
    assert.is_true(external.open("/tmp/clip.mp4"))
    assert.equals(2, calls)
  end)

  it("opens a different path even without a reset", function()
    package.loaded["media"] = {
      play = function()
        return true
      end,
    }
    assert.is_true(external.open("/tmp/a.mp4"))
    assert.is_true(external.open("/tmp/b.mp4"))
  end)

  it("reports failure, and stays closed, when media.play fails", function()
    package.loaded["media"] = {
      play = function()
        return false, "no handler"
      end,
    }
    assert.is_false(external.open("/tmp/clip.mp4"))
    assert.is_false(external.is_open())
  end)

  it("reports failure when media.nvim has no play() at all", function()
    package.loaded["media"] = {}
    assert.is_false(external.open("/tmp/clip.mp4"))
  end)

  it("is_open tracks a hand-off since the last reset", function()
    package.loaded["media"] = {
      play = function()
        return true
      end,
    }
    assert.is_false(external.is_open())
    external.open("/tmp/clip.mp4")
    assert.is_true(external.is_open())
    external.reset()
    assert.is_false(external.is_open())
  end)

  it("asks align_win to try centring the window only when align is requested", function()
    package.loaded["media"] = {
      play = function()
        return true
      end,
    }
    local asked = false
    package.loaded["hover.preview.align_win"] = {
      try_centre_new_window = function()
        asked = true
      end,
    }
    external.open("/tmp/clip.mp4", { align = false })
    assert.is_false(asked)
    external.reset()
    external.open("/tmp/clip.mp4", { align = true })
    assert.is_true(asked)
  end)

  it("does not ask align_win again on the idempotent no-op path", function()
    package.loaded["media"] = {
      play = function()
        return true
      end,
    }
    local asks = 0
    package.loaded["hover.preview.align_win"] = {
      try_centre_new_window = function()
        asks = asks + 1
      end,
    }
    external.open("/tmp/clip.mp4", { align = true })
    external.open("/tmp/clip.mp4", { align = true })
    assert.equals(1, asks)
  end)
end)

describe("hover.preview.external, preferring a known player", function()
  -- A fullscreen window defeats `align_win`'s `SetWindowPos` before it
  -- starts (reported 2026-09-09, against VLC opening in its remembered
  -- fullscreen state) -- so when alignment is wanted, a known, scriptable
  -- player is tried by name first, with a flag that keeps it out of
  -- fullscreen. `vim.fn.executable` and `vim.system` are real OS boundaries
  -- and stubbed directly here, the same way `TESTS/bare_git_spec.lua` does.

  local real_executable, real_system

  before_each(function()
    external.reset()
    package.loaded["media"] = {
      play = function()
        return true
      end,
    }
    real_executable = vim.fn.executable
    real_system = vim.system
  end)

  after_each(function()
    vim.fn.executable = real_executable
    vim.system = real_system
    package.loaded["media"] = nil
  end)

  it("launches a known player directly, bypassing media.play, when one is found", function()
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.fn.executable = function(name)
      return name == "vlc" and 1 or 0
    end
    local media_played = false
    package.loaded["media"].play = function()
      media_played = true
      return true
    end
    local seen_argv
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.system = function(argv, _opts)
      -- A fake handle, not the real spawn: the code under test only checks
      -- that this call did not raise, never the process it would have
      -- started -- and "vlc" plainly is not on this test runner's PATH.
      seen_argv = argv
      return { pid = 1 }
    end

    local ok = external.open("/tmp/clip.mp4", { align = true })

    assert.is_true(ok)
    assert.is_false(media_played, "a known player was found -- media.play must not also run")
    assert.same({ "vlc", "--no-fullscreen", "/tmp/clip.mp4" }, seen_argv)
  end)

  it("falls to media.play when no known player is on PATH", function()
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.fn.executable = function()
      return 0
    end
    local media_played = false
    package.loaded["media"].play = function()
      media_played = true
      return true
    end

    local ok = external.open("/tmp/clip.mp4", { align = true })

    assert.is_true(ok)
    assert.is_true(media_played)
  end)

  it("is never tried when align is not requested, even if a player is found", function()
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.fn.executable = function(name)
      return name == "vlc" and 1 or 0
    end
    local system_called = false
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.system = function(...)
      system_called = true
      return real_system(...)
    end
    local media_played = false
    package.loaded["media"].play = function()
      media_played = true
      return true
    end

    local ok = external.open("/tmp/clip.mp4", { align = false })

    assert.is_true(ok)
    assert.is_true(media_played, "no alignment requested -- the system handler is the only tier")
    assert.is_false(system_called)
  end)

  it("is skipped when prefer_classic is turned off, even with align on", function()
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.fn.executable = function(name)
      return name == "vlc" and 1 or 0
    end
    local media_played = false
    package.loaded["media"].play = function()
      media_played = true
      return true
    end

    local ok = external.open("/tmp/clip.mp4", { align = true, prefer_classic = false })

    assert.is_true(ok)
    assert.is_true(media_played)
  end)

  it("still asks align_win to centre the window after a known player launch", function()
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.fn.executable = function(name)
      return name == "vlc" and 1 or 0
    end
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.system = function(_argv, _opts)
      return { pid = 1 }
    end
    local asked = false
    package.loaded["hover.preview.align_win"] = {
      try_centre_new_window = function()
        asked = true
      end,
    }

    external.open("/tmp/clip.mp4", { align = true })

    assert.is_true(asked)
    package.loaded["hover.preview.align_win"] = nil
  end)
end)
