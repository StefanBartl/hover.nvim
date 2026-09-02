---@module 'hover.preview.media'
---@brief Image and PDF hover previews.
---@description
--- Both aim at the same result: a blank float in the picture's own aspect
--- ratio, holding nothing but the picture. A filename in the border and a
--- "PNG · 10 KB" line describe something the reader is already looking at,
--- and the float's geometry is not decoration either — it *is* the drawing
--- box handed to the terminal, so a float measured against text deforms the
--- image inside it.
---
--- Metadata is the fallback, not the default: it appears where the picture
--- cannot be drawn at all (no provider, `inline_images = false`, a failed
--- render), and there it is the only thing the hover can say.
---
--- Neither previewer reimplements anything: image drawing goes through
--- `lib.nvim.image_preview`'s provider detection (images.nvim / snacks
--- / image.nvim), and a PDF page becomes a PNG via `pdfport.render_page`,
--- whose own docs name exactly this use case ("lets consumers like
--- images.nvim show a PDF page as an image").

local M = {}

---@internal
---@param n integer|nil
---@return string
local function human_size(n)
  if not n then
    return "?"
  end
  local ok, fmt = pcall(require, "lib.lua.strings.format")
  if ok and fmt and fmt.format_bytes then
    return fmt.format_bytes(n)
  end
  return tostring(n) .. " B"
end

---@internal
--- JPEG dimensions. Unlike PNG/GIF/BMP there is no fixed offset: the size
--- lives in a start-of-frame segment somewhere behind a variable-length run
--- of metadata (an EXIF thumbnail from a phone camera is routinely tens of
--- kilobytes), so the segment chain has to be walked. `f` must be positioned
--- just after the two-byte SOI.
---@param f file*
---@return integer|nil width
---@return integer|nil height
local function jpeg_dimensions(f)
  for _ = 1, 256 do -- bounded: a malformed file must not spin here
    local marker = f:read(2)
    if not marker or #marker < 2 then
      return nil, nil
    end
    local lead, code = marker:byte(1, 2)
    if lead ~= 0xFF then
      return nil, nil
    end

    -- 0xFF doubles as segment padding; skip any run of them.
    while code == 0xFF do
      local nxt = f:read(1)
      if not nxt then
        return nil, nil
      end
      code = nxt:byte(1)
    end

    -- Standalone markers (TEM, RSTn) carry no length field.
    if not (code == 0x01 or (code >= 0xD0 and code <= 0xD7)) then
      local len_bytes = f:read(2)
      if not len_bytes or #len_bytes < 2 then
        return nil, nil
      end
      local len = len_bytes:byte(1) * 256 + len_bytes:byte(2)
      if len < 2 then
        return nil, nil
      end

      -- SOF0..SOF15 carry the frame header, except 0xC4/0xC8/0xCC, which are
      -- Huffman/arithmetic tables that happen to sit in the same range.
      local is_sof = code >= 0xC0
        and code <= 0xCF
        and code ~= 0xC4
        and code ~= 0xC8
        and code ~= 0xCC
      if is_sof then
        local body = f:read(5) -- precision, height (2 bytes), width (2 bytes)
        if not body or #body < 5 then
          return nil, nil
        end
        return body:byte(4) * 256 + body:byte(5), body:byte(2) * 256 + body:byte(3)
      end

      if not f:seek("cur", len - 2) then
        return nil, nil
      end
    end
  end
  return nil, nil
end

---@internal
--- Image dimensions without a decoder: parse just enough header bytes for
--- the common formats. Returns nil for anything else (SVG, WebP, AVIF, …)
--- rather than guessing; `pixel_size` falls back to ImageMagick there.
---@param path string
---@return integer|nil width
---@return integer|nil height
local function dimensions(path)
  local f = io.open(path, "rb")
  if not f then
    return nil, nil
  end
  local head = f:read(32) or ""
  if #head < 24 then
    f:close()
    return nil, nil
  end

  local byte = string.byte

  -- PNG: 8-byte signature, then IHDR with big-endian width/height at 16..23.
  if head:sub(1, 8) == "\137PNG\r\n\26\n" then
    f:close()
    local function be32(offset)
      return byte(head, offset) * 0x1000000
        + byte(head, offset + 1) * 0x10000
        + byte(head, offset + 2) * 0x100
        + byte(head, offset + 3)
    end
    return be32(17), be32(21)
  end

  -- GIF: "GIF87a"/"GIF89a", then little-endian width/height.
  if head:sub(1, 3) == "GIF" then
    f:close()
    return byte(head, 7) + byte(head, 8) * 256, byte(head, 9) + byte(head, 10) * 256
  end

  -- BMP: "BM", little-endian width/height at 18..25.
  if head:sub(1, 2) == "BM" then
    f:close()
    local function le32(offset)
      return byte(head, offset)
        + byte(head, offset + 1) * 0x100
        + byte(head, offset + 2) * 0x10000
        + byte(head, offset + 3) * 0x1000000
    end
    return le32(19), le32(23)
  end

  -- JPEG: SOI, then a segment chain.
  if byte(head, 1) == 0xFF and byte(head, 2) == 0xD8 then
    f:seek("set", 2)
    local w, h = jpeg_dimensions(f)
    f:close()
    return w, h
  end

  f:close()
  return nil, nil
end

---@internal
--- Pixel size of an image: header parse first, ImageMagick only as fallback.
--- That order is deliberate. The parse above is a handful of reads and covers
--- the formats a markdown document actually links, while `images.info` shells
--- out — worth it for a WebP or SVG the parser cannot read, not worth it for
--- every PNG.
---@param path string
---@return Hover.Preview.Dims|nil
local function pixel_size(path)
  local w, h = dimensions(path)
  if w and h and w > 0 and h > 0 then
    return { width = w, height = h }
  end

  local ok, info = pcall(require, "images.info")
  if ok and type(info.collect) == "function" then
    local px = info.collect(path)
    if px and px.width and px.height and px.width > 0 and px.height > 0 then
      return { width = px.width, height = px.height }
    end
  end
  return nil
end

---@internal
--- Fit `image_px` into the hover's maximum box, in cells. Prefers
--- `images.scale.fit_cells` — the same function `images.zen` and
--- `images.redact` size their windows with, so a hover, a zen window and a
--- redaction box all letterbox identically. The local fallback covers an
--- images.nvim too old to have it.
---
--- **A resize arrives here as nothing but a larger `max_width` /
--- `max_lines`.** There is no second drawing path and no factor of its own:
--- the letterboxing, the inset and the screen clamp below all happen exactly
--- where they did, so a resized picture is the same picture in a bigger frame
--- rather than a differently produced one. The clamp is also what gives
--- `hover.resize` its ceiling, which it finds by stepping into it rather than
--- by carrying a number.
---@param image_px Hover.Preview.Dims|nil
---@param opts Hover.PreviewOpts
---@return integer cols
---@return integer rows
local function canvas_cells(image_px, opts)
  local want_cols = opts.max_width or 80
  local want_rows = opts.max_lines or 20

  local max_cols = math.max(10, math.min(want_cols, math.max(10, vim.o.columns - 4)))
  local max_rows = math.max(3, math.min(want_rows, math.max(3, vim.o.lines - 4)))

  -- The frame is not the drawing box. `images.anchor` keeps `draw_inset`
  -- cells free on every side, so a float sized to fit the image exactly is
  -- then drawn into a box two cells smaller on each axis — and two cells off
  -- 20 rows is a bigger relative change than two off 77 columns. The ratio
  -- shifts, `preserveAspectRatio=1` letterboxes what no longer fits, and the
  -- terminal centres the remainder: measured at ~2.7 cells of empty space on
  -- the left for a 1200x675 image in a 77x20 frame. That reads as "the image
  -- is shifted right" and was chased as a placement bug for a long time.
  --
  -- So fit the image to the box it will actually be drawn in, then add the
  -- inset back for the frame. The float ends up slightly larger and the
  -- picture fills it edge to edge.
  local inset = 0
  do
    local ok_cfg, images_cfg = pcall(require, "images.config")
    if ok_cfg then
      local configured = (images_cfg.get().display or {}).draw_inset
      if type(configured) == "number" and configured > 0 then
        inset = math.floor(configured)
      end
    end
  end

  local ok, scale = pcall(require, "images.scale")
  if ok and type(scale.fit_cells) == "function" then
    -- Never let the inset eat the box: on a very small frame keep at least
    -- one cell to fit into, and drop the inset instead.
    local inner_cols = max_cols - 2 * inset
    local inner_rows = max_rows - 2 * inset
    if inner_cols < 1 or inner_rows < 1 then
      inset, inner_cols, inner_rows = 0, max_cols, max_rows
    end

    local cols, rows = scale.fit_cells(inner_cols, inner_rows, image_px)
    return math.min(cols + 2 * inset, max_cols), math.min(rows + 2 * inset, max_rows)
  end

  if not image_px then
    return max_cols, max_rows
  end
  -- A terminal cell is roughly twice as tall as it is wide — the same 0.5
  -- assumption images.scale documents.
  local aspect = image_px.width / image_px.height
  local cols = math.floor(max_rows * aspect / 0.5)
  if cols <= max_cols then
    return math.max(1, cols), max_rows
  end
  return max_cols, math.max(1, math.floor(max_cols * 0.5 / aspect))
end

--- A drawable file as hover content: a blank float in the file's own aspect
--- ratio, plus the path to draw into it. Public because a rasterized PDF page
--- is exactly this once it exists — a PNG that wants a correctly shaped
--- frame and has nothing to say about itself.
---@param path string
---@param opts Hover.PreviewOpts
---@return Hover.Content
function M.canvas_for(path, opts)
  local cols, rows = canvas_cells(pixel_size(path), opts)
  return { lines = {}, canvas = { cols = cols, rows = rows }, image_path = path }
end

--- Draw `png_path` into an already-open hover window, if a provider can.
--- Returns a teardown function to run when the hover closes, or nil when
--- no provider could draw at all.
---
--- The draw is deferred by one tick (`images.anchor`'s `defer` option), and
--- that is the whole reason this goes through `images.anchor` rather than
--- `images.browse.draw_in_window`: the hover float is opened in the *same*
--- tick this runs in. `nvim_ui_send` puts the image on the terminal at once,
--- but Neovim repaints everything that turned dirty since the last return to
--- its main loop — including the cells of the float that was just created —
--- and paints straight over it. Float there, image gone. `browse
--- .draw_in_window` never needed the defer (its snacks picker window has
--- stood for a while by then), so it draws immediately and is the wrong
--- primitive here.
---
--- Because the draw happens later, whether it succeeded is not known when
--- this returns; the teardown is registered on the strength of the provider
--- being present, and clearing when nothing was drawn is a no-op anyway.
---@param png_path string
---@param win integer
---@return (fun())|nil on_close
function M.draw_into(png_path, win)
  local provider = require("lib.nvim.image_preview").detect()
  if provider ~= "images.nvim" then
    -- Only images.nvim can draw into an arbitrary existing window;
    -- snacks/image.nvim need a buffer they own, which a borrowed hover
    -- window is not.
    return nil
  end

  local ok_anchor, anchor = pcall(require, "images.anchor")
  if ok_anchor and type(anchor.draw) == "function" then
    pcall(anchor.draw, win, "full", png_path, { defer = true })
  else
    -- images.nvim without `images.anchor`: fall back to the older public
    -- entry point, undeferred — worse, but better than no image.
    local ok, browse = pcall(require, "images.browse")
    if not ok or type(browse.draw_in_window) ~= "function" then
      return nil
    end
    local drawn = false
    pcall(function()
      drawn = browse.draw_in_window(png_path, win)
    end)
    if not drawn then
      return nil
    end
  end

  return function()
    pcall(function()
      require("images.terminal").clear()
    end)
  end
end

---@type number What one zoom step divides the visible rectangle by.
--- 1.5 rather than the 1.25 `resize` uses, and the reason is the measurement
--- below: a zoom step costs a quarter of a second, so the useful number of
--- them is small. 1.5 reaches 5x in four presses; 1.25 would need eight.
local ZOOM_STEP = 1.5

---@type integer Smallest rectangle a zoom may ask for, in source pixels.
--- Past this there is nothing left to magnify -- the crop is upscaled into
--- the float and the answer is blur rather than detail. A floor on the
--- *source* rectangle rather than one derived from the terminal's cell size,
--- because that needs images.nvim's calibration and this does not.
local ZOOM_FLOOR_PX = 32

--- The rectangle a zoom level and centre select from an image.
---
--- The centre is a fraction of the source rather than a pixel, so it survives
--- a level change: zooming in keeps looking at the same place, which is what
--- makes stepping feel like one gesture rather than a jump. The rectangle is
--- then pushed back inside the source, so a centre near an edge still yields
--- a full-size view rather than one hanging off the picture.
---@param px Hover.Preview.Dims
---@param level integer 0 is the whole picture
---@param cx number 0..1
---@param cy number 0..1
---@return { w: integer, h: integer, x: integer, y: integer }|nil rect nil at level 0
function M.zoom_rect(px, level, cx, cy)
  if level <= 0 then
    return nil
  end
  local factor = ZOOM_STEP ^ level
  local w = math.max(ZOOM_FLOOR_PX, math.floor(px.width / factor))
  local h = math.max(ZOOM_FLOOR_PX, math.floor(px.height / factor))
  w, h = math.min(w, px.width), math.min(h, px.height)

  local x = math.floor(cx * px.width - w / 2)
  local y = math.floor(cy * px.height - h / 2)
  x = math.max(0, math.min(x, px.width - w))
  y = math.max(0, math.min(y, px.height - h))
  return { w = w, h = h, x = x, y = y }
end

--- Whether another step in would show anything new.
---
--- The counterpart to how `resize` finds its ceiling: there a step that
--- changes nothing is stepped back off, because only the terminal knows where
--- the room ends. Here the limit is knowable in advance -- it is the source's
--- own pixels -- so it is answered rather than discovered, and a refused step
--- costs no `magick` run.
---@param px Hover.Preview.Dims|nil
---@param level integer the level that would be reached
---@return boolean
function M.zoom_possible(px, level)
  if not px or level <= 0 then
    return level <= 0
  end
  local factor = ZOOM_STEP ^ level
  return math.floor(px.width / factor) >= ZOOM_FLOOR_PX
    and math.floor(px.height / factor) >= ZOOM_FLOOR_PX
end

---@internal
--- Cropped views, keyed by file, mtime, level and centre. Same lifetime as a
--- rasterized page and swept by the same hook: stepping back out to a view
--- that has been seen must not pay for it twice, and a quarter of a second is
--- worth remembering.
---@type table<string, string>
local _crops = {}

---@internal
---@param path string
---@param rect { w: integer, h: integer, x: integer, y: integer }
---@return string|nil
local function crop_key(path, rect)
  local st = vim.uv.fs_stat(path)
  if not st then
    return nil
  end
  return table.concat({
    path,
    tostring(st.mtime and st.mtime.sec or 0),
    rect.w,
    rect.h,
    rect.x,
    rect.y,
  }, "\0")
end

--- Pixel dimensions of an image, or nil when neither the header parser nor
--- `images.info` can say. Public because `hover.zoom` has to know how far in
--- it may still go, and asking that per step would re-read the file -- and,
--- for a format the parser cannot read, shell out -- on every press.
---@param path string
---@return Hover.Preview.Dims|nil
function M.pixel_size(path)
  return pixel_size(path)
end

--- Whether a magnified detail can be produced at all.
---
--- Two things have to be there and neither is a hard dependency: images.nvim
--- new enough to carry `images.convert.crop`, and the ImageMagick it runs.
--- Asked before a step rather than discovered during one, so the answer is a
--- sentence instead of a float that quietly never changes.
---@return boolean
function M.can_zoom()
  local ok, convert = pcall(require, "images.convert")
  if not ok or type(convert.crop) ~= "function" then
    return false
  end
  return require("lib.nvim.cross.executable").exists("magick")
end

--- A magnified detail of `path`, as hover content.
---
--- **Why this is a separate path from `resize` and not a parameter on it.**
--- `resize` changes the box and the whole picture is letterboxed into it: no
--- process, no file, nothing to wait for. A zoom cuts the source, which means
--- a `magick` run and a file. Measured on Windows, 2026-09-02: process start
--- 71 ms, a 1920x1080 screenshot cropped and fitted **258 ms**, a dense image
--- of the same size 502 ms, a 4K source ~900 ms. No format or compression
--- setting brought it under ~150 ms, and batching several crops into one
--- process saved only the start.
---
--- That cost decides the shape rather than the feature: it is the class this
--- plugin already runs asynchronously behind a placeholder -- and in fact
--- *faster* than the PDF page preview that has shipped all along (1150 ms for
--- one page, measured the same day). So it goes through exactly that
--- machinery, and it is never a key you hold down.
---@param path string
---@param opts Hover.PreviewOpts
---@param on_result fun(content: Hover.Content|nil): nil
---@return Hover.Content|nil provisional content, or nil when nothing can be done
function M.zoomed(path, opts, on_result)
  local px = pixel_size(path)
  local rect = px and M.zoom_rect(px, opts.zoom or 0, opts.zoom_cx or 0.5, opts.zoom_cy or 0.5)
  if not rect then
    return nil
  end

  local key = crop_key(path, rect)
  local cached = key and _crops[key]
  if cached and vim.uv.fs_stat(cached) then
    -- Nothing to wait for, so nothing is deferred and no placeholder can
    -- flash: stepping back to a view already cut is as instant as `resize`.
    return M.canvas_for(cached, opts)
  end

  local ok_convert, convert = pcall(require, "images.convert")
  if not ok_convert or type(convert.crop) ~= "function" then
    return nil
  end

  local out = ("%s/hover.nvim/zoom/%s.png"):format(
    vim.fn.stdpath("cache"),
    vim.fn.sha256(key or (path .. tostring(rect.x)))
  )
  local spec = ("%dx%d+%d+%d"):format(rect.w, rect.h, rect.x, rect.y)

  convert.crop(path, spec, out, nil, function(cropped)
    if not cropped then
      -- Silence rather than a badge: the picture the reader is looking at is
      -- still on screen and still correct, only not magnified.
      on_result(nil)
      return
    end
    if key then
      _crops[key] = cropped
      M._hook_cleanup()
    end
    on_result(M.canvas_for(cropped, opts))
  end)

  -- The uncropped picture, held back for the grace period. A crop that beats
  -- it shows the detail and nothing else; one that does not leaves the whole
  -- picture up rather than a wait that looks like the hover failing.
  return vim.tbl_extend("force", M.canvas_for(path, opts), { pending = true })
end

--- Image preview.
---
--- Two shapes, depending on whether the picture can actually be drawn:
---
--- * **Drawable** — a blank float sized to the image's aspect ratio, and
---   nothing else. No filename in the border, no dimension or size line: the
---   reader is looking at the picture, and a caption for it is noise. The
---   sizing is not only cosmetic — the drawing box handed to the terminal
---   *is* the float's geometry, so a float measured against two lines of text
---   squeezes the image into a box two cells tall.
--- * **Not drawable** (no provider, or `inline_images = false`) — the
---   metadata lines, which are then the only thing the hover can say at all.
---@param target Hover.Target
---@param opts Hover.PreviewOpts
---@return Hover.Content
function M.image(target, opts)
  local provider = require("lib.nvim.image_preview").detect()

  if provider and opts.inline_images ~= false then
    return M.canvas_for(target.path, opts)
  end

  local lines = {}
  local w, h = dimensions(target.path)
  if w and h then
    lines[#lines + 1] = ("%d × %d px"):format(w, h)
  end
  lines[#lines + 1] = ("%s · %s"):format((target.ext or "image"):upper(), human_size(target.size))
  if not provider then
    lines[#lines + 1] = "(no image provider installed)"
  end

  return { lines = lines, title = vim.fs.basename(target.path) }
end

---@internal
--- Rasterized pages, keyed by file *and* mtime: a PDF that changed on disk
--- must not answer with the old page. The PNGs outlive the float they were
--- drawn into — that is the whole point, a second hover over the same PDF
--- should not shell out to pdftoppm again — so they are cleaned up once at
--- exit rather than per close.
---@type table<string, string>
local _pages = {}
local _cleanup_hooked = false

---@internal
--- Register the one exit sweep, once. It clears both caches -- rasterized
--- pages and cropped details -- because they have the same lifetime and the
--- same reason for it: both outlive the float they were drawn into on
--- purpose, and neither should outlive the session.
---@return nil
function M._hook_cleanup()
  if _cleanup_hooked then
    return
  end
  _cleanup_hooked = true
  require("lib.nvim.bindings.autocmd").create("VimLeavePre", function()
    for _, file in pairs(_pages) do
      pcall(os.remove, file)
    end
    for _, file in pairs(_crops) do
      pcall(os.remove, file)
    end
    _pages, _crops = {}, {}
  end, {
    group = "HoverMedia",
    desc = "hover: delete rasterized PDF pages and cropped details at exit",
  })
end

---@internal
--- The page number is part of the key. It was passed in from the start and
--- silently dropped, so every page of one PDF shared a single cache slot:
--- rendering page 2 deleted page 1's PNG, and a later hover on page 1 was
--- served page 2's image.
---@param path string
---@param page integer
---@return string|nil
local function page_key(path, page)
  local st = vim.uv.fs_stat(path)
  if not st then
    return nil
  end
  return path .. "\0" .. tostring(st.mtime and st.mtime.sec or 0) .. "\0" .. tostring(page)
end

---@internal
---@param key string
---@param png string
local function remember_page(key, png)
  M._hook_cleanup()

  local previous = _pages[key]
  if previous and previous ~= png then
    pcall(os.remove, previous)
  end
  _pages[key] = png
end

--- PDF preview.
---
--- Same destination as an image hover — a blank float in the page's aspect
--- ratio — reached in up to three steps, because the page does not exist yet.
---
--- 1. **Already rasterized** (same file, same mtime): returns the finished
---    content synchronously. Nothing pops, because nothing has to wait.
--- 2. **Not yet**: `pdfport.render_page` shells out to pdftoppm and the
---    return value is a *provisional* metadata float marked `pending`. Whether
---    it is ever shown is the caller's decision — `hover` holds it
---    back for a grace period, so a fast render never flashes it.
--- 3. **Rendered**: `on_result` receives the real content, and the page is
---    kept for the next hover.
---
--- The rendered PNG is owned by this module from here on. Callers must not
--- delete it — an earlier version did, which is why every hover re-rendered.
---@param target Hover.Target
---@param opts Hover.PreviewOpts
---@param on_result fun(content: Hover.Content): nil
---@return Hover.Content
function M.pdf(target, opts, on_result)
  local function metadata(extra)
    local lines = { ("PDF · %s"):format(human_size(target.size)) }
    if extra then
      lines[#lines + 1] = extra
    end
    return { lines = lines, title = vim.fs.basename(target.path) }
  end

  local ok_pdfport, pdfport = pcall(require, "pdfport")
  if not ok_pdfport or type(pdfport.render_page) ~= "function" then
    return metadata("(pdfport.nvim not installed — no page preview)")
  end

  if opts.inline_images == false then
    return metadata()
  end

  local provider = require("lib.nvim.image_preview").detect()
  if not provider then
    return metadata("(no image provider installed)")
  end

  local page = math.max(1, math.floor(opts.page or 1))
  local key = page_key(target.path, page)
  local cached = key and _pages[key]
  -- `fs_stat`: a temp sweeper may have taken the file since. Then it is not a
  -- cache entry any more, it is a dangling path.
  if cached and vim.uv.fs_stat(cached) then
    local content = M.canvas_for(cached, opts)
    content.scroll = { page = page, step = 1, more = true }
    -- Page 1 stays untitled, as every image preview does: a filename over a
    -- picture the reader is already looking at is noise. From page 2 on the
    -- number is the one thing the picture cannot say about itself.
    if page > 1 then
      content.title = ("p%d"):format(page)
    end
    return content
  end
  if key and cached then
    _pages[key] = nil
  end

  pdfport.render_page(target.path, page, nil, function(png_path, err)
    -- pdftoppm's exit lands in a fast event context, where neither
    -- `nvim_create_autocmd` nor the ImageMagick fallback's `vim.system():wait()`
    -- may be called. Everything downstream of here runs on the main loop.
    vim.schedule(function()
      if not png_path then
        -- A failed render past page 1 is almost always "there is no such
        -- page", which is how the page count is discovered: pdfport reports
        -- no total, so paging walks until it stops. Reported as an end rather
        -- than an error so the caller can step back instead of showing a
        -- failure for a document it has simply reached the end of.
        if page > 1 then
          on_result(vim.tbl_extend("force", metadata(("(no page %d)"):format(page)), {
            scroll = { page = page, step = 1, more = false, past_end = true },
          }))
        else
          on_result(metadata("(page render failed: " .. (err or "unknown error") .. ")"))
        end
        return
      end
      if key then
        remember_page(key, png_path)
      end
      local content = M.canvas_for(png_path, opts)
      content.scroll = { page = page, step = 1, more = true }
      if page > 1 then
        content.title = ("p%d"):format(page)
      end
      on_result(content)
    end)
  end)

  return vim.tbl_extend(
    "force",
    metadata(("rendering page %d…"):format(page)),
    { pending = true }
  )
end

return M
