---@diagnostic disable: need-check-nil
-- The test body is the guard; see the note in TESTS/bare_path_spec.lua
-- (`LLS-42`).

-- TESTS/zoom_spec.lua -- making the picture bigger, and the two things about
-- it that are not obvious.
--
--   1. **The ceiling belongs to the terminal, not to this plugin.** Measured
--      against a real Neovim on 2026-09-02, a 1200x675 image at the default
--      80x20 box: a 210x55 terminal has room for five steps (71x20 cells of
--      picture up to 181x51); an 80x24 one has room for **none**, because 20
--      rows is already `lines - 4`. Any fixed limit would be wrong on one of
--      those two, so `hover.zoom` carries none and steps back off a press
--      that changed nothing. The specs below therefore say how large the
--      screen is before they ask for room on it -- a plenary run is 80x24,
--      which is precisely the size where zoom cannot do anything.
--
--   2. **The borrow condition is `canvas`, not `scroll`.** An image declares
--      no `scroll` -- `canvas_for` returns `lines`, `canvas` and
--      `image_path`, nothing else -- so hanging zoom off the one condition
--      `keys.borrow` already had would have bound it for every case except
--      the one it is for.
--
-- Zoom is not a second drawing path: it scales the box `canvas_cells` fits
-- the picture into and nothing else. What is pinned here is that scaling and
-- its edges, not the drawing, which needs a terminal and is evidenced by hand
-- (`docs/MANUAL-EVIDENCE.md`).

local config = require("hover.config")
local media = require("hover.preview.media")
local keys = require("hover.bindings.keymaps")
local float = require("hover.float")
local registry = require("hover.registry")
local hover = require("hover")

--- Write a file whose first 32 bytes are a PNG header of the given size.
--- `media.dimensions` reads exactly that much and no more, so the picture
--- needs no pixels to have a shape.
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

describe("the canvas a zoom factor asks for", function()
  local root, png

  before_each(function()
    config.reset()
    root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    png = root .. "/pic.png"
    fake_png(png, 1200, 675)
  end)

  after_each(function()
    vim.fn.delete(root, "rf")
    config.reset()
  end)

  ---@param zoom number|nil
  ---@return Hover.Canvas
  local function canvas(zoom)
    local opts = config.preview_opts()
    opts.zoom = zoom
    return media.canvas_for(png, opts).canvas
  end

  it("is the same with no zoom as with a factor of one", function()
    assert.same(canvas(nil), canvas(1))
    -- A factor that is not a positive number is not a factor. `0` would
    -- collapse the box, and a negative one is the *level* being passed where
    -- the multiplier belongs.
    assert.same(canvas(1), canvas(0))
    assert.same(canvas(1), canvas(-2))
  end)

  it("grows with the factor, while there is screen left", function()
    local before = canvas(1)
    -- Enough screen that the default box is not already against it.
    local cols, lines = vim.o.columns, vim.o.lines
    vim.o.columns, vim.o.lines = 210, 55
    local grown = canvas(1.25)
    vim.o.columns, vim.o.lines = cols, lines

    assert.is_true(
      grown.cols > before.cols and grown.rows > before.rows,
      ("%dx%d did not grow past %dx%d"):format(grown.cols, grown.rows, before.cols, before.rows)
    )
  end)

  it("never asks for more than the terminal has", function()
    local big = canvas(100)
    assert.is_true(big.cols <= math.max(10, vim.o.columns - 4))
    assert.is_true(big.rows <= math.max(3, vim.o.lines - 4))
  end)

  it("shrinks to a floor rather than to nothing", function()
    -- The floors are `canvas_cells`' own, and they are what makes zooming out
    -- safe to hold down: the box stops being a box before it stops existing.
    local tiny = canvas(0.001)
    assert.is_true(tiny.cols >= 1 and tiny.rows >= 1)
    assert.is_true(tiny.cols < canvas(1).cols or tiny.rows < canvas(1).rows)
  end)
end)

