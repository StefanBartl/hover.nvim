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
      { "links", "web", "fetch", "paths", "missing", "code", "positions", "images", "office" },
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
    it("is dropped when a switch changes what a preview reads", function()
      local target = { type = "file", raw = "x", path = nil }
      local key = cache.key(target)
      cache.put(key, { lines = { "stale" } })
      assert.is_truthy(cache.get(key))

      switches.set("images", nil, { silent = true })
      assert.is_nil(cache.get(key))
    end)

    it("is kept when a switch changes only what counts as a target", function()
      -- `paths code` decides where a path is looked for, not how anything is
      -- rendered. A rasterized PDF page cached before the toggle is still
      -- that page, and used to be thrown away with everything else.
      local key = cache.key({ type = "pdf", raw = "doc.pdf", path = nil })
      cache.put(key, { lines = { "page 1" } })
      switches.set("code", nil, { silent = true })
      assert.is_truthy(cache.get(key))
    end)

    it("keeps it for every finding switch, and drops it for every rendering one", function()
      -- Written over the switch table rather than over a list, so a tenth
      -- switch is classified the moment it is declared -- the same shape the
      -- specs above use, for the same reason.
      local config = require("hover.config")
      for _, name in ipairs(switches.names()) do
        config.reset()
        vim.g.hover_disable = nil
        local key = cache.key({ type = "pdf", raw = "doc.pdf", path = nil })
        cache.put(key, { lines = { "page 1" } })

        local before = vim.inspect(config.preview_opts())
        switches.set(name, nil, { silent = true })
        local changed = vim.inspect(config.preview_opts()) ~= before

        if changed then
          assert.is_nil(cache.get(key), ("%q changed preview_opts and kept the cache"):format(name))
        else
          assert.is_truthy(
            cache.get(key),
            ("%q changed nothing a preview reads and dropped the cache anyway"):format(name)
          )
        end
      end
      config.reset()
      vim.g.hover_disable = nil
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
      -- Every value a route declares for an argument, read off the same
      -- routes rather than kept as a list here. This *was* a list, naming
      -- five values, and it was already two short (`bigger`/`smaller`) before
      -- `zoom` and `nav` arrived with seven more -- at which point a source
      -- comment saying `:Hover zoom in` was reported as naming a command that
      -- does not exist. `TESTS/docs_spec.lua` kept a second copy of the same
      -- list and fell behind in exactly the same way on the same day.
      local STATES = {}
      for _, handle in ipairs(registry.all()) do
        if handle:name() == "Hover" then
          for _, route in ipairs(handle:spec().routes or {}) do
            routes[table.concat(route.path or {}, " ")] = true
            for _, arg in ipairs(route.args or {}) do
              for _, value in ipairs(arg.enum or {}) do
                STATES[value] = true
              end
            end
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

-- `:Hover why`. A hover that does not open is silent by design and has seven
-- possible reasons, which look identical from the outside. The one thing this
-- must not become is a second implementation of the rules -- so what these
-- specs pin is that it names the *right* reason, case by case, rather than
-- that it produces some output.
describe("hover.why", function()
  local hover = require("hover")
  local api = vim.api
  local root, win, prev_buf, prev_isfname, buf

  before_each(function()
    config.reset()
    -- `set_mode` keeps this in step with the runtime mode, and it outlives
    -- `config.reset()` -- the same trap the specs above already guard.
    vim.g.hover_disable = nil
    require("hover.registry").reset()
    root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    vim.fn.writefile({ "# real" }, root .. "/real.md")

    win = api.nvim_get_current_win()
    prev_buf = api.nvim_win_get_buf(win)
    prev_isfname = vim.o.isfname
    vim.o.isfname = "@,48-57,/,.,-,_,+,,,#,$,%,~,=,:"

    buf = api.nvim_create_buf(true, false)
    api.nvim_buf_set_name(buf, root .. "/notes.md")
    api.nvim_win_set_buf(win, buf)
  end)

  after_each(function()
    pcall(api.nvim_win_set_buf, win, prev_buf)
    pcall(api.nvim_buf_delete, buf, { force = true })
    vim.o.isfname = prev_isfname
    vim.fn.delete(root, "rf")
    config.reset()
    vim.g.hover_disable = nil
    require("hover.registry").reset()
  end)

  ---@param line string
  ---@param col integer
  ---@return string
  local function why_at(line, col)
    api.nvim_buf_set_lines(buf, 0, -1, false, { line })
    api.nvim_win_set_cursor(win, { 1, col })
    return table.concat(hover.why(), "\n")
  end

  it("names the mode when the mode is what stopped it", function()
    hover.set_mode("off")
    local report = why_at("see ./real.md ok", 4)
    assert.is_truthy(report:find("mode: off", 1, true))
    assert.is_truthy(report:find("Hover mode auto", 1, true))
  end)

  it("names the buffer type, which is checked before anything else", function()
    local scratch = api.nvim_create_buf(false, true)
    api.nvim_win_set_buf(win, scratch)
    api.nvim_buf_set_lines(scratch, 0, -1, false, { "see ./real.md ok" })
    api.nvim_win_set_cursor(win, { 1, 4 })
    local report = table.concat(hover.why(), "\n")
    assert.is_truthy(report:find("buftype", 1, true))
    api.nvim_win_set_buf(win, buf)
    pcall(api.nvim_buf_delete, scratch, { force = true })
  end)

  it("reports the target when there is one", function()
    local report = why_at("see ./real.md ok", 4)
    assert.is_truthy(report:find("target:", 1, true))
    assert.is_truthy(report:find("./real.md", 1, true))
  end)

  it("says the token is not shaped like a path, and shows the token", function()
    local report = why_at("ordinary prose here", 2)
    assert.is_truthy(report:find("not shaped like a path", 1, true))
    assert.is_truthy(report:find("ordinary", 1, true))
  end)

  it("says the class is off when bare paths are off", function()
    config.setup({ paths = { enabled = false } })
    local report = why_at("see ./real.md ok", 4)
    assert.is_truthy(report:find("bare paths: off", 1, true))
  end)

  it("mentions a registered position preview that had nothing to say", function()
    require("hover.registry").register("p", {
      positions = {
        function()
          return nil
        end,
      },
    })
    local report = why_at("ordinary prose here", 2)
    assert.is_truthy(report:find("positions:", 1, true))
  end)

  it("says the position class is off when it is", function()
    require("hover.registry").register("p", {
      positions = {
        function()
          return { lines = { "x" } }
        end,
      },
    })
    config.setup({ positions = false })
    local report = why_at("ordinary prose here", 2)
    assert.is_truthy(report:find("Hover positions on", 1, true))
  end)
end)

-- The generic version of a bug that has now happened twice: a consumer of
-- `SWITCHES` with its own hand-written list, which a newly added switch falls
-- out of without anything failing. `route_path` was the first (`ac50599`,
-- a switch registered at the wrong place in the command tree); `effective`
-- was the second, and reported `positions` as off while it was on -- in
-- `:Hover status` and in `:checkhealth` alike, since both read from there.
--
-- These specs are written over `switches.names()` rather than over a list, so
-- a tenth switch is covered the moment it is declared. That is the only shape
-- that actually prevents the third occurrence.
describe("every switch, generically", function()
  before_each(function()
    config.reset()
    vim.g.hover_disable = nil
  end)

  after_each(function()
    config.reset()
    vim.g.hover_disable = nil
  end)

  it("reports its own state, rather than a hardcoded reader's", function()
    for _, name in ipairs(switches.names()) do
      switches.set(name, true, { silent = true })
      assert.is_true(
        switches.enabled(name),
        ("%q was switched on and did not report as on"):format(name)
      )
      switches.set(name, false, { silent = true })
      assert.is_false(
        switches.enabled(name),
        ("%q was switched off and did not report as off"):format(name)
      )
      config.reset()
    end
  end)

  it("appears in status with the state it actually has", function()
    for _, name in ipairs(switches.names()) do
      switches.set(name, true, { silent = true })
      local seen = false
      for _, row in ipairs(switches.status()) do
        if row.name == name then
          seen = true
          assert.is_true(row.enabled, ("status reported %q as off while it was on"):format(name))
        end
      end
      assert.is_true(seen, ("%q is missing from status entirely"):format(name))
      config.reset()
    end
  end)

  it("has a config path that resolves to a boolean in the defaults", function()
    -- What makes the derived reader exact rather than a default-direction
    -- guess: every switch path carries a concrete boolean before any merge.
    local defaults = require("hover.config.DEFAULTS")
    for _, name in ipairs(switches.names()) do
      -- Annotated rather than inferred: the walk starts at `Hover.Config` and
      -- descends out of it, which LuaLS reads as `cast-local-type` -- but only
      -- on some runs. Measured 2026-09-02 on unchanged source: one scan in
      -- five reported it, four reported nothing. A diagnostic that flickers is
      -- worse than one that stands, because this scan is read as a regression
      -- signal and a `+1` then costs a hunt for a change that never happened.
      ---@type any
      local node = defaults
      for _, key in ipairs(switches.spec(name).path) do
        assert.is_table(node, ("%q has a path that leaves the defaults"):format(name))
        node = node[key]
      end
      assert.equals("boolean", type(node), ("%q does not point at a boolean default"):format(name))
    end
  end)
end)

-- The master switch, and the one gate `force` must not open.
--
-- `force` is for the volume switches: a key pressed on purpose is not the
-- noise problem those solve, so an explicit request answers for a web link
-- even with `links web off`. The *mode* is not one of them. `mode = "off"`
-- reads "nothing at all", and `vim.g.hover_disable` -- a reader's veto over a
-- host plugin that switched the hover on -- reaches the code as that mode.
--
-- Until 2026-09-02 `show` skipped the check whenever `force` was set, so
-- `:Hover show`, `keymaps.show` and any host's own keymap (markdown.nvim
-- binds one) opened a float in both cases. `:Hover why` reported "mode: off"
-- as the reason nothing had appeared, which is the shape of the bug: two
-- routes disagreeing about the same switch.
describe("the master switch against an explicit request", function()
  local hover = require("hover")
  local registry = require("hover.registry")

  before_each(function()
    config.reset()
    registry.reset()
    vim.g.hover_disable = nil
    -- Something that always answers, so a `false` can only come from a gate.
    registry.register("probe", {
      positions = {
        function()
          return { lines = { "probe" } }
        end,
      },
    })
  end)

  after_each(function()
    hover.hide()
    config.reset()
    registry.reset()
    vim.g.hover_disable = nil
  end)

  it("refuses a forced request in mode off", function()
    config.setup({ mode = "off" })
    assert.is_false(hover.show({ force = true }))
  end)

  it("refuses a forced request under vim.g.hover_disable", function()
    config.setup({ mode = "auto" })
    vim.g.hover_disable = true
    assert.is_false(hover.show({ force = true }))
  end)

  it("still answers a forced request in manual, the mode that is for it", function()
    config.setup({ mode = "manual" })
    assert.is_true(hover.show({ force = true }))
  end)
end)
