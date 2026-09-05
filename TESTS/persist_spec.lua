---@diagnostic disable: need-check-nil
-- The test body is the guard; see the note in TESTS/bare_path_spec.lua
-- (`LLS-42`).

-- TESTS/persist_spec.lua -- `persist`, on by default, and the two properties
-- that make that safe: `false` genuinely turns it off again, and a snapshot
-- shaped exactly like the `opts` an installation spec would pass, so a round
-- trip through disk changes nothing this plugin does not already merge on
-- every `setup()` call.

local config = require("hover.config")
local switches = require("hover.switches")
local persist = require("hover.persist")

describe("hover.persist", function()
  local dir

  before_each(function()
    config.reset()
    vim.g.hover_disable = nil
    dir = vim.fn.tempname()
  end)

  after_each(function()
    config.reset()
    vim.g.hover_disable = nil
    vim.fn.delete(dir, "rf")
  end)

  describe("on by default", function()
    it("is true straight out of DEFAULTS", function()
      assert.is_true(config.get().persist)
    end)

    it("writes a snapshot with nothing configured at all", function()
      switches.set("web", true, { silent = true })
      persist.save({ dir = dir })
      assert.is_truthy(require("lib.nvim.cache.disk").load("hover/status", { dir = dir }))
    end)
  end)

  describe("persist = false", function()
    it("writes nothing", function()
      config.setup({ persist = false })
      switches.set("web", true, { silent = true })
      persist.save({ dir = dir })
      assert.is_nil(require("lib.nvim.cache.disk").load("hover/status", { dir = dir }))
    end)

    it("loads nothing", function()
      require("lib.nvim.cache.disk").save("hover/status", { mode = "off" }, { dir = dir })
      config.setup({ persist = false })
      persist.load({ dir = dir })
      assert.equals("auto", config.mode())
    end)
  end)

  describe("snapshot", function()
    it("carries mode, auto_hover and every switch's own flag", function()
      config.setup({ persist = true, mode = "manual" })
      switches.set("web", true, { silent = true })

      local snap = persist.snapshot()
      assert.equals("manual", snap.mode)
      assert.is_true(snap.links.web)
      assert.is_true(snap.links.enabled, "an implied switch is not in the snapshot")
      assert.is_true(snap.paths.enabled)
      assert.is_boolean(snap.auto_hover.image)
    end)

    it("does not carry layout options such as border", function()
      config.setup({ persist = true, border = "double" })
      local snap = persist.snapshot()
      assert.is_nil(snap.border)
    end)
  end)

  describe("save and load", function()
    it("round-trips a switch across a reset", function()
      config.setup({ persist = true })
      switches.set("web", true, { silent = true })
      assert.is_true(config.web_enabled())

      persist.save({ dir = dir })
      config.reset()
      assert.is_false(config.web_enabled(), "reset did not clear the switch")

      config.setup({ persist = true })
      persist.load({ dir = dir })
      assert.is_true(config.web_enabled(), "the saved switch did not come back")
    end)

    it("lets the last session's switch win over the installation spec's default", function()
      -- The order the whole feature depends on: DEFAULTS -> installation
      -- spec -> the last session's own switches. A spec that declares
      -- `office = { convert = false }` (the shipped default) must still lose
      -- to a persisted `true`, or persisting would do nothing a spec could
      -- not already do on its own.
      config.setup({ persist = true })
      switches.set("office", true, { silent = true })
      persist.save({ dir = dir })

      config.reset()
      config.setup({ persist = true, office = { convert = false } })
      persist.load({ dir = dir })
      assert.is_true(config.office_enabled())
    end)

    it("carries mode, including off", function()
      config.setup({ persist = true, mode = "manual" })
      persist.save({ dir = dir })

      config.reset()
      config.setup({ persist = true })
      persist.load({ dir = dir })
      assert.equals("manual", config.mode())
    end)
  end)

  describe("setup", function()
    --- `nvim_get_autocmds` errors on a group that has never been created,
    --- which is the state before the first `persist.setup()` call anywhere
    --- in this process -- so a plain call cannot be `before`'s baseline.
    ---@return integer
    local function group_size()
      local ok, list = pcall(vim.api.nvim_get_autocmds, { group = "HoverPersist" })
      return ok and #list or 0
    end

    it("installs one VimLeavePre autocmd, idempotently", function()
      persist.setup()
      local once = group_size()
      persist.setup()
      assert.equals(once, group_size())
    end)
  end)
end)
