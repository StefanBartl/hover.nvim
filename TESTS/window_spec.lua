-- TESTS/window_spec.lua -- the mpv window `preview.video` hands off to.
--
-- What is worth a spec here is not "does mpv open" (that needs a real mpv
-- and a display, and media.nvim's own suite already covers `play_window`'s
-- argv) but the one thing this module adds on top: it asks `preview.monitor`
-- which screen the terminal is on and passes that through, so mpv centres
-- where the reader actually is rather than always on screen 0.

local window = require("hover.preview.window")

describe("hover.preview.window", function()
  before_each(function()
    window.close()
    package.loaded["media"] = nil
    package.loaded["hover.preview.monitor"] = nil
  end)

  it("passes the detected screen through to media.play_window", function()
    local seen_opts
    package.loaded["media"] = {
      play_window = function(_, opts)
        seen_opts = opts
        return {
          stopped = function()
            return false
          end,
          stop = function() end,
        }
      end,
    }
    package.loaded["hover.preview.monitor"] = {
      detect = function()
        return { screen = 1, x = 1920, y = 0, w = 1920, h = 1080 }
      end,
    }

    local ok = window.open({ path = "/tmp/clip.mp4", at = 0 })
    assert.is_true(ok)
    assert.are.equal(1, seen_opts.screen)
  end)

  it("passes no screen when the terminal's monitor cannot be detected", function()
    local seen_opts
    package.loaded["media"] = {
      play_window = function(_, opts)
        seen_opts = opts
        return {
          stopped = function()
            return false
          end,
          stop = function() end,
        }
      end,
    }
    package.loaded["hover.preview.monitor"] = {
      detect = function()
        return nil
      end,
    }

    local ok = window.open({ path = "/tmp/clip.mp4", at = 0 })
    assert.is_true(ok)
    assert.is_nil(seen_opts.screen)
  end)

  it("still opens fine when preview.monitor has no detect() to call", function()
    -- The type check is not decoration: an older or unexpected shape of this
    -- module must not turn every video hover into a crash the moment mpv
    -- would otherwise have played happily.
    local seen_opts
    package.loaded["media"] = {
      play_window = function(_, opts)
        seen_opts = opts
        return {
          stopped = function()
            return false
          end,
          stop = function() end,
        }
      end,
    }
    package.loaded["hover.preview.monitor"] = {}

    local ok = window.open({ path = "/tmp/clip.mp4", at = 0 })
    assert.is_true(ok)
    assert.is_nil(seen_opts.screen)
  end)
end)
