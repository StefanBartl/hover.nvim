---@diagnostic disable: need-check-nil
-- The test body is the guard; see the note in TESTS/bare_path_spec.lua
-- (`LLS-42`).

-- TESTS/registry_spec.lua -- the provider registry, and the degradation
-- guarantees that depend on it.
--
-- The registry is what let this framework leave markdown.nvim: it is the
-- only channel through which plugin-specific knowledge reaches a plugin that
-- must work with none of those plugins installed. So most of what is
-- asserted here is the *absence* of coupling -- that nothing crashes, and
-- nothing is attached, when a contributor is missing.
--
-- The attach cases matter for a second reason: hover.nvim installs an
-- autocmd in every ordinary buffer, so "could this ever answer" has to be
-- decided before the autocmd exists, not inside it.

local registry = require("hover.registry")
local config = require("hover.config")
local autocmds = require("hover.bindings.autocmds")

describe("hover.registry", function()
  before_each(function()
    registry.reset()
    config.reset()
    vim.g.hover_disable = nil
  end)

  after_each(function()
    registry.reset()
    config.reset()
    vim.g.hover_disable = nil
  end)

  describe("with nothing registered", function()
    it("stands on its own", function()
      assert.is_false(registry.has_sources())
      assert.is_nil(registry.source_at(0, 1, 0))
      assert.is_nil(registry.preview_for("image"))
    end)
  end)

  describe("a registered source", function()
    before_each(function()
      registry.register("fake.nvim", {
        sources = {
          function(_, row, col)
            if row == 1 and col == 3 then
              return "target.png", { kind = "fake", col = 3, col_end = 9 }
            end
            return nil
          end,
        },
        previews = {
          image = function()
            return { lines = { "claimed" } }
          end,
        },
      })
    end)

    it("is visible and answers with its extra fields intact", function()
      assert.is_true(registry.has_sources())
      local target, extra = registry.source_at(0, 1, 3)
      assert.equals("target.png", target)
      assert.equals("fake", extra.kind)
    end)

    it("yields nil at a position it declines", function()
      assert.is_nil(registry.source_at(0, 2, 0))
    end)

    it("claims only the preview types it named", function()
      assert.is_not_nil(registry.preview_for("image"))
      assert.is_nil(registry.preview_for("pdf"))
    end)
  end)

  it("replaces a contribution on re-registration rather than stacking it", function()
    -- A `setup()` running twice (a reload, `:Lazy reload`) must not make
    -- every source fire twice -- for a source with side effects that is a
    -- real bug, and for the ordering guarantee it is one regardless.
    local calls = 0
    for _ = 1, 3 do
      registry.register("fake.nvim", {
        sources = {
          function()
            calls = calls + 1
            return nil
          end,
        },
      })
    end
    registry.source_at(0, 1, 0)
    assert.equals(1, calls)
  end)

  it("skips a source that throws and still runs the next one", function()
    registry.register("broken.nvim", {
      sources = {
        function()
          error("this plugin is having a bad day")
        end,
      },
    })
    registry.register("good.nvim", {
      sources = {
        function()
          return "still-works.md"
        end,
      },
    })
    assert.equals("still-works.md", registry.source_at(0, 1, 0))
  end)
end)

