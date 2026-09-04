-- scripts/pdfzoom_probe.lua -- the sharp PDF zoom, against a real document.
--
-- Run from THIS repository's root -- hover.nvim's checkout, not your Neovim
-- configuration directory; `-l` resolves the path relative to the working
-- directory and the runtime path is appended from it:
--   nvim --clean --headless -l scripts/pdfzoom_probe.lua path/to/file.pdf
--   nvim --clean --headless -l scripts/pdfzoom_probe.lua path/to/file.pdf 7
--
-- **Why this is a script and not a spec.** The claim the feature makes is
-- that a magnified page is *sharper*, not merely larger, and that costs a
-- second rasterization by pdftoppm -- which no CI here has, and which no
-- assertion about arithmetic can stand in for. The suite covers what a
-- machine can check: which window a level selects, that the cache key carries
-- the DPI, that the keys are offered for a page at all. What it cannot check
-- is that pdftoppm was asked for the right window and answered with more
-- detail in it.
--
-- So this prints what happened and reading it is the check, exactly like
-- `scripts/onrequest_probe.lua`.
--
-- What to look for, in the table it prints:
--
--   * **px** is the same on every row. That is the whole cost argument: a
--     level does not enlarge the render, it re-samples the same number of
--     pixels from a higher resolution, so the wait does not grow with depth.
--   * **ms** stays in the same band from level 0 to the ceiling. A row that
--     climbs with the level means the crop window was dropped and the whole
--     page is being rendered at that DPI -- which is the failure mode a
--     pdfport too old to understand `opts.crop` produces, silently.
--   * **sha** differs on every row. Equal hashes mean the DPI never reached
--     pdftoppm and every level rendered the same picture.
--   * **sharp** beats **cropped**, on every row. This is the feature itself,
--     and it is a comparison rather than a trend: both columns are the
--     standard deviation of a Laplacian over the *same window* of the page at
--     the same pixel size -- `sharp` re-rendered at the higher DPI, `cropped`
--     cut out of the level-0 render and scaled up, which is what the picture
--     zoom would do and what this feature exists to not do. A single column
--     would say nothing: detail *per pixel* falls as the view narrows, since
--     two magnified letterforms are mostly white. Needs ImageMagick; without
--     it both read `-` and the other columns still say whether it worked.

vim.opt.rtp:append(vim.fn.getcwd())

local deps = dofile(vim.fn.getcwd() .. "/scripts/probe_deps.lua")

if not deps.add("LIB_NVIM_DIR", "lib.nvim", "lib.nvim.notify", "scripts/pdfzoom_probe.lua") then
  os.exit(1)
end
if not deps.add("PDFPORT_NVIM_DIR", "pdfport.nvim", "pdfport", "scripts/pdfzoom_probe.lua") then
  os.exit(1)
end
-- Optional: only the sharpness columns need it, and `images.nvim` is what
-- `lib.nvim.image_preview` detects as a drawing provider -- without one,
-- `media.pdf` answers with metadata and never renders anything at all.
deps.add("IMAGES_NVIM_DIR", "images.nvim", "images.convert", "scripts/pdfzoom_probe.lua")

local argv = _G.arg or {}
local pdf = argv[1]
local page = tonumber(argv[2]) or 1

if not pdf or pdf == "" then
  io.stderr:write("scripts/pdfzoom_probe.lua: pass a PDF path as the first argument.\n")
  os.exit(1)
end
if vim.fn.filereadable(pdf) ~= 1 then
  io.stderr:write(("scripts/pdfzoom_probe.lua: cannot read %s\n"):format(pdf))
  os.exit(1)
end

local media = require("hover.preview.media")

if not media.can_zoom_pdf() then
  io.stderr:write(
    "scripts/pdfzoom_probe.lua: pdfport.nvim cannot rasterize a window of a page "
      .. "(`pdfport.can_render_page_crop`). That is exactly the state in which the zoom "
      .. "keys are not offered, so there is nothing to probe.\n"
  )
  os.exit(1)
end

local st = vim.uv.fs_stat(pdf)

---@type Hover.Target
local target = { type = "pdf", path = pdf, raw = pdf, size = st and st.size or 0 }

