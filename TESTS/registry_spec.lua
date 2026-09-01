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
