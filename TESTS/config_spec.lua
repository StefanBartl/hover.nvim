---@diagnostic disable: need-check-nil
-- The test body is the guard; see the note in TESTS/bare_path_spec.lua
-- (`LLS-42`).

-- TESTS/config_spec.lua -- the merge, and the three ways it is not a plain
-- `tbl_deep_extend`.
--
--   1. **Legacy shapes normalize.** `enabled`, `bare_paths` and `url` were
--      the documented spelling while this plugin lived inside `lib.nvim`,
--      and markdown.nvim passes its own `hover = { ... }` table straight
--      through. A caller has no way of knowing the plugin moved, so the old
--      names keep working and are rewritten on the way in -- liberal in,
--      canonical out. Nothing downstream ever sees the tolerant form.
--   2. **Key lists replace, never extend.** `tbl_deep_extend` merges lists
--      by index, so `{ "<C-c>" }` over `{ "q", "<Esc>" }` leaves `<Esc>`
--      sitting at index 2 and still bound -- a closed, curated list needs an
--      explicit override (`ERR-52`).
--   3. **The caller's table is not mutated.** Normalization rewrites keys,
--      and markdown.nvim hands over its own live config table.

local config = require("hover.config")

describe("hover.config", function()
  before_each(function()
    config.reset()
    vim.g.hover_disable = nil
  end)

  after_each(function()
    config.reset()
    vim.g.hover_disable = nil
  end)

  describe("defaults", function()
    it("opens by itself, on links and bare paths", function()
      assert.equals("auto", config.mode())
      assert.is_true(config.links_enabled())
      assert.is_true(config.paths_enabled())
      assert.is_true(config.missing_enabled())
      assert.is_true(config.images_enabled())
    end)

    it("leaves the three costly classes off", function()
      -- web: the offline preview restates the link text.
      -- fetch: it discloses every link brushed past to its host.
      -- office: it is a LibreOffice start per document.
      assert.is_false(config.web_enabled())
      assert.is_false(config.fetch_enabled())
      assert.is_false(config.office_enabled())
    end)
  end)

  describe("legacy option shapes", function()
    it("reads enabled = false as mode = off", function()
      config.setup({ enabled = false })
      assert.equals("off", config.mode())
      assert.is_nil(config.raw().enabled)
    end)

    it("does not let enabled = false override an explicit mode", function()
      config.setup({ enabled = false, mode = "manual" })
      assert.equals("manual", config.mode())
    end)

    it("reads bare_paths as paths.enabled", function()
      config.setup({ bare_paths = false })
      assert.is_false(config.paths_enabled())
      assert.is_nil(config.raw().bare_paths)
    end)

    it("folds url = { hover, fetch, timeout_ms } into links", function()
      config.setup({ url = { hover = true, fetch = true, timeout_ms = 500 } })
      assert.is_true(config.web_enabled())
      assert.is_true(config.fetch_enabled())
      assert.equals(500, config.preview_opts().url_timeout_ms)
      assert.is_nil(config.raw().url)
    end)

    it("lets a canonical key win over the legacy one it maps to", function()
      config.setup({ bare_paths = true, paths = { enabled = false } })
      assert.is_false(config.paths_enabled())
    end)

    it("does not mutate the caller's table", function()
      -- markdown.nvim passes its own live config through; rewriting keys in
      -- place would edit that plugin's configuration as a side effect.
      local mine = { url = { hover = true }, bare_paths = false }
      config.setup(mine)
      assert.equals("table", type(mine.url))
      assert.is_false(mine.bare_paths)
    end)
  end)

  describe("key lists", function()
    it("replaces dismiss_keys rather than merging by index", function()
      config.setup({ dismiss_keys = { "<C-c>" } })
      assert.equals(1, #config.get().dismiss_keys)
      assert.equals("<C-c>", config.get().dismiss_keys[1])
    end)

    it("replaces one scroll direction and leaves the other alone", function()
      config.setup({ scroll_keys = { down = "<C-n>" } })
      assert.equals("<C-n>", config.get().scroll_keys.down)
      assert.equals(2, #config.get().scroll_keys.up)
    end)

    it("accepts an empty list as 'bind nothing'", function()
      config.setup({ dismiss_keys = {} })
      assert.equals(0, #config.get().dismiss_keys)
    end)
  end)

  describe("the global kill switch", function()
    it("outranks whatever a host configured", function()
      config.setup({ mode = "auto" })
      vim.g.hover_disable = true
      assert.equals("off", config.mode())
      assert.is_false(config.is_enabled())
    end)

    it("does not permanently overwrite the stored mode", function()
      config.setup({ mode = "auto" })
      vim.g.hover_disable = true
      local _ = config.mode()
      vim.g.hover_disable = nil
      assert.equals("auto", config.mode())
    end)
  end)

  describe("validation", function()
    it("degrades an unknown mode to the default rather than aborting setup", function()
      -- `ERR-22`: one bad value must not take the whole configuration with
      -- it. `:checkhealth hover` is where it becomes visible.
      -- The invalid value is the point of the test, so the narrowed enum
      -- rejecting it is correct and the suppression is the honest answer
      -- rather than a workaround (`LLS-40`).
      ---@diagnostic disable-next-line: assign-type-mismatch
      config.setup({ mode = "sideways", max_lines = 7 })
      assert.equals("auto", config.mode())
      assert.equals(7, config.get().max_lines)
    end)
  end)

  describe("is_enabled vs is_auto", function()
    it("separates 'would open at all' from 'opens by itself'", function()
      config.setup({ mode = "manual" })
      assert.is_true(config.is_enabled())
      assert.is_false(config.is_auto())

      config.setup({ mode = "off" })
      assert.is_false(config.is_enabled())
      assert.is_false(config.is_auto())
    end)
  end)
end)

-- The office conversion cache outlives the session now, which is only safe
-- because something retires it. These pin the wiring of that policy; the
-- sweep itself needs LibreOffice and a real cache directory, and is evidenced
-- by hand (docs/MANUAL-EVIDENCE.md).
describe("the office cache policy", function()
  after_each(function()
    config.reset()
  end)

  it("reaches the preview as an option, not as a constant", function()
    assert.equals(7, config.preview_opts().office_cache_days)
  end)

  it("is configurable, including to zero", function()
    config.setup({ office = { cache_days = 30 } })
    assert.equals(30, config.preview_opts().office_cache_days)
    config.setup({ office = { cache_days = 0 } })
    -- Zero means "keep nothing between sessions", the pre-cache behaviour,
    -- and must survive the `or DEFAULTS` fallback rather than being read as
    -- unset.
    assert.equals(0, config.preview_opts().office_cache_days)
  end)
end)
