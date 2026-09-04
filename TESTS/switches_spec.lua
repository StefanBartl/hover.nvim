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
    assert.same({
      "links",
      "web",
      "fetch",
      "pdf",
      "shot",
      "eager",
      "paths",
      "missing",
      "code",
      "positions",
      "images",
      "office",
    }, switches.names())
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

  -- The gate `:Hover why` did not know about, which is the one it was written
  -- for: a target that is found, allowed and not dismissed, and still does not
  -- open, because its *type* waits to be asked for. The old report ended at
  -- "this should hover. If it does not, that is a bug worth reporting."
  it("names the type gate, the second one every target passes", function()
    local report = why_at("see ./real.md ok", 4)
    assert.is_truthy(report:find("do not open by themselves", 1, true))
    assert.is_truthy(report:find("Hover auto markdown", 1, true))
  end)

  it("stops naming it once that type is allowed to open", function()
    config.setup({ auto_hover = { markdown = true } })
    local report = why_at("see ./real.md ok", 4)
    assert.is_truthy(report:find("this should hover", 1, true))
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

describe("auto_hover, the third axis", function()
  local hover = require("hover")
  local registry = require("hover.registry")
  local classify = require("hover.classify")
  local auto_types = require("hover.config.auto_types")

  before_each(function()
    config.reset()
    registry.reset()
    vim.g.hover_disable = nil
  end)

  after_each(function()
    hover.hide()
    config.reset()
    registry.reset()
    vim.g.hover_disable = nil
  end)

  -- The two hand-kept lists this feature adds, each held against the source
  -- it copies. Five times in this repository a copy like these has fallen
  -- behind the thing it copies, and every one of those was found by a person
  -- rather than by a run.
  it("knows exactly the target types Hover.Target declares", function()
    local fd = assert(io.open(vim.fn.getcwd() .. "/lua/hover/@types/init.lua", "r"))
    local text = fd:read("*a")
    fd:close()
    local union = text:match("@class Hover%.Target.-@field type ([^\n]+)")
    assert.is_truthy(union, "Hover.Target no longer declares its type union")

    local declared = {}
    for name in union:gmatch('"(%a+)"') do
      declared[#declared + 1] = name
    end
    table.sort(declared)

    local known = vim.deepcopy(classify.TYPES)
    table.sort(known)
    assert.same(declared, known, "classify.TYPES has drifted from the declared union")
  end)

  it("gives every name it accepts a default", function()
    -- A type missing from `DEFAULTS.auto_hover` would read as "not
    -- configured", and `auto_hover_for` fails open, so a new target type
    -- would arrive switched *on* while the table said nothing about it. That
    -- is the right direction for an unknown name and the wrong one for a
    -- known one, which is what this holds apart.
    local DEFAULTS = require("hover.config.DEFAULTS")
    for _, name in ipairs(auto_types()) do
      assert.is_boolean(
        DEFAULTS.auto_hover[name],
        ("DEFAULTS.auto_hover has no entry for %q"):format(name)
      )
    end
  end)

  it("opens pictures and pages by itself, and nothing else", function()
    local defaults = config.auto_hover()
    assert.is_true(defaults.image)
    assert.is_true(defaults.pdf)
    assert.is_false(defaults.file)
    assert.is_false(defaults.position)
  end)

  it("reads a list as a closed set rather than merging it", function()
    -- The trap `replace_key_lists` exists for, one option along: merged by
    -- index, `{ "file" }` would leave the default's second element in place
    -- and turn on a type nobody named.
    config.setup({ auto_hover = { "file" } })
    local now = config.auto_hover()
    assert.is_true(now.file)
    assert.is_false(now.image, "the default's first entry survived a list that did not name it")
    assert.is_false(now.pdf, "the default's second entry survived a list that did not name it")
  end)

  it("reads a table as an addition, which is how every other option merges", function()
    config.setup({ auto_hover = { file = true } })
    local now = config.auto_hover()
    assert.is_true(now.file)
    assert.is_true(now.image, "a partial table replaced the defaults instead of adding to them")
  end)

  it("reads true and false as both ends of the same axis", function()
    config.setup({ auto_hover = true })
    assert.is_true(config.auto_hover_for("file"))
    config.reset()
    config.setup({ auto_hover = false })
    assert.is_false(config.auto_hover_for("image"))
  end)

  it("fails open for a name it has never heard of", function()
    -- A newer target class than the configuration was written against. The
    -- same fail-open direction `hover.scope` takes for capture families it
    -- does not recognise: show something rather than withhold it silently.
    assert.is_true(config.auto_hover_for("something-invented-later"))
  end)

  it("gates the trigger and not the request", function()
    registry.register("probe", {
      positions = {
        function()
          return { lines = { "probe" } }
        end,
      },
    })
    config.setup({ auto_hover = { "image" } })
    assert.is_false(hover.show(), "a position preview opened without being asked for")
    assert.is_true(hover.show({ force = true }), "an explicit request was refused by a volume gate")
  end)

  it("gates a target by its type, which is the axis it adds", function()
    -- The position gate above sits in `show_position`; this one sits after
    -- `classify`, and they are two different lines of code. Sabotaging one
    -- left the other's assertion green, which is how this second block came
    -- to exist.
    local api = vim.api
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    vim.fn.writefile({ "first line of the target" }, root .. "/target.md")

    local win = api.nvim_get_current_win()
    local prev_buf = api.nvim_win_get_buf(win)
    local prev_isfname = vim.o.isfname
    vim.o.isfname = "@,48-57,/,.,-,_,+,,,#,$,%,~,=,:"
    local buf = api.nvim_create_buf(true, false)
    api.nvim_buf_set_name(buf, root .. "/notes.md")
    api.nvim_win_set_buf(win, buf)
    api.nvim_buf_set_lines(buf, 0, -1, false, { "see ./target.md here" })
    api.nvim_win_set_cursor(win, { 1, 6 })

    config.setup({ auto_hover = { "image", "pdf" } })
    assert.is_false(hover.show(), "a markdown target opened without being asked for")
    assert.is_true(hover.show({ force = true }), "an explicit request was refused")

    hover.hide()
    config.reset()
    config.setup({ auto_hover = { "markdown" } })
    assert.is_true(hover.show(), "the type was listed and still did not open")

    hover.hide()
    vim.o.isfname = prev_isfname
    pcall(api.nvim_win_set_buf, win, prev_buf)
    pcall(api.nvim_buf_delete, buf, { force = true })
    vim.fn.delete(root, "rf")
  end)

  it("toggles one type, and both ends, through set_auto", function()
    assert.is_false(config.auto_hover_for("file"))
    local said = hover.set_auto("file")
    assert.is_true(config.auto_hover_for("file"))
    assert.is_truthy(said and said:find("file", 1, true))

    hover.set_auto("file")
    assert.is_false(config.auto_hover_for("file"), "the second press did not toggle back")

    hover.set_auto("all")
    assert.is_true(config.auto_hover_for("file"))
    assert.is_true(config.auto_hover_for("position"))

    hover.set_auto("none")
    assert.is_false(config.auto_hover_for("image"))
  end)

  it("reports without changing anything when asked for nothing", function()
    local before = config.auto_hover()
    local said = hover.set_auto(nil)
    assert.is_truthy(said and said:find("image", 1, true))
    assert.same(before, config.auto_hover())
  end)

  it("refuses a name that is not a type, and says which are", function()
    local said, err = hover.set_auto("nonsense")
    assert.is_nil(said)
    assert.is_truthy(err and err:find("nonsense", 1, true))
    assert.is_truthy(err and err:find("image", 1, true), "the error does not name the valid set")
  end)

  -- **The bug this axis introduced, and the one nothing on screen could
  -- explain.** `:Hover links web on` announced "web links hover" and then
  -- nothing hovered: `auto_hover.url` is false, a second gate the switch knew
  -- nothing about. Both halves were true, which is why it took a day to find
  -- and why the announcement is the place to fix it -- the reader is looking
  -- at exactly one line at that moment, and it was the wrong one.
  it("says so when a switch it turns on still will not open by itself", function()
    local report = switches.on_report("web")
    assert.is_truthy(report:find("web links hover", 1, true), "the switch's own message is gone")
    assert.is_truthy(report:find("Hover auto url", 1, true), "the second gate was not named")
  end)

  it("says nothing about the second gate once that gate is open", function()
    config.setup({ auto_hover = { url = true } })
    local report = switches.on_report("web")
    assert.is_nil(report:find("Hover auto", 1, true), "the gate is open and was still named")
  end)

  -- The sixth hand-kept copy in this repository, held against its source the
  -- moment it was written rather than after it fell behind. A switch whose
  -- `auto_type` names a type that does not exist would report a gate nobody
  -- can open and complete to nothing.
  it("declares an auto_hover name that exists, wherever a switch declares one", function()
    local names = {}
    for _, name in ipairs(auto_types()) do
      names[name] = true
    end
    local bad, declared = {}, 0
    for _, s in ipairs(switches.status()) do
      if s.auto_type then
        declared = declared + 1
        if not names[s.auto_type] then
          bad[#bad + 1] = ("%s declares auto_type %q"):format(s.name, s.auto_type)
        end
      end
    end
    assert.same({}, bad)
    assert.is_true(declared > 0, "no switch declares the second gate any more")
  end)
end)

describe("border styles", function()
  local hover = require("hover")
  local float = require("hover.float")

  before_each(function()
    config.reset()
  end)

  after_each(function()
    hover.hide()
    config.reset()
  end)

  it("passes Neovim's own names through untouched", function()
    -- The names `nvim_open_win` already knows must not be copied into a table
    -- here: a copy of something the API answers is exactly the shape that has
    -- gone stale five times in this repository.
    for _, name in ipairs({ "none", "single", "double", "rounded", "solid", "shadow" }) do
      assert.equals(name, float.resolve_border(name))
    end
  end)

  it("turns its own names into eight characters, clockwise from the top-left", function()
    for _, name in ipairs({ "heavy", "ascii", "dashed", "block" }) do
      local chars = float.resolve_border(name)
      if type(chars) ~= "table" then
        error(name .. " did not resolve to a character list")
      end
      -- Eight, always: `nvim_open_win` reads the list positionally, and a
      -- shorter one is not an error -- it repeats, and the frame comes out
      -- with corners in the wrong places.
      assert.equals(8, #chars, name .. " has the wrong number of characters")
      for i, ch in ipairs(chars) do
        assert.equals("string", type(ch), ("%s[%d] is not a string"):format(name, i))
        assert.is_true(#ch > 0, ("%s[%d] is empty"):format(name, i))
      end
    end
  end)

  it("leaves a hand-written list alone, which is the escape hatch", function()
    local custom = { "1", "2", "3", "4", "5", "6", "7", "8" }
    -- Bound and narrowed before the comparison: the return type is a union,
    -- and `assert.same` takes tables -- handing it the union directly is a
    -- `param-type-mismatch` that a green suite says nothing about, and the
    -- LuaLS scan does.
    local resolved = float.resolve_border(custom)
    if type(resolved) ~= "table" then
      error("a hand-written list did not come back as a list")
    end
    assert.same(custom, resolved)
  end)

  it("falls back to the documented default when nothing is set", function()
    assert.equals("rounded", float.resolve_border(nil))
  end)

  it("offers every name it accepts, and accepts every name it offers", function()
    local names = float.border_names()
    assert.is_true(#names >= 10)
    for _, name in ipairs(names) do
      local report, err = hover.set_border(name)
      assert.is_nil(err, ("border_names() offers %q and set_border refused it"):format(name))
      assert.is_truthy(report)
      assert.equals(name, config.get().border)
    end
  end)

  it("keeps working when setup is handed a typo", function()
    -- The failure this prevents is total and silent: `nvim_open_win` refuses
    -- an unknown border string, `float.open` calls it inside a `pcall`, and
    -- the plugin then never opens a float again without saying why. Measured
    -- 2026-09-03 -- `border = "heavey"` survived the merge and
    -- `nvim_open_win` returned false.
    config.setup({ border = "heavey" })
    assert.equals(
      "rounded",
      config.get().border,
      "a border name that does not exist was kept, and every hover would be gone"
    )
  end)

  it("takes every name it offers through setup, which is where a user writes it", function()
    for _, name in ipairs(float.border_names()) do
      config.reset()
      config.setup({ border = name })
      assert.equals(name, config.get().border, ("setup() dropped %q"):format(name))
    end
  end)

  it("leaves a hand-written list alone in setup, since a name list cannot judge it", function()
    local custom = { "1", "2", "3", "4", "5", "6", "7", "8" }
    config.setup({ border = custom })
    assert.same(custom, config.get().border)
  end)

  it("refuses a name that is not a style, and says which are", function()
    local report, err = hover.set_border("fancy")
    assert.is_nil(report)
    assert.is_truthy(err and err:find("fancy", 1, true))
    assert.is_truthy(err and err:find("heavy", 1, true), "the error does not name the valid set")
  end)

  it("reports without changing anything when asked for nothing", function()
    config.setup({ border = "double" })
    local report = hover.set_border(nil)
    assert.is_truthy(report and report:find("double", 1, true))
    assert.is_truthy(
      report and report:find("heavy", 1, true),
      "the report does not list the styles"
    )
    assert.equals("double", config.get().border)
  end)
end)
