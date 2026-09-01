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
      { "links", "web", "fetch", "paths", "missing", "code", "images", "office" },
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

  -- The command tree is the third consumer of this table, after dispatch and
  -- `status`, and the one that used to be able to fall behind it silently.
  -- `route_path` was a hand-written `if name == "web" then ... elseif` chain;
  -- a switch added without a matching branch landed at the top level instead
  -- of under its parent, and nothing anywhere failed. It is derived from
  -- `implies` now, and this is what says so.
  describe("the command tree", function()
    --- Every `:Hover …` route path the verb was registered with.
    ---@return table<string, true>
    local function registered_paths()
      require("hover.bindings.usrcmds").setup()
      local registry = require("lib.nvim.bindings.usercmd.composer.registry")
      local out = {}
      for _, handle in ipairs(registry.all()) do
        if handle:name() == "Hover" then
          for _, route in ipairs(handle:spec().routes or {}) do
            out[table.concat(route.path or {}, " ")] = true
          end
        end
      end
      return out
    end

    it("nests every switch under the switch it implies", function()
      local paths = registered_paths()
      for _, name in ipairs(switches.names()) do
        local spec = switches.spec(name)
        local want = name
        local cursor, guard = spec, 0
        while cursor and cursor.implies and guard < 10 do
          want = cursor.implies .. " " .. want
          cursor = switches.spec(cursor.implies)
          guard = guard + 1
        end
        assert.is_true(
          paths[want] == true,
          ("switch %q should be reachable as `:Hover %s`"):format(name, want)
        )
      end
    end)

    it("puts no switch at the top level that implies something", function()
      -- The exact shape of the bug: `code` implies `paths`, so a bare
      -- `:Hover code` route means the nesting was lost.
      local paths = registered_paths()
      for _, name in ipairs(switches.names()) do
        if switches.spec(name).implies then
          assert.is_nil(
            paths[name],
            ("%q implies something, so `:Hover %s` must not exist on its own"):format(name, name)
          )
        end
      end
    end)
  end)

  -- Every `:Hover …` this plugin names in its own source has to be a command
  -- that exists. Two bugs of exactly this shape landed within a day of each
  -- other: `preview/office.lua` put `:Lib hover office on` in the badge a
  -- reader sees when a `.docx` will not render -- a command deleted with
  -- lib.nvim's copy -- and the `code` switch registered as `:Hover code`
  -- while every document called it `:Hover paths code`. Neither failed
  -- anything. A float telling someone to type a command that does not exist
  -- is worse than saying nothing.
  describe("the commands this plugin names in its own text", function()
    local STATES = { on = true, off = true, toggle = true, auto = true, manual = true }

    --- Every `lua/**/*.lua` file, read.
    ---@return table<string, string>
    local function sources()
      local out = {}
      for _, file in ipairs(vim.fn.glob(vim.fn.getcwd() .. "/lua/**/*.lua", false, true)) do
        local fd = io.open(file, "r")
        if fd then
          out[file] = fd:read("*a")
          fd:close()
        end
      end
      return out
    end

    it("names only commands that are actually registered", function()
      local files = sources()
      assert.is_true(vim.tbl_count(files) > 0, "found no sources to scan")

      require("hover.bindings.usrcmds").setup()
      local registry = require("lib.nvim.bindings.usercmd.composer.registry")
      local routes = {}
      for _, handle in ipairs(registry.all()) do
        if handle:name() == "Hover" then
          for _, route in ipairs(handle:spec().routes or {}) do
            routes[table.concat(route.path or {}, " ")] = true
          end
        end
      end

      local bad = {}
      for file, text in pairs(files) do
        for mention in text:gmatch(":Hover([ a-z]*)") do
          local words = {}
          for word in mention:gmatch("%a+") do
            words[#words + 1] = word
          end
          -- Trailing state arguments are not part of the route path:
          -- `:Hover paths on` is the `paths` route with an argument.
          while #words > 0 and STATES[words[#words]] do
            table.remove(words)
          end
          local path = table.concat(words, " ")
          -- A bare `:Hover` is the verb itself and always exists.
          if path ~= "" and not routes[path] then
            bad[#bad + 1] = ("%s names `:Hover %s`"):format(vim.fn.fnamemodify(file, ":."), path)
          end
        end
      end

      assert.same({}, bad)
    end)
  end)
end)
