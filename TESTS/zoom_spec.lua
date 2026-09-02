---@diagnostic disable: need-check-nil
-- The test body is the guard; see the note in TESTS/bare_path_spec.lua
-- (`LLS-42`).

-- TESTS/zoom_spec.lua -- magnifying a *detail*, which is the operation
-- `resize` is not.
--
-- **The distinction this file exists to hold.** `resize` changes the box and
-- letterboxes the whole picture into it: the framing never changes, and it
-- costs no process. A zoom keeps the box and cuts the source, so what is on
-- screen is a smaller part of the picture, larger. Only the second is
-- magnification, and it needs a file.
--
-- **The measurement that decided the shape**, taken before a line was
-- written (Windows, 2026-09-02): a `magick` start alone is 71 ms, cropping a
-- 1920x1080 screenshot and fitting it 258 ms, a dense image of that size
-- 502 ms, a 4K source ~900 ms. No format or compression setting brought it
-- under ~150 ms, and batching several crops into one process saved only the
-- start. That is a deliberate operation, not a dial -- so the way in is a
-- route, and the only borrowed keys are the ones for panning, which is the
-- part done repeatedly once already in.
--
-- **What is pinned here and what is not.** The arithmetic and the borrow
-- conditions run everywhere; the crop itself needs ImageMagick and is skipped
-- without it, the same stance images.nvim takes in its own `convert_spec`
-- (and the crop is that plugin's own to prove). What no machine here can say
-- is that the *detail* arrived on the terminal -- that is a row in
-- `docs/MANUAL-EVIDENCE.md`.

local config = require("hover.config")
local media = require("hover.preview.media")
local keys = require("hover.bindings.keymaps")
local float = require("hover.float")
local registry = require("hover.registry")
local hover = require("hover")

--- Write a file whose first 32 bytes are a PNG header of the given size.
---@param path string
---@param w integer
---@param h integer
---@return nil
local function fake_png(path, w, h)
  ---@param n integer
  ---@return string
  local function be32(n)
    return string.char(
      math.floor(n / 0x1000000) % 256,
      math.floor(n / 0x10000) % 256,
      math.floor(n / 0x100) % 256,
      n % 256
    )
  end
  local f = assert(io.open(path, "wb"))
  f:write("\137PNG\r\n\26\n" .. be32(13) .. "IHDR" .. be32(w) .. be32(h) .. string.rep("\0", 16))
  f:close()
end

describe("the rectangle a zoom selects", function()
  local px = { width = 1200, height = 800 }

  it("is the whole picture at level zero, which is no rectangle at all", function()
    assert.is_nil(media.zoom_rect(px, 0, 0.5, 0.5))
    assert.is_nil(media.zoom_rect(px, -3, 0.5, 0.5))
  end)

  it("shrinks with the level, and keeps the source's shape", function()
    local one = media.zoom_rect(px, 1, 0.5, 0.5)
    local two = media.zoom_rect(px, 2, 0.5, 0.5)
    assert.is_true(one.w > two.w and one.h > two.h)
    -- Same aspect ratio as the source, which is why zooming never changes the
    -- float's size -- only what is inside it. A spec that watched the float
    -- for a zoom would pass forever.
    assert.is_true(math.abs(one.w / one.h - px.width / px.height) < 0.02)
    assert.is_true(math.abs(two.w / two.h - px.width / px.height) < 0.02)
  end)

  it("centres on the fraction it is given", function()
    local mid = media.zoom_rect(px, 2, 0.5, 0.5)
    local right = media.zoom_rect(px, 2, 0.75, 0.5)
    assert.is_true(right.x > mid.x, "moving the centre right did not move the rectangle")
    assert.equals(mid.y, right.y, "moving it right moved it vertically too")
  end)

  it("stays inside the picture, however far the centre is pushed", function()
    -- A centre near an edge must still yield a full-size view rather than one
    -- hanging off the source -- `magick` would answer a rectangle that starts
    -- outside with a smaller image, or nothing.
    for _, c in ipairs({ { 0, 0 }, { 1, 1 }, { 0, 1 }, { 1, 0 }, { -5, 9 } }) do
      local r = media.zoom_rect(px, 3, c[1], c[2])
      assert.is_true(
        r.x >= 0 and r.y >= 0,
        ("centre %s put the rectangle at %d,%d"):format(vim.inspect(c), r.x, r.y)
      )
      assert.is_true(r.x + r.w <= px.width, "the rectangle runs off the right edge")
      assert.is_true(r.y + r.h <= px.height, "the rectangle runs off the bottom edge")
    end
  end)

  it("never asks for fewer than the floor of source pixels", function()
    local deep = media.zoom_rect(px, 40, 0.5, 0.5)
    assert.is_true(deep.w >= 32 and deep.h >= 32)
  end)
end)

describe("how far in a zoom may go", function()
  it("answers from the source rather than by trying", function()
    -- The opposite of how `resize` finds its ceiling: there only the terminal
    -- knows where the room ends, so a step that changed nothing is stepped
    -- back off. Here the limit is the source's own pixels and is knowable, so
    -- a refused step costs no `magick` run at all.
    local small = { width = 100, height = 100 }
    assert.is_true(media.zoom_possible(small, 1))
    assert.is_false(media.zoom_possible(small, 20))
    assert.is_false(media.zoom_possible(nil, 1), "an unreadable size cannot be zoomed")
  end)

  it("treats level zero as always reachable, since it is the whole picture", function()
    assert.is_true(media.zoom_possible(nil, 0))
  end)
end)

describe("the keys a zoomed hover borrows", function()
  before_each(function()
    config.reset()
    keys.release()
  end)

  after_each(function()
    keys.release()
    for _, lhs in ipairs({ "h", "j", "k", "l" }) do
      pcall(vim.keymap.del, "n", lhs)
    end
    config.reset()
  end)

  ---@param lhs string
  ---@return boolean
  local function mapped(lhs)
    return vim.fn.maparg(lhs, "n") ~= ""
  end

  ---@param content table
  ---@param zoomed boolean
  ---@return nil
  local function borrow(content, zoomed)
    keys.borrow(content, {
      scroll = function() end,
      resize = function() end,
      pan = function() end,
      zoomed = zoomed,
    })
  end

  it("takes hjkl only while the hover is actually zoomed", function()
    borrow({ lines = {}, canvas = { cols = 40, rows = 10 }, image_path = "/x.png" }, false)
    assert.is_false(mapped("h"), "a picture that is not zoomed took the pan keys")
    keys.release()

    borrow({ lines = {}, canvas = { cols = 40, rows = 10 }, image_path = "/x.png" }, true)
    for _, lhs in ipairs({ "h", "j", "k", "l" }) do
      assert.is_true(mapped(lhs), lhs .. " was not borrowed while zoomed")
    end
  end)

  it("gives a motion back rather than deleting it", function()
    -- The reason these are worth borrowing at all: unbound, `h` moves the
    -- cursor, and the dismissal hangs on CursorMoved -- so the keypress takes
    -- the picture away. That is never what it means over a magnified picture.
    vim.keymap.set("n", "h", "<Nop>", { desc = "the user's own h" })
    borrow({ lines = {}, canvas = { cols = 40, rows = 10 } }, true)
    assert.equals("hover: move the magnified view left", vim.fn.maparg("h", "n", false, true).desc)
    keys.release()
    assert.equals("the user's own h", vim.fn.maparg("h", "n", false, true).desc)
  end)

  it("binds nothing when the key list is emptied", function()
    config.setup({ pan_keys = { left = {}, right = {}, up = {}, down = {} } })
    borrow({ lines = {}, canvas = { cols = 40, rows = 10 } }, true)
    assert.is_false(mapped("h"))
    assert.is_false(mapped("l"))
  end)

  it("takes none when no pan handler was handed over", function()
    keys.borrow({ lines = {}, canvas = { cols = 40, rows = 10 } }, { zoomed = true })
    assert.is_false(mapped("h"))
  end)
end)

describe("hover.zoom and hover.pan", function()
  local root, win, prev_buf, prev_isfname, prev_cols, prev_lines, buf

  before_each(function()
    config.reset()
    registry.reset()
    vim.g.hover_disable = nil

    root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    fake_png(root .. "/pic.png", 1200, 800)
    vim.fn.writefile(vim.fn["repeat"]({ "line" }, 200), root .. "/long.txt")

    prev_cols, prev_lines = vim.o.columns, vim.o.lines
    vim.o.columns, vim.o.lines = 210, 55

    win = vim.api.nvim_get_current_win()
    prev_buf = vim.api.nvim_win_get_buf(win)
    prev_isfname = vim.o.isfname
    vim.o.isfname = "@,48-57,/,.,-,_,+,,,#,$,%,~,=,:"

    buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, root .. "/notes.md")
    vim.api.nvim_win_set_buf(win, buf)

    -- Stands in for a drawing provider, so a picture produces a canvas at all.
    -- Note it claims the `image` type, and `build` asks the registry *before*
    -- the built-in chain -- so this stand-in has to answer for the zoomed case
    -- too, exactly as `preview.media` does. Getting that wrong made an early
    -- probe report "no crops written" while the code was correct.
    registry.register("stand-in-provider", {
      previews = {
        image = function(target, opts)
          if (opts.zoom or 0) > 0 then
            return nil -- decline, so the built-in zoom path runs
          end
          return media.canvas_for(target.path, opts)
        end,
      },
    })
  end)

  after_each(function()
    hover.hide()
    pcall(vim.api.nvim_win_set_buf, win, prev_buf)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    vim.o.isfname = prev_isfname
    vim.o.columns, vim.o.lines = prev_cols, prev_lines
    vim.fn.delete(root, "rf")
    config.reset()
    registry.reset()
    vim.g.hover_disable = nil
  end)

  ---@param line string
  ---@param col integer
  ---@return boolean
  local function show_at(line, col)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line })
    vim.api.nvim_win_set_cursor(win, { 1, col })
    return hover.show({ force = true })
  end

  it("declines for a text hover, which has no picture to cut", function()
    assert.is_true(show_at("see ./long.txt here", 5))
    assert.is_false(hover.zoom(1))
  end)

  it("declines to pan when nothing is zoomed", function()
    assert.is_true(show_at("see ./pic.png here", 5))
    assert.is_false(hover.pan(1, 0), "panning a whole picture has nowhere to go")
  end)

  it("declines when no float is open, and hands the keys back doing it", function()
    assert.is_true(show_at("see ./pic.png here", 5))
    hover.hide()
    assert.is_false(hover.zoom(1))
    assert.is_false(keys.is_borrowing())
  end)

  it("really cuts the source, when there is something to cut with", function()
    -- Guarded rather than assumed: the crop needs images.nvim carrying
    -- `images.convert.crop` and the ImageMagick it runs, and a CI runner has
    -- neither. Without them this says so instead of passing on a feature that
    -- never ran -- which is what the route test below would otherwise do,
    -- since a float that declines to zoom still survives the command.
    if not media.can_zoom() then
      pending("no images.convert.crop or no ImageMagick -- the crop is images.nvim's own to prove")
      return
    end

    -- `fake_png` writes a PNG *header* and no image data. That is exactly
    -- right for every other test here -- `pixel_size` reads IHDR and never
    -- opens the pixels -- and useless for this one: ImageMagick cannot crop a
    -- file with nothing in it, so the step below would write no file and this
    -- assertion could never have passed on a machine that has magick.
    --
    -- It went unnoticed because it never ran. `scripts/minimal_init.lua` had a
    -- `nil` hole at index 1 of its candidate list, `ipairs` stopped there, and
    -- images.nvim was found only by someone who had IMAGES_NVIM_DIR exported
    -- -- so this test reported *pending* on the machine it was written on.
    --
    -- A real picture, made by the same ImageMagick the branch already
    -- requires: no binary fixture in the repository, and nothing to install
    -- that `can_zoom()` has not already confirmed.
    vim.fn.system({
      "magick",
      "-size",
      "1200x800",
      "gradient:red-blue",
      root .. "/pic.png",
    })
    assert.equals(0, vim.v.shell_error, "could not build a real picture to crop")
    local source = media.pixel_size(root .. "/pic.png")
    assert.same({ 1200, 800 }, { source and source.width, source and source.height })

    local dir = vim.fn.stdpath("cache") .. "/hover.nvim/zoom"
    vim.fn.delete(dir, "rf")

    assert.is_true(show_at("see ./pic.png here", 5))
    assert.is_true(hover.zoom(1))

    ---@return integer
    local function crops()
      local n = 0
      for _, kind in vim.fs.dir(dir) do
        if kind == "file" then
          n = n + 1
        end
      end
      return n
    end
    vim.wait(4000, function()
      return crops() > 0
    end, 50)
    assert.is_true(crops() > 0, "a zoom step wrote no cropped file")

    -- And it is the rectangle the arithmetic asked for, not the whole picture
    -- copied: that is the difference between a zoom and an expensive no-op.
    local want = media.zoom_rect(assert(media.pixel_size(root .. "/pic.png")), 1, 0.5, 0.5)
    local seen
    for name, kind in vim.fs.dir(dir) do
      if kind == "file" then
        seen = media.pixel_size(dir .. "/" .. name)
      end
    end
    assert.is_truthy(seen, "the cropped file has no readable size")
    assert.same({ want.w, want.h }, { seen.width, seen.height })
  end)

  it("is reachable as a command, in both directions", function()
    require("hover.bindings.usrcmds").setup()
    assert.is_true(show_at("see ./pic.png here", 5))
    -- The route exists and the float survives being typed at, which is the
    -- property `:Hover resize` relies on too: the dismissal hangs on
    -- CursorMoved, InsertEnter, BufLeave and WinScrolled, and entering the
    -- command line fires none of them.
    vim.cmd("Hover zoom in")
    assert.is_truthy(float.win(), "the command closed the float it acts on")
    vim.cmd("Hover zoom reset")
    assert.is_truthy(float.win())
    vim.cmd("Hover pan right")
    assert.is_truthy(float.win())
  end)