describe("the keys a drawn hover borrows", function()
  before_each(function()
    config.reset()
    keys.release()
  end)

  after_each(function()
    keys.release()
    -- Here rather than at the end of the one test that sets a mapping: a
    -- failing assertion returns before its own cleanup, and the leaked `+`
    -- then reads as a second failure in the next test. Found by sabotaging
    -- the borrow away and watching two specs fall for one reason.
    for _, lhs in ipairs({ "+", "-" }) do
      pcall(vim.keymap.del, "n", lhs)
    end
    config.reset()
  end)

  ---@param lhs string
  ---@return boolean
  local function mapped(lhs)
    return vim.fn.maparg(lhs, "n") ~= ""
  end

  it("takes the zoom keys for a picture", function()
    keys.borrow(
      { lines = {}, canvas = { cols = 40, rows = 10 }, image_path = "/x.png" },
      function() end,
      function() end
    )
    assert.is_true(mapped("+"))
    assert.is_true(mapped("-"))
  end)

  it("takes no zoom key for text, which has nothing to zoom", function()
    -- Scrollable, and deliberately so: this is the content that *does* get
    -- the other borrowed pair, and it must still not get this one.
    keys.borrow(
      { lines = { "a", "b" }, scroll = { offset = 0, step = 20, more = true } },
      function() end,
      function() end
    )
    assert.is_false(mapped("+"))
    assert.is_false(mapped("-"))
  end)

  it("takes none when no zoom handler was handed over", function()
    -- `borrow` is public; a caller that does not implement zoom must not end
    -- up with keys bound to nothing.
    keys.borrow({ lines = {}, canvas = { cols = 40, rows = 10 } }, function() end)
    assert.is_false(mapped("+"))
  end)

  it("gives back what it displaced, rather than deleting it", function()
    vim.keymap.set("n", "+", "<Nop>", { desc = "the user's own +" })
    keys.borrow({ lines = {}, canvas = { cols = 40, rows = 10 } }, function() end, function() end)
    assert.equals("hover: zoom the picture in", vim.fn.maparg("+", "n", false, true).desc)
    keys.release()
    assert.equals("the user's own +", vim.fn.maparg("+", "n", false, true).desc)
  end)

  it("binds nothing when the key list is emptied", function()
    config.setup({ zoom_keys = { larger = {}, smaller = {} } })
    keys.borrow({ lines = {}, canvas = { cols = 40, rows = 10 } }, function() end, function() end)
    assert.is_false(mapped("+"))
    assert.is_false(mapped("-"))
  end)
end)

