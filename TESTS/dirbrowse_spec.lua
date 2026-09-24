---@diagnostic disable: need-check-nil
-- The test body is the guard; see the note in TESTS/bare_path_spec.lua
-- (`LLS-42`).

-- TESTS/dirbrowse_spec.lua -- the directory hover's mini filetree, as data.
--
-- `hover.preview.dirbrowse` is deliberately the one module in this feature
-- with no window, no keymap and no selection in it -- see its own header for
-- why. That is also what makes it cheap to pin down here: scan, render and
-- clamp are pure functions over a temp directory and a plain list, with none
-- of `hover.init`'s float state to fake.

local dirbrowse = require("hover.preview.dirbrowse")

describe("hover.preview.dirbrowse.scan", function()
  local root

  before_each(function()
    root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
  end)

  after_each(function()
    vim.fn.delete(root, "rf")
  end)

  it("lists directories before files, both alphabetical", function()
    vim.fn.writefile({}, root .. "/b.txt")
    vim.fn.writefile({}, root .. "/a.txt")
    vim.fn.mkdir(root .. "/zeta", "p")
    vim.fn.mkdir(root .. "/alpha", "p")

    local entries = dirbrowse.scan(root)
    local names = {}
    for i, e in ipairs(entries) do
      names[i] = e.name
    end
    assert.same({ "alpha", "zeta", "a.txt", "b.txt" }, names)
  end)

  it("marks a directory entry as such, and a file as not", function()
    vim.fn.mkdir(root .. "/child", "p")
    vim.fn.writefile({}, root .. "/leaf.txt")

    local entries = dirbrowse.scan(root)
    local by_name = {}
    for _, e in ipairs(entries) do
      by_name[e.name] = e
    end
    assert.is_true(by_name["child"].is_dir)
    assert.is_false(by_name["leaf.txt"].is_dir)
  end)

  it("joins the entry's own path onto the scanned directory", function()
    vim.fn.writefile({}, root .. "/leaf.txt")
    local entries = dirbrowse.scan(root)
    assert.equals(vim.fs.joinpath(root, "leaf.txt"), entries[1].path)
  end)

  it("answers nil for a directory it cannot read", function()
    assert.is_nil(dirbrowse.scan(root .. "/does-not-exist"))
  end)

  it("answers an empty list for a directory with nothing in it", function()
    assert.same({}, dirbrowse.scan(root))
  end)
end)

describe("hover.preview.dirbrowse.render", function()
  it("suffixes a directory with a slash, and leaves a file bare", function()
    local lines = dirbrowse.render({
      { name = "src", path = "/x/src", is_dir = true },
      { name = "README.md", path = "/x/README.md", is_dir = false },
    })
    assert.same({ "src/", "README.md" }, lines)
  end)

  it("keeps the caller's order rather than re-sorting", function()
    -- `scan` already sorted; `render` must not have an opinion of its own, or
    -- a caller handing over a deliberately reordered slice (a truncation, a
    -- future filter) would be silently undone.
    local lines = dirbrowse.render({
      { name = "z", path = "/x/z", is_dir = false },
      { name = "a", path = "/x/a", is_dir = false },
    })
    assert.same({ "z", "a" }, lines)
  end)

  it("renders nothing for nothing", function()
    assert.same({}, dirbrowse.render({}))
  end)
end)

describe("hover.preview.dirbrowse.clamp", function()
  it("answers nil when there is nothing to select", function()
    assert.is_nil(dirbrowse.clamp(1, 0))
    assert.is_nil(dirbrowse.clamp(nil, 0))
  end)

  it("floors at 1, and a nil index reads as the first entry", function()
    assert.equals(1, dirbrowse.clamp(0, 5))
    assert.equals(1, dirbrowse.clamp(-3, 5))
    assert.equals(1, dirbrowse.clamp(nil, 5))
  end)

  it("ceils at the count, for an index that has walked past the end", function()
    assert.equals(5, dirbrowse.clamp(9, 5))
  end)

  it("leaves an index already inside the range alone", function()
    assert.equals(3, dirbrowse.clamp(3, 5))
  end)
end)