describe("attaching", function()
  local buf, scratch

  ---@param b integer
  ---@return integer
  local function hover_autocmds(b)
    local n = 0
    for _, a in ipairs(vim.api.nvim_get_autocmds({ event = "CursorHold", buffer = b })) do
      if (a.desc or ""):match("hover%.nvim") then
        n = n + 1
      end
    end
    return n
  end

  before_each(function()
    registry.reset()
    config.reset()
    vim.g.hover_disable = nil
    buf = vim.api.nvim_create_buf(false, false) -- a real (buftype "") buffer
    scratch = vim.api.nvim_create_buf(false, true) -- buftype = "nofile"
  end)

  after_each(function()
    autocmds.detach_all()
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    pcall(vim.api.nvim_buf_delete, scratch, { force = true })
    registry.reset()
    config.reset()
  end)

  it("installs nothing when nothing could ever answer", function()
    -- hover.nvim can be installed with none of its contributors, so a user
    -- must not pay for an autocmd that wakes on every CursorHold to find it
    -- has nothing to say.
    config.setup({ paths = { enabled = false } })
    autocmds.attach(buf)
    assert.equals(0, hover_autocmds(buf))
  end)

  it("attaches for bare paths alone, which need no plugin at all", function()
    config.setup({ paths = { enabled = true } })
    autocmds.attach(buf)
    assert.is_true(hover_autocmds(buf) > 0)
  end)

  it("attaches for a registered source even with bare paths off", function()
    config.setup({ paths = { enabled = false } })
    registry.register("fake.nvim", {
      sources = {
        function()
          return nil
        end,
      },
    })
    autocmds.attach(buf)
    assert.is_true(hover_autocmds(buf) > 0)
  end)

  it("never attaches to a non-file buffer", function()
    -- A picker, a file tree, a terminal or a dashboard has no document to
    -- hover in, and a float opening over one is always wrong. A non-empty
    -- 'buftype' catches all of them in one check.
    autocmds.attach(scratch)
    assert.equals(0, hover_autocmds(scratch))
  end)

  it("installs no trigger in manual mode, but still hides on leaving", function()
    config.setup({ mode = "manual" })
    autocmds.attach(buf)
    assert.equals(0, hover_autocmds(buf))

    local hides = 0
    for _, a in ipairs(vim.api.nvim_get_autocmds({ event = "BufLeave", buffer = buf })) do
      if (a.desc or ""):match("hover%.nvim") then
        hides = hides + 1
      end
    end
    assert.is_true(hides > 0)
  end)

  it("installs nothing at all when the hover is off", function()
    config.setup({ mode = "off" })
    autocmds.attach(buf)
    assert.equals(0, hover_autocmds(buf))
  end)

  it("uses CursorMoved and not CursorHold under the cursor trigger", function()
    -- The point of the "cursor" trigger is not inheriting 'updatetime',
    -- which is a global usually set for something else entirely.
    config.setup({ trigger = { "cursor" } })
    autocmds.attach(buf)
    assert.equals(0, hover_autocmds(buf))

    local moved = 0
    for _, a in ipairs(vim.api.nvim_get_autocmds({ event = "CursorMoved", buffer = buf })) do
      if (a.desc or ""):match("hover%.nvim") then
        moved = moved + 1
      end
    end
    assert.is_true(moved > 0)
  end)
end)

describe("the framework with no providers at all", function()
  it("classifies and previews a plain file", function()
    -- classify and the text previews must not reach for images.nvim,
    -- pdfport or markdown.nvim to answer.
    registry.reset()
    local tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
    vim.fn.writefile({ "alpha", "beta" }, tmp .. "/plain.txt")

    local t = require("hover.classify").classify("plain.txt", tmp .. "/doc.md")
    assert.equals("file", t.type)

    local content = require("hover.preview.text").file(t, { max_lines = 10 })
    assert.equals("alpha", content.lines[1])

    vim.fn.delete(tmp, "rf")
  end)
end)

