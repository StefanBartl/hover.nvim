---@diagnostic disable: need-check-nil
-- The test body is the guard; see the note in TESTS/bare_path_spec.lua
-- (`LLS-42`).

-- TESTS/config_layers_spec.lua -- who owns which part of the configuration.
--
-- `markdown` (markdown.nvim's `hover = {}` table) < `setup` (the installation spec) < `persist` (the reader's
-- earlier sessions) < `runtime` (what they switch now). A writer replaces only its own layer; a runtime switch
-- is not undone by a later `setup()`.

local config = require("hover.config")

describe("hover.config layers", function()
  before_each(function()
    config.reset()
    vim.g.hover_disable = nil
  end)

  after_each(function()
    config.reset()
    vim.g.hover_disable = nil
  end)

  it("replaces its own layer on a second setup, so a dropped option is gone", function()
    config.setup({ delay_ms = 900, max_lines = 7 })
    assert.equals(900, config.get().delay_ms)
    config.setup({ max_lines = 9 })
    assert.equals(9, config.get().max_lines)
    assert.equals(require("hover.config.DEFAULTS").delay_ms, config.get().delay_ms)
  end)

  it("lets the installation spec outrank markdown.nvim, whichever speaks first", function()
    config.setup({ delay_ms = 111, max_lines = 5 }, "markdown")
    config.setup({ delay_ms = 222 })
    assert.equals(222, config.get().delay_ms)
    assert.equals(5, config.get().max_lines)
    config.reset()
    config.setup({ delay_ms = 222 })
    config.setup({ delay_ms = 111 }, "markdown")
    assert.equals(222, config.get().delay_ms)
  end)

  it("puts what the reader touched before the spec", function()
    config.setup({ mode = "manual" })
    config.setup({ mode = "off" }, "persist")
    assert.equals("off", config.mode())
  end)

  it("keeps a runtime switch across a later setup() and clears it on reset()", function()
    config.setup({ mode = "auto" })
    config.set_runtime({ "mode" }, "manual")
    config.setup({ mode = "auto", delay_ms = 400 })
    assert.equals("manual", config.mode())
    assert.equals(400, config.get().delay_ms)
    config.reset()
    assert.equals("auto", config.mode())
  end)

  it("keeps a switch flipped through :Hover across a later setup()", function()
    config.setup({ links = { web = false } })
    require("hover.switches").set("web", true, { silent = true })
    assert.is_true(config.web_enabled())
    config.setup({ links = { web = false, timeout_ms = 900 } })
    assert.is_true(config.web_enabled())
    assert.equals(900, config.get().links.timeout_ms)
  end)

  it("takes a key list from a layer whole, never by index", function()
    config.setup({ dismiss_keys = { "<C-c>" }, scroll_keys = { down = { "<C-n>" } } })
    assert.same({ "<C-c>" }, config.get().dismiss_keys)
    assert.same({ "<C-n>" }, config.get().scroll_keys.down)
    assert.same(require("hover.config.DEFAULTS").scroll_keys.up, config.get().scroll_keys.up)
  end)

  it("accepts a bare boolean for a class and a string for a key", function()
    config.setup({ links = false, scroll_keys = { down = "<C-n>" } })
    assert.is_false(config.links_enabled())
    assert.equals("<C-n>", config.get().scroll_keys.down)
  end)

  it("reports an unknown option and keeps the default", function()
    config.setup({ delay_msx = 5, max_lines = "many" })
    assert.equals(require("hover.config.DEFAULTS").max_lines, config.get().max_lines)
    local seen = table.concat(config.issues(), "\n")
    assert.matches("delay_msx", seen)
    assert.matches("max_lines", seen)
  end)
end)