describe("hover.zoom", function()
  local root, win, prev_buf, prev_isfname, prev_cols, prev_lines, buf

  before_each(function()
    config.reset()
    registry.reset()
    vim.g.hover_disable = nil

    root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    fake_png(root .. "/pic.png", 1200, 675)
    vim.fn.writefile({ "%PDF-1.4" }, root .. "/doc.pdf")
    vim.fn.writefile(vim.fn["repeat"]({ "line" }, 200), root .. "/long.txt")

    -- A plenary run is 80x24, where `lines - 4` equals the default
    -- `max_lines` and no zoom step can do anything. Say how big the screen is
    -- before asking it for room.
    prev_cols, prev_lines = vim.o.columns, vim.o.lines
    vim.o.columns, vim.o.lines = 210, 55

    win = vim.api.nvim_get_current_win()
    prev_buf = vim.api.nvim_win_get_buf(win)
    prev_isfname = vim.o.isfname
    vim.o.isfname = "@,48-57,/,.,-,_,+,,,#,$,%,~,=,:"

    buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, root .. "/notes.md")
    vim.api.nvim_win_set_buf(win, buf)

    -- Stands in for an image provider, and for that alone. `preview.media`
    -- asks `lib.nvim.image_preview.detect()` whether anything can draw, and
    -- with nothing installed it answers with metadata lines instead of a
    -- canvas -- so on a runner there would be no picture to zoom and these
    -- specs would pass by never testing anything. This registration is the
    -- one line `media.image` runs when a provider *is* there, so everything
    -- below it is the real path: the real `canvas_cells`, the real
    -- `hover.zoom`, the real float. Only `detect()` and the drawing itself
    -- are missing, and the drawing needs a terminal (`MANUAL-EVIDENCE.md`).
    registry.register("stand-in-provider", {
      previews = {
        image = function(target, opts)
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

  ---@return integer width
  ---@return integer height
  local function geometry()
    local w = float.win()
    assert(w, "no float is open")
    local cfg = vim.api.nvim_win_get_config(w)
    return cfg.width, cfg.height
  end

  it("makes the float bigger, and smaller again", function()
    assert.is_true(show_at("see ./pic.png here", 5))
    local w0, h0 = geometry()

    assert.is_true(hover.zoom(1))
    local w1, h1 = geometry()
    assert.is_true(w1 > w0 and h1 > h0, ("%dx%d is not bigger than %dx%d"):format(w1, h1, w0, h0))

    assert.is_true(hover.zoom(-1))
    assert.same({ w0, h0 }, { geometry() })
  end)

  it("stops where the terminal does, and does not run the level away there", function()
    -- The property that makes holding the key safe. Without the step-back,
    -- eight presses into the ceiling would need eight presses to come out of
    -- it, and the first few would look like the key had stopped working.
    assert.is_true(show_at("see ./pic.png here", 5))
    for _ = 1, 12 do
      hover.zoom(1)
    end
    local wmax, hmax = geometry()

    hover.zoom(-1)
    local w, h = geometry()
    assert.is_true(
      w < wmax and h < hmax,
      ("one step out of the ceiling left %dx%d, was %dx%d"):format(w, h, wmax, hmax)
    )
  end)

  it("declines for a hover with nothing drawn in it", function()
    assert.is_true(show_at("see ./long.txt here", 5))
    assert.is_false(hover.zoom(1))
  end)

  it("declines when no float is open, and hands the keys back doing it", function()
    assert.is_true(show_at("see ./pic.png here", 5))
    hover.hide()
    assert.is_false(hover.zoom(1))
    assert.is_false(keys.is_borrowing())
  end)

  it("keeps the page it is on while zooming", function()
    -- A PDF is the one target with both, and the trap is that
    -- `config.preview_opts()` is built fresh from the configuration: it knows
    -- nothing about where this hover already is, so page and offset have to
    -- be put back deliberately. Zooming page 3 back to page 1 would look
    -- exactly like a zoom bug and is not one.
    local seen = {}
    registry.register("fake-pdf", {
      previews = {
        pdf = function(_, opts)
          seen[#seen + 1] = { page = opts.page, zoom = opts.zoom }
          local factor = opts.zoom or 1
          return {
            lines = {},
            canvas = { cols = math.floor(40 * factor), rows = math.floor(10 * factor) },
            image_path = root .. "/pic.png",
            scroll = { page = opts.page or 1, step = 1, more = true },
          }
        end,
      },
    })

    assert.is_true(show_at("see ./doc.pdf here", 5))
    assert.is_true(hover.scroll(1))
    assert.equals(2, seen[#seen].page)

    assert.is_true(hover.zoom(1))
    assert.equals(2, seen[#seen].page, "zooming lost the page the hover was on")
    assert.is_true((seen[#seen].zoom or 1) > 1, "the zoom factor never reached the previewer")
  end)

  -- `:Hover zoom` -- the same step, reached the way the rest of this plugin
  -- is reached.
  --
  -- The keys are primary, and they are a *borrow*: bound only while a drawn
  -- hover is on screen. A reader who has never seen one has no way to find
  -- the feature, and `:Hover` completion is where everything else here is
  -- found.
  --
  -- The route only works because the float survives being typed at: its
  -- dismissal hangs on CursorMoved, InsertEnter, BufLeave and WinScrolled,
  -- and entering the command line fires none of them. Asserted rather than
  -- assumed -- if it were false the route would be a command that closes the
  -- thing it acts on.
  it("is reachable as a command, in both directions", function()
    require("hover.bindings.usrcmds").setup()
    assert.is_true(show_at("see ./pic.png here", 5))
    local w0, h0 = geometry()

    vim.cmd("Hover zoom in")
    local w1, h1 = geometry()
    assert.is_true(w1 > w0 and h1 > h0, "the command did not grow the float")

    vim.cmd("Hover zoom out")
    assert.same({ w0, h0 }, { geometry() })
  end)

  it("zooms in on a bare `:Hover zoom`, and the float survives the command", function()
    require("hover.bindings.usrcmds").setup()
    assert.is_true(show_at("see ./pic.png here", 5))
    local w0 = (geometry())

    vim.cmd("Hover zoom")
    assert.is_truthy(float.win(), "the float did not survive a command line")
    assert.is_true((geometry()) > w0, "a bare zoom did not zoom in")
  end)
end)