describe("text preview scrolling", function()
  local tmp, doc

  before_each(function()
    tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
    local rows = {}
    for i = 1, 60 do
      rows[i] = "line " .. i
    end
    vim.fn.writefile(rows, tmp .. "/long.txt")
    doc = { type = "file", raw = "long.txt", path = tmp .. "/long.txt" }
  end)

  after_each(function()
    vim.fn.delete(tmp, "rf")
  end)

  it("starts at the top and reports more to come", function()
    local first = require("hover.preview.text").file(doc, { max_lines = 10 })
    assert.equals("line 1", first.lines[1])
    assert.is_true(first.scroll.more)
    assert.equals(0, first.scroll.offset)
  end)

  it("skips exactly the requested number of lines", function()
    local second = require("hover.preview.text").file(doc, { max_lines = 10, offset = 10 })
    assert.equals("line 11", second.lines[1])
    assert.is_truthy(second.title:match("10"))
  end)

  it("reaches the last line and then reports nothing follows", function()
    local last = require("hover.preview.text").file(doc, { max_lines = 10, offset = 55 })
    assert.equals("line 60", last.lines[#last.lines])
    assert.is_false(last.scroll.more)
  end)

  it("falls back rather than showing an empty float when overshooting", function()
    local past = require("hover.preview.text").file(doc, { max_lines = 10, offset = 999 })
    assert.is_true(#past.lines > 0)
    assert.is_true(past.scroll.offset < 999)
  end)

  it("reports a file that fits as not scrollable, so no keys are bound", function()
    vim.fn.writefile({ "a", "b" }, tmp .. "/short.txt")
    local fits = require("hover.preview.text").file(
      { type = "file", raw = "short.txt", path = tmp .. "/short.txt" },
      { max_lines = 10 }
    )
    assert.is_false(fits.scroll.more)
  end)
end)

-- A *position* preview answers for a cursor position that points at nothing:
-- a deprecated call on this line, how often this token occurs, what this
-- module is. It is the one contribution kind that hands back finished content
-- instead of a target string, because there is nothing to classify -- and
-- four plugins in this ecosystem were waiting on it (see docs/ROADMAP.md).
--
-- Three properties are worth pinning, and each of them is a way the kind
-- could be built wrong:
--
--   1. **Sources win.** A position preview must be asked only after every
--      source declined, or a plugin that answers for any line would shadow
--      every link and path in the buffer.
--   2. **A throwing contribution is skipped, not fatal.** Same guarantee
--      `source_at` gives, for the same reason.
--   3. **Content, not a target.** Anything that is not a table with a
--      non-empty `lines` list is a decline, so a plugin returning `true` or
--      an empty table cannot open a blank float.
describe("hover.registry position previews", function()
  before_each(function()
    registry.reset()
  end)

  after_each(function()
    registry.reset()
  end)

  it("has none until one is registered", function()
    assert.is_false(registry.has_positions())
    registry.register("p", { positions = { function() end } })
    assert.is_true(registry.has_positions())
  end)

  it("answers with the content the plugin produced", function()
    registry.register("p", {
      positions = {
        function()
          return { lines = { "deprecated: vim.loop" }, title = "migrate" }
        end,
      },
    })
    local content, name = registry.position_at(0, 1, 0)
    assert.same({ "deprecated: vim.loop" }, content.lines)
    assert.equals("migrate", content.title)
    assert.equals("p", name)
  end)

  it("takes the first that answers, in registration order", function()
    registry.register("first", {
      positions = {
        function()
          return nil
        end,
        function()
          return { lines = { "second fn of first plugin" } }
        end,
      },
    })
    registry.register("later", {
      positions = {
        function()
          return { lines = { "later plugin" } }
        end,
      },
    })
    local content, name = registry.position_at(0, 1, 0)
    assert.same({ "second fn of first plugin" }, content.lines)
    assert.equals("first", name)
  end)

  it("skips one that throws and keeps asking", function()
    registry.register("broken", {
      positions = {
        function()
          error("this contribution is broken")
        end,
      },
    })
    registry.register("fine", {
      positions = {
        function()
          return { lines = { "still here" } }
        end,
      },
    })
    local content = registry.position_at(0, 1, 0)
    assert.same({ "still here" }, content.lines)
  end)

  it("declines anything that is not content with lines", function()
    for _, answer in ipairs({ true, "a string", {}, { lines = {} }, { lines = "no" } }) do
      registry.reset()
      registry.register("p", {
        positions = {
          -- The wrong types are the point of the test: the registry
          -- promising to decline them is what is under test, so the
          -- suppression is the honest answer rather than a workaround
          -- (`LLS-40`).
          function()
            ---@diagnostic disable-next-line: return-type-mismatch
            return answer
          end,
        },
      })
      assert.is_nil(registry.position_at(0, 1, 0))
    end
  end)

  it("replaces a plugin's positions on re-registration, rather than stacking", function()
    local calls = 0
    local function counting()
      calls = calls + 1
      return nil
    end
    registry.register("p", { positions = { counting } })
    registry.register("p", { positions = { counting } })
    registry.position_at(0, 1, 0)
    assert.equals(1, calls)
  end)

  it("leaves another plugin's positions alone when one re-registers", function()
    registry.register("a", {
      positions = {
        function()
          return nil
        end,
      },
    })
    registry.register("b", {
      positions = {
        function()
          return { lines = { "b" } }
        end,
      },
    })
    registry.register("a", {
      positions = {
        function()
          return nil
        end,
      },
    })
    local content, name = registry.position_at(0, 1, 0)
    assert.same({ "b" }, content.lines)
    assert.equals("b", name)
  end)

  it("is cleared by reset along with everything else", function()
    registry.register("p", {
      positions = {
        function()
          return { lines = { "x" } }
        end,
      },
    })
    registry.reset()
    assert.is_false(registry.has_positions())
    assert.is_nil(registry.position_at(0, 1, 0))
  end)
end)

-- The wiring, not the registry: does a position preview actually reach the
-- screen, does a target still beat it, does the switch stop it, and does the
-- trigger get installed for a buffer where it is the only thing that could
-- answer. The last one is the silent failure this kind invites -- the class
-- works, and nothing ever calls it.
describe("a position preview, end to end", function()
  local hover = require("hover")
  local float = require("hover.float")
  local api = vim.api
  local win, prev_buf, buf

  --- A contribution that answers for every position with `text`.
  ---@param text string
  local function always(text)
    registry.register("stub", {
      positions = {
        function()
          return { lines = { text }, title = "stub" }
        end,
      },
    })
  end

  before_each(function()
    registry.reset()
    config.reset()
    win = api.nvim_get_current_win()
    prev_buf = api.nvim_win_get_buf(win)
    buf = api.nvim_create_buf(false, true)
    api.nvim_win_set_buf(win, buf)
    api.nvim_buf_set_lines(buf, 0, -1, false, { "ordinary prose with no target" })
    api.nvim_win_set_cursor(win, { 1, 3 })
  end)

  after_each(function()
    hover.hide()
    pcall(api.nvim_win_set_buf, win, prev_buf)
    pcall(api.nvim_buf_delete, buf, { force = true })
    registry.reset()
    config.reset()
  end)

  it("opens a float where nothing is a target", function()
    always("something about this line")
    assert.is_true(hover.show())
    assert.is_true(float.is_open())
  end)

  it("does not open when nothing is registered", function()
    assert.is_false(hover.show())
    assert.is_false(float.is_open())
  end)

  it("is silenced by its switch", function()
    always("something about this line")
    config.setup({ positions = false })
    assert.is_false(hover.show())
    assert.is_false(float.is_open())
  end)

  it("answers anyway when the request is explicit", function()
    -- `:Hover show` opens every volume gate, and this is one of them.
    always("something about this line")
    config.setup({ positions = false })
    assert.is_true(hover.show({ force = true }))
  end)

  it("loses to a source, which is the more specific reading", function()
    always("the position preview")
    registry.register("src", {
      sources = {
        function()
          return "./somewhere.md"
        end,
      },
    })
    hover.show()
    -- A float *does* open: the path does not exist, and a target a source
    -- vouched for being missing is worth reporting. What matters is whose
    -- content is in it.
    assert.is_true(float.is_open())
    local win_id = float.win()
    if not win_id then
      error("the float reports open but has no window")
    end
    local lines = api.nvim_buf_get_lines(api.nvim_win_get_buf(win_id), 0, -1, false)
    assert.is_nil(
      vim.iter(lines):find(function(l)
        return l:find("the position preview", 1, true) ~= nil
      end),
      "the position preview must not shadow a source"
    )
  end)

  it("stays away once dismissed, until the cursor leaves the line", function()
    always("something about this line")
    assert.is_true(hover.show())
    assert.is_true(hover.dismiss())
    assert.is_false(hover.show())

    api.nvim_buf_set_lines(buf, 0, -1, false, { "line one", "line two" })
    api.nvim_win_set_cursor(win, { 2, 3 })
    assert.is_true(hover.show())
  end)

  it("counts as something that could answer, so the trigger is installed", function()
    -- Without this the class would be registered, switched on, and never
    -- called: `paths.enabled = false` and no source means no CursorHold.
    config.setup({ paths = { enabled = false } })
    assert.is_false(autocmds.anything_to_show())
    always("something")
    assert.is_true(autocmds.anything_to_show())
    config.setup({ positions = false })
    assert.is_false(autocmds.anything_to_show())
  end)
end)

-- Pinning. What it does is take one float out of the cursor's hands; what it
-- deliberately does not do is open a second one, which would be a lifecycle
-- rather than a flag -- `_open`, the generation counter and the async guard
-- are each written for one window.
--
-- The consequence is the thing worth pinning down: while a float is pinned,
-- the automatic trigger opens nothing. That is a real cost and it should fail
-- loudly if someone "fixes" it.
describe("a pinned hover", function()
  local hover = require("hover")
  local float = require("hover.float")
  local api = vim.api
  local win, prev_buf, buf

  local function always(text)
    registry.register("stub", {
      positions = {
        function()
          return { lines = { text }, title = "stub" }
        end,
      },
    })
  end

  before_each(function()
    registry.reset()
    config.reset()
    vim.g.hover_disable = nil
    win = api.nvim_get_current_win()
    prev_buf = api.nvim_win_get_buf(win)
    buf = api.nvim_create_buf(true, false)
    api.nvim_win_set_buf(win, buf)
    api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "two" })
    api.nvim_win_set_cursor(win, { 1, 1 })
  end)

  after_each(function()
    hover.hide()
    pcall(api.nvim_win_set_buf, win, prev_buf)
    pcall(api.nvim_buf_delete, buf, { force = true })
    registry.reset()
    config.reset()
    vim.g.hover_disable = nil
  end)

  it("does nothing when no hover is open", function()
    assert.is_false(hover.pin())
    assert.is_false(hover.pinned())
  end)

  it("toggles, and reports its state", function()
    always("first")
    assert.is_true(hover.show())
    assert.is_true(hover.pin())
    assert.is_true(hover.pinned())
    assert.is_false(hover.pin())
    assert.is_false(hover.pinned())
  end)

  it("survives the trigger, which opens nothing while it is up", function()
    always("first")
    hover.show()
    hover.pin()
    api.nvim_win_set_cursor(win, { 2, 1 })
    -- The trigger's own call. It must neither replace the float nor close it.
    assert.is_false(hover.show())
    assert.is_true(float.is_open())
    assert.is_true(hover.pinned())
  end)

  it("is replaced by an explicit request, which is unambiguous", function()
    always("first")
    hover.show()
    hover.pin()
    assert.is_true(hover.show({ force = true }))
    assert.is_true(float.is_open())
  end)

  it("survives leaving the buffer and entering insert", function()
    -- The two events someone pinned a float *for*.
    always("first")
    hover.show()
    hover.pin()
    hover.hide_unless_pinned()
    assert.is_true(float.is_open())
  end)

  it("is closed by those events once released", function()
    always("first")
    hover.show()
    hover.hide_unless_pinned()
    assert.is_false(float.is_open())
  end)

  it("does not outlive its window: hide clears the pin", function()
    always("first")
    hover.show()
    hover.pin()
    hover.hide()
    assert.is_false(hover.pinned())
    assert.is_false(float.is_open())
  end)

  it("is taken away by a dismissal like any other float", function()
    always("first")
    hover.show()
    hover.pin()
    assert.is_true(hover.dismiss())
    assert.is_false(float.is_open())
    assert.is_false(hover.pinned())
  end)
end)

-- Opening what the float is showing. A preview that shows a target and cannot
-- open it is half an answer, and `gf` is what that key already means in
-- Neovim -- while a float is up, "open what is under the cursor" and "open
-- what this float shows" are the same thing.
--
-- Two things are pinned here that are easy to get wrong in opposite
-- directions: it must *route* rather than open directly (open.nvim knows a
-- URL wants a browser and a path wants a file manager, and this must not
-- re-decide that), and it must decline for the targets that have nothing to
-- open rather than guessing.
describe("opening what the hover shows", function()
  local hover = require("hover")
  local float = require("hover.float")
  local api = vim.api
  local root, win, prev_buf, prev_isfname, buf, calls, real_open

  before_each(function()
    registry.reset()
    config.reset()
    vim.g.hover_disable = nil

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

    calls = {}
    real_open = package.loaded["open"]
    package.loaded["open"] = {
      open = function(target, scope)
        calls[#calls + 1] = { target = target, scope = scope }
      end,
    }
  end)

  after_each(function()
    package.loaded["open"] = real_open
    hover.hide()
    pcall(api.nvim_win_set_buf, win, prev_buf)
    pcall(api.nvim_buf_delete, buf, { force = true })
    vim.o.isfname = prev_isfname
    vim.fn.delete(root, "rf")
    registry.reset()
    config.reset()
    vim.g.hover_disable = nil
  end)

  ---@param line string
  ---@param marker string
  local function hover_on(line, marker)
    api.nvim_buf_set_lines(buf, 0, -1, false, { line })
    local at = line:find(marker, 1, true)
    api.nvim_win_set_cursor(win, { 1, at - 1 })
    return hover.show({ force = true })
  end

  it("does nothing when no hover is open", function()
    assert.is_false(hover.open())
  end)

  it("routes a path through open.nvim as a path scope", function()
    assert.is_true(hover_on("see ./real.md ok", "./real"))
    assert.is_true(hover.open())
    assert.equals(1, #calls)
    -- `nil` handler: open.nvim picks by context. `path=` so a filename that
    -- spells one of its scope keywords is still read as a path.
    assert.is_nil(calls[1].target)
    assert.is_truthy(calls[1].scope:find("^path="))
    assert.is_truthy(calls[1].scope:find("real.md", 1, true))
  end)

  it("routes a URL as itself, not as a path", function()
    config.setup({ links = { web = true } })
    assert.is_true(hover_on("see https://example.com/x ok", "https://"))
    assert.is_true(hover.open())
    assert.equals(1, #calls)
    assert.is_nil(calls[1].scope:find("^path="), "a URL must not be wrapped in path=")
    assert.is_truthy(calls[1].scope:find("example.com", 1, true))
  end)

  it("closes the float once it has handed the target over", function()
    hover_on("see ./real.md ok", "./real")
    hover.open()
    assert.is_false(float.is_open())
  end)

  it("declines a target that does not exist", function()
    -- `missing` has nothing to open, and an opener asked to open nothing
    -- reports an error the reader did not cause.
    assert.is_true(hover_on("see ./gone.md ok", "./gone"))
    assert.is_false(hover.open())
    assert.equals(0, #calls)
  end)

  it("declines a position preview, which is about a place and not a thing", function()
    registry.register("p", {
      positions = {
        function()
          return { lines = { "something about this line" } }
        end,
      },
    })
    api.nvim_buf_set_lines(buf, 0, -1, false, { "ordinary prose here" })
    api.nvim_win_set_cursor(win, { 1, 2 })
    assert.is_true(hover.show())
    assert.is_false(hover.open())
    assert.equals(0, #calls)
  end)

  it("falls back to vim.ui.open when open.nvim is not installed", function()
    package.loaded["open"] = nil
    local preload = package.preload["open"]
    package.preload["open"] = function()
      error("module 'open' not found")
    end
    local seen
    local real_ui = vim.ui.open
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.ui.open = function(what)
      seen = what
    end

    hover_on("see ./real.md ok", "./real")
    local opened = hover.open()

    vim.ui.open = real_ui
    package.preload["open"] = preload

    assert.is_true(opened)
    assert.is_truthy(seen and seen:find("real.md", 1, true))
  end)
end)

-- `on_request`: a contribution saying its own answer is expensive.
--
-- The knowledge this exists to carry is knowledge only the contributor has.
-- Measured, the population that needs it: a git start costs ~41 ms, a
-- `docker --version` 230 ms, `podman --version` 490 ms -- the same whether
-- they hit or miss. A trigger that fires after every keystroke followed by
-- quiet cannot pay that, and the only lever before this was
-- `:Hover positions off`, which silences every registered plugin at once.
--
-- Three properties, and the third is the one that would fail silently:
--
--   1. **It is skipped on the automatic trigger** and asked on an explicit
--      one. That is the whole feature.
--   2. **A bare function still means "every trigger"**, so nothing that
--      registered before this existed changes behaviour.
--   3. **It does not count as "something that could answer"** for the
--      trigger's own installation check. A buffer whose only contribution is
--      force-only must not get a CursorHold installed for it -- the trigger
--      would wake, ask nobody, and go back to sleep, forever.
describe("a contribution that answers only on request", function()
  before_each(function()
    registry.reset()
    config.reset()
  end)

  after_each(function()
    registry.reset()
    config.reset()
  end)

  it("accepts a bare function and a table entry side by side", function()
    local asked = { bare = 0, gated = 0 }
    registry.register("p", {
      sources = {
        {
          fn = function()
            asked.gated = asked.gated + 1
            return nil
          end,
          on_request = true,
        },
        function()
          asked.bare = asked.bare + 1
          return nil
        end,
      },
    })

    registry.source_at(0, 1, 0)
    assert.equals(1, asked.bare, "a bare function is asked on the trigger")
    assert.equals(0, asked.gated, "a force-only one is not")

    registry.source_at(0, 1, 0, { force = true })
    assert.equals(2, asked.bare, "and both are asked on request")
    assert.equals(1, asked.gated)
  end)

  it("gates a position preview the same way", function()
    local asked = 0
    registry.register("p", {
      positions = {
        {
          fn = function()
            asked = asked + 1
            return { lines = { "expensive" } }
          end,
          on_request = true,
        },
      },
    })

    assert.is_nil(registry.position_at(0, 1, 0))
    assert.equals(0, asked)

    local content = registry.position_at(0, 1, 0, { force = true })
    assert.same({ "expensive" }, content.lines)
    assert.equals(1, asked)
  end)

  it("keeps registration order across both shapes", function()
    registry.register("p", {
      sources = {
        {
          fn = function()
            return "first, force-only"
          end,
          on_request = true,
        },
        function()
          return "second, always"
        end,
      },
    })
    assert.equals("second, always", registry.source_at(0, 1, 0))
    assert.equals("first, force-only", registry.source_at(0, 1, 0, { force = true }))
  end)

  it("does not count as something that could answer", function()
    -- Otherwise the trigger is installed for a buffer where nothing can ever
    -- answer it: it wakes, asks nobody, and sleeps again, forever.
    config.setup({ paths = { enabled = false } })
    registry.register("p", {
      sources = { { fn = function() end, on_request = true } },
      positions = { { fn = function() end, on_request = true } },
    })
    assert.is_false(registry.has_sources())
    assert.is_false(registry.has_positions())
    assert.is_false(autocmds.anything_to_show())

    registry.register("q", { sources = { function() end } })
    assert.is_true(registry.has_sources())
    assert.is_true(autocmds.anything_to_show())
  end)

  it("ignores a malformed entry rather than failing", function()
    registry.register("p", {
      -- Every one of these is deliberately wrong: the registry promising to
      -- skip them is what is under test (`LLS-40`).
      ---@diagnostic disable-next-line: missing-fields, assign-type-mismatch
      sources = { 42, {}, { fn = "not a function" }, { on_request = true } },
    })
    assert.is_false(registry.has_sources())
    assert.is_nil(registry.source_at(0, 1, 0, { force = true }))
  end)
end)