--- One `media.pdf` call, run to completion.
---@param level integer
---@return table|nil result
local function view(level)
  local opts = {
    page = page,
    zoom = level,
    zoom_cx = 0.5,
    zoom_cy = 0.5,
    max_width = 120,
    max_lines = 40,
    inline_images = true,
  }

  local done, content = false, nil
  local started = vim.uv.hrtime()

  local provisional = media.pdf(target, opts, function(c)
    content = c
    done = true
  end)
  if provisional and not provisional.pending then
    content, done = provisional, true
  end

  vim.wait(60000, function()
    return done
  end, 20)

  local ms = (vim.uv.hrtime() - started) / 1e6
  if not content then
    return nil
  end
  return { ms = ms, png = content.image_path, lines = content.lines }
end

---@param path string
---@return string
local function sha(path)
  local fd = io.open(path, "rb")
  if not fd then
    return "?"
  end
  local body = fd:read("*a")
  fd:close()
  return vim.fn.sha256(body):sub(1, 10)
end

---@return boolean
local function have_magick()
  return vim.fn.executable("magick") == 1
end

--- Laplacian standard deviation: detail per pixel, as one number.
---@param path string
---@return string
local function edges(path)
  if not have_magick() then
    return "-"
  end
  local out = vim
    .system({
      "magick",
      path,
      "-colorspace",
      "gray",
      "-morphology",
      "Convolve",
      "Laplacian:0",
      "-format",
      "%[fx:standard_deviation]",
      "info:",
    }, { text = true })
    :wait()
  if out.code ~= 0 then
    return "-"
  end
  return (out.stdout or ""):gsub("%s+$", ""):sub(1, 6)
end

--- The same window, taken the way a *picture* zoom takes it: cropped out of
--- the level-0 render and scaled back up to its size.
---
--- The control the `sharp` column is measured against, and — before this
--- feature existed — the only thing a zoom key could have done to a page.
---@param base_png string
---@param level integer
---@return string|nil path
local function upscaled(base_png, level)
  if not have_magick() then
    return nil
  end
  local px = media.pixel_size(base_png)
  local rect = px and media.zoom_rect(px, level, 0.5, 0.5)
  if not (px and rect) then
    return nil
  end
  local out = ("%s/hover-pdfzoom-probe-%d.png"):format(vim.fn.stdpath("cache"), level)
  local done = vim
    .system({
      "magick",
      base_png,
      "-crop",
      ("%dx%d+%d+%d"):format(rect.w, rect.h, rect.x, rect.y),
      "+repage",
      "-resize",
      ("%dx%d!"):format(px.width, px.height),
      out,
    }, { text = true })
    :wait()
  if done.code ~= 0 then
    return nil
  end
  return out
end

io.stdout:write(("PDF %s, page %d\n\n"):format(pdf, page))
io.stdout:write(
  ("%5s %10s %14s %10s %12s %8s %9s\n"):format("level", "ms", "px", "KB", "sha", "sharp", "cropped")
)

---@type string|nil
local base_png = nil

for level = 0, 6 do
  if not media.pdf_zoom_possible(level) then
    io.stdout:write(("%5d   (past the ceiling -- no render attempted)\n"):format(level))
    break
  end
  local result = view(level)
  if not result then
    io.stdout:write(("%5d   nothing came back\n"):format(level))
  else
    local png = result.png
    if not png then
      io.stdout:write(
        ("%5d %10.0f   no picture: %s\n"):format(
          level,
          result.ms,
          table.concat(result.lines or {}, " / ")
        )
      )
    else
      base_png = base_png or png
      local size = media.pixel_size(png)
      local bytes = (vim.uv.fs_stat(png) or {}).size or 0
      local control = level > 0 and upscaled(base_png, level) or nil
      io.stdout:write(
        ("%5d %9.0fms %14s %9.0f %12s %8s %9s\n"):format(
          level,
          result.ms,
          size and ("%dx%d"):format(size.width, size.height) or "?",
          bytes / 1024,
          sha(png),
          edges(png),
          control and edges(control) or "-"
        )
      )
    end
  end
end

io.stdout:write("\n")
