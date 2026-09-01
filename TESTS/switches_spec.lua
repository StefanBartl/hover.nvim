---@diagnostic disable: need-check-nil
-- The test body is the guard; see the note in TESTS/bare_path_spec.lua
-- (`LLS-42`).

-- TESTS/switches_spec.lua -- the switch table, and the two asymmetries in it
-- that are easy to "fix" into a bug.
--
--   1. **Implication runs upward only.** Turning `fetch` on turns `web` on,
--      and `web` turns `links` on. Turning `links` *off* must not clear
--      `web` -- the read side already answers that, and clearing the flag
--      would quietly demote a setting the user never changed, so turning
--      `links` back on would silently come back with less than it had.
--   2. **Every change drops the preview cache.** It is keyed by what a
--      target is, not by how it was rendered, so a stale entry answers with
--      the old preview and makes the switch look like it did nothing.

local config = require("hover.config")
local switches = require("hover.switches")
local cache = require("hover.cache")

describe("hover.switches", function()
  before_each(function()
    config.reset()
    vim.g.hover_disable = nil
  end)

  after_each(function()
    config.reset()
    vim.g.hover_disable = nil
  end)

  it("lists every switch in hierarchy order, not hash order", function()
    assert.same(
      { "links", "web", "fetch", "paths", "missing", "images", "office" },
      switches.names()
    )
  end)

  describe("implication", function()
    it("turns on everything a switch needs to mean anything", function()
      switches.set("fetch", true, { silent = true })
      assert.is_true(switches.enabled("fetch"))
      assert.is_true(switches.enabled("web"))
      assert.is_true(switches.enabled("links"))
    end)

    it("silences a child when the parent goes off, without demoting it", function()
      switches.set("web", true, { silent = true })
      switches.set("links", false, { silent = true })

      assert.is_false(switches.enabled("web"))
      -- The flag itself is untouched: that is what makes turning the parent
      -- back on restore the child rather than reset it.
      assert.is_true(config.raw().links.web)

      switches.set("links", true, { silent = true })
      assert.is_true(switches.enabled("web"))
    end)

    it("does not cascade downward when a switch goes off", function()
      switches.set("fetch", true, { silent = true })
      switches.set("web", false, { silent = true })
      assert.is_false(switches.enabled("fetch"))
      assert.is_true(config.raw().links.fetch)
    end)
  end)

  describe("toggling", function()
    it("flips the current state when no state is given", function()
      assert.is_true(switches.enabled("paths"))
      switches.set("paths", nil, { silent = true })
      assert.is_false(switches.enabled("paths"))
      switches.set("paths", nil, { silent = true })
      assert.is_true(switches.enabled("paths"))
    end)
  end)

  describe("unknown names", function()
    it("answers nil plus a message, not false", function()
      -- `ERR-10`: "there is no such switch" and "the switch is now off" are
      -- different answers and must not collapse onto one value.
      local on, err = switches.set("nope", true)
      assert.is_nil(on)
      assert.equals("string", type(err))
      assert.is_nil(switches.spec("nope"))
    end)
  end)

  describe("the preview cache", function()
    it("is dropped on any change", function()
      local target = { type = "file", raw = "x", path = nil }
      local key = cache.key(target)
      cache.put(key, { lines = { "stale" } })
      assert.is_truthy(cache.get(key))

      switches.set("images", nil, { silent = true })
      assert.is_nil(cache.get(key))
    end)
  end)

  describe("status", function()
    it("reports every switch with its effective state", function()
      switches.set("web", true, { silent = true })
      local seen = {}
      for _, s in ipairs(switches.status()) do
        seen[s.name] = s.enabled
        assert.equals("string", type(s.label))
      end
      assert.is_true(seen.web)
      assert.is_true(seen.links)
      assert.is_false(seen.office)
    end)

    it("reports the implied state, not the raw flag", function()
      switches.set("web", true, { silent = true })
      switches.set("links", false, { silent = true })
      for _, s in ipairs(switches.status()) do
        if s.name == "web" then
          assert.is_false(s.enabled)
        end
      end
    end)
  end)
end)

describe("hover.set_mode", function()
  local hover = require("hover")

  before_each(function()
    config.reset()
    vim.g.hover_disable = nil
  end)

  after_each(function()
    config.reset()
    vim.g.hover_disable = nil
  end)

  it("rejects an unknown mode with nil plus a message", function()
    -- Deliberately outside the enum: `set_mode` promising to reject it is
    -- exactly what is under test here (`LLS-40`).
    ---@diagnostic disable-next-line: param-type-mismatch
    local mode, err = hover.set_mode("sideways")
    assert.is_nil(mode)
    assert.equals("string", type(err))
  end)

  it("keeps vim.g.hover_disable in step, so the two cannot disagree", function()
    hover.set_mode("off")
    assert.is_true(vim.g.hover_disable)
    hover.set_mode("manual")
    assert.is_nil(vim.g.hover_disable)
    assert.equals("manual", hover.mode())
  end)

  it("leaves manual mode able to show, but not to open by itself", function()
    hover.set_mode("manual")
    assert.is_true(config.is_enabled())
    assert.is_false(config.is_auto())
  end)
end)