end)

describe("what a re-render carries with it", function()
  -- The bug this found, and the reason one function now answers for all four:
  -- `scroll` built its own `preview_opts` from the configuration and knew
  -- nothing about the resize level, so **scrolling a resized hover reset it to
  -- the configured size**. Four hand-kept copies of "where this hover is" is
  -- the shape this plugin has been bitten by repeatedly.
  local root, win, prev_buf, prev_isfname, prev_cols, prev_lines, buf

  before_each(function()
    config.reset()
    registry.reset()
    vim.g.hover_disable = nil
    root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    vim.fn.writefile(vim.fn["repeat"]({ "line of text" }, 400), root .. "/long.txt")
    prev_cols, prev_lines = vim.o.columns, vim.o.lines
    vim.o.columns, vim.o.lines = 210, 55
    win = vim.api.nvim_get_current_win()
    prev_buf = vim.api.nvim_win_get_buf(win)
    prev_isfname = vim.o.isfname
    vim.o.isfname = "@,48-57,/,.,-,_,+,,,#,$,%,~,=,:"
    buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, root .. "/notes.md")
    vim.api.nvim_win_set_buf(win, buf)
  end)

  after_each(function()
    hover.hide()
    pcall(vim.api.nvim_win_set_buf, win, prev_buf)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    vim.o.isfname = prev_isfname
    vim.o.columns, vim.o.lines = prev_cols, prev_lines
    vim.fn.delete(root, "rf")
    config.reset()
    registry.reset()
    vim.g.hover_disable = nil
  end)

  it("keeps the resize when the hover is scrolled", function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "see ./long.txt here" })
    vim.api.nvim_win_set_cursor(win, { 1, 5 })
    assert.is_true(hover.show({ force = true }))

    assert.is_true(hover.resize(2))
    local w, h = float.size()

    assert.is_true(hover.scroll(1))
    local after_w, after_h = float.size()
    assert.same(
      { w, h },
      { after_w, after_h },
      "scrolling reset the size the hover had been resized to"
    )
  end)
end)
