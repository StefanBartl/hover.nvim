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

  describe("loading an untrusted file (SEC-33)", function()
    -- The file on disk is a snapshot this plugin wrote, but read back as
    -- untrusted: hand-edited, half-written, or from an older version with a
    -- different shape. Every case here writes something `M.snapshot()`
    -- itself never would, straight through `lib.nvim.cache.disk`, bypassing
    -- the write side's own discipline entirely.
    local disk = require("lib.nvim.cache.disk")

    it("drops a key it does not know, rather than merging it in unfiltered", function()
      disk.save("hover/status", { mode = "manual", max_lines = {} }, { dir = dir })
      config.setup({ persist = true })

      persist.load({ dir = dir })

      assert.equals("manual", config.mode(), "a known, valid key was not applied")
      -- `max_lines = {}` is not part of the snapshot shape at all, so it must
      -- never reach `config.setup` -- a table there survives `c.max_lines or
      -- DEFAULTS.max_lines` (a table is truthy) and later breaks `#out >=
      -- limit` in preview/text.lua with a number/table comparison.
      assert.is_number(config.preview_opts().max_lines)
    end)

    it("drops a switch flag whose value is not a boolean", function()
      disk.save("hover/status", { links = { web = "yes" } }, { dir = dir })
      config.setup({ persist = true })

      persist.load({ dir = dir })

      assert.is_boolean(
        config.raw().links.web,
        "a non-boolean switch value reached the merged config"
      )
      assert.is_false(config.web_enabled())
    end)

    it("drops auto_hover entries whose value is not a boolean", function()
      disk.save("hover/status", { auto_hover = { image = true, file = "always" } }, { dir = dir })
      config.setup({ persist = true })

      persist.load({ dir = dir })

      assert.is_true(config.auto_hover_for("image"))
      -- A non-boolean entry is dropped rather than merged in: `file` keeps
      -- whatever `DEFAULTS` already says (a real boolean), and the bogus
      -- string itself never reaches `_options` at all.
      assert.is_boolean(config.raw().auto_hover.file)
      assert.is_false(config.raw().auto_hover.file, "DEFAULTS.auto_hover.file is false")
    end)

    it("drops a mode that is not a string, instead of handing it to setup() raw", function()
      disk.save("hover/status", { mode = { "off" } }, { dir = dir })
      config.setup({ persist = true, mode = "manual" })

      assert.has_no.errors(function()
        persist.load({ dir = dir })
      end)
      assert.equals("manual", config.mode(), "a non-string mode overwrote the spec's own value")
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
