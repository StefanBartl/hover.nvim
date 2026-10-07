---@diagnostic disable: need-check-nil, duplicate-set-field
-- The test body is the guard; see the note in TESTS/bare_path_spec.lua
-- (`LLS-42`).

-- TESTS/monitor_spec.lua -- `hover.preview.monitor`, and specifically the one
-- part of it that is not "run a real OS script and trust the machine it runs
-- on": the pattern that turns whatever came back on stdout into
-- `{ screen, x, y, w, h }`.
--
-- The script bodies themselves (PowerShell/AppleScript/bash, generated as
-- text and run for real against this machine's actual window manager) are
-- deliberately left untested here, the same as `hover.preview.align_win`:
-- there is no meaningful assertion to make about a string of embedded
-- PowerShell beyond "the Lua that builds it does not error", and the
-- CI workflow already documents that this whole family is evidenced only by
-- hand. What *is* ordinary, branching Lua -- and had no coverage at all
-- before this file -- is `M.detect`'s result parsing: `vim.system` is
-- stubbed to hand back canned stdout, per this campaign's convention that it
-- is a Neovim global rather than a `require()` upvalue and can be
-- monkeypatched directly.

local monitor = require("hover.preview.monitor")

describe("hover.preview.monitor.detect, parsing the helper script's stdout", function()
  local real_system

  before_each(function()
    real_system = vim.system
  end)

  after_each(function()
    vim.system = real_system
  end)

  ---@param stdout string
  ---@param code? integer
  local function stub_stdout(stdout, code)
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.system = function(_argv, _opts)
      return {
        wait = function()
          return { code = code or 0, stdout = stdout }
        end,
      }
    end
  end

  it("parses a well-formed line into screen/x/y/w/h", function()
    stub_stdout("0 100 200 800 600\n")
    local result = monitor.detect()
    assert.same({ screen = 0, x = 100, y = 200, w = 800, h = 600 }, result)
  end)

  it("creates the cache directory for the helper script when it is missing", function()
    -- A fresh profile has no cache directory yet; the script could not be written and detect()
    -- answered nil forever (the stubbed stdout was never even asked for).
    stub_stdout("0 1 2 3 4\n")
    monitor.detect()
    assert.equals(1, vim.fn.isdirectory(vim.fn.stdpath("cache")))
  end)

  it("reports no screen index for a negative screen, keeping the rectangle", function()
    -- macOS and Linux report `-1` for "no numbered screen"; the rectangle is
    -- still meaningful even without one.
    stub_stdout("-1 10 20 300 400\n")
    local result = monitor.detect()
    assert.same({ screen = nil, x = 10, y = 20, w = 300, h = 400 }, result)
  end)

  it("returns nil for stdout that does not match the expected shape", function()
    stub_stdout("not a geometry line at all")
    assert.is_nil(monitor.detect())
  end)

  it("returns nil for an empty stdout", function()
    stub_stdout("")
    assert.is_nil(monitor.detect())
  end)

  it("returns nil when the helper script exits non-zero", function()
    stub_stdout("0 100 200 800 600\n", 1)
    assert.is_nil(monitor.detect())
  end)

  it("returns nil rather than raising when vim.system itself throws", function()
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.system = function()
      error("spawn failed")
    end
    local ok, result = pcall(monitor.detect)
    assert.is_true(ok, "M.detect() propagated an error instead of answering nil")
    assert.is_nil(result)
  end)

  it("returns nil when wait() itself throws (e.g. a timeout)", function()
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.system = function()
      return {
        wait = function()
          error("timeout")
        end,
      }
    end
    local ok, result = pcall(monitor.detect)
    assert.is_true(ok)
    assert.is_nil(result)
  end)
end)
