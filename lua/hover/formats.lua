---@module 'hover.formats'
---@brief What a file extension actually names, for the previews that have to
---say so in words.
---@description
--- Two questions are asked of this table, by two modules that must not depend
--- on each other:
---
---  * `hover.classify` asks **"is this an office document?"** — the
---    one group that has a second preview route (convert to PDF, show the
---    page), so it gets a target type of its own.
---  * `hover.preview.binary` asks **"what do I call this?"** for the
---    badge it shows when a file has no text to preview.
---
--- Keeping both answers in one table is the point. The alternative — an
--- extension list in `classify` and a label list in the preview — drifts the
--- moment one of them learns about `.pptm` and the other does not.
---
--- **The table is not the test for "binary".** It cannot be: the interesting
--- case is the file nobody listed. Whether a preview is possible is decided
--- by looking at the bytes (`preview.binary.is_binary`); this table only
--- supplies a better word than "binary file" when the extension is known.

local M = {}

---@class Hover.Format
---@field label string # Human name for the badge's first line.
---@field office? boolean # Convertible to PDF by LibreOffice, and therefore previewable page by page.
---@field video? boolean # Holds moving picture, and therefore has a frame ffmpeg can lift out of it.

---@type table<string, Hover.Format>
local FORMATS = {
  -- ── Office documents ──────────────────────────────────────────────────
  -- `office = true` is what routes these to `preview.office` instead of the
  -- generic badge: they are the formats `pdfport.nvim`'s soffice producer
  -- accepts, and therefore the only ones that can become a picture.
  doc = { label = "Word document", office = true },
  docx = { label = "Word document", office = true },
  docm = { label = "Word document (macro-enabled)", office = true },
  dot = { label = "Word template", office = true },
  dotx = { label = "Word template", office = true },
  rtf = { label = "Rich Text document", office = true },
  xls = { label = "Excel workbook", office = true },
  xlsx = { label = "Excel workbook", office = true },
  xlsm = { label = "Excel workbook (macro-enabled)", office = true },
  xlt = { label = "Excel template", office = true },
  xltx = { label = "Excel template", office = true },
  ppt = { label = "PowerPoint presentation", office = true },
  pptx = { label = "PowerPoint presentation", office = true },
  pptm = { label = "PowerPoint presentation (macro-enabled)", office = true },
  pps = { label = "PowerPoint slideshow", office = true },
  ppsx = { label = "PowerPoint slideshow", office = true },
  odt = { label = "OpenDocument text", office = true },
  ods = { label = "OpenDocument spreadsheet", office = true },
  odp = { label = "OpenDocument presentation", office = true },
  odg = { label = "OpenDocument drawing", office = true },

  -- ── Archives ──────────────────────────────────────────────────────────
  zip = { label = "ZIP archive" },
  ["7z"] = { label = "7-Zip archive" },
  rar = { label = "RAR archive" },
  tar = { label = "tar archive" },
  gz = { label = "gzip archive" },
  tgz = { label = "gzip archive" },
  bz2 = { label = "bzip2 archive" },
  xz = { label = "xz archive" },
  zst = { label = "zstd archive" },
  jar = { label = "Java archive" },
  whl = { label = "Python wheel" },

  -- ── Executables and objects ───────────────────────────────────────────
  exe = { label = "Windows executable" },
  dll = { label = "Windows library" },
  msi = { label = "Windows installer" },
  so = { label = "shared library" },
  dylib = { label = "shared library" },
  o = { label = "object file" },
  a = { label = "static library" },
  obj = { label = "object file" },
  class = { label = "Java class file" },
  wasm = { label = "WebAssembly module" },
  pyc = { label = "compiled Python" },
  luac = { label = "compiled Lua" },

  -- ── Media ─────────────────────────────────────────────────────────────
  mp3 = { label = "MP3 audio" },
  wav = { label = "WAV audio" },
  flac = { label = "FLAC audio" },
  ogg = { label = "Ogg audio" },
  opus = { label = "Opus audio" },
  m4a = { label = "AAC audio" },
  -- `video = true` is what routes these to `preview.video` instead of the
  -- generic badge — the second group with another answer available: media.nvim
  -- lifts a frame out with ffmpeg, and a frame is something this hover can
  -- actually show. The list is the containers ffmpeg reads *and* people put
  -- video in; `.ogg` stays audio-only above because in practice it is, and a
  -- false claim here costs the reader their badge and gives back an error.
  mp4 = { label = "MP4 video", video = true },
  m4v = { label = "MPEG-4 video", video = true },
  mkv = { label = "Matroska video", video = true },
  mov = { label = "QuickTime video", video = true },
  avi = { label = "AVI video", video = true },
  webm = { label = "WebM video", video = true },
  wmv = { label = "Windows Media video", video = true },
  flv = { label = "Flash video", video = true },
  mpg = { label = "MPEG video", video = true },
  mpeg = { label = "MPEG video", video = true },
  -- `.ts` and `.mts` are deliberately absent. They are MPEG transport streams
  -- and they are TypeScript, and in an editor the second reading wins by
  -- orders of magnitude — claiming them would send every TypeScript file in a
  -- project to ffmpeg. `.m2ts` is unambiguous and stays.
  m2ts = { label = "Blu-ray transport stream", video = true },
  ogv = { label = "Ogg video", video = true },
  ["3gp"] = { label = "3GPP video", video = true },

  -- ── Fonts ─────────────────────────────────────────────────────────────
  ttf = { label = "TrueType font" },
  otf = { label = "OpenType font" },
  woff = { label = "web font" },
  woff2 = { label = "web font" },

  -- ── Data and disk images ──────────────────────────────────────────────
  sqlite = { label = "SQLite database" },
  sqlite3 = { label = "SQLite database" },
  db = { label = "database file" },
  iso = { label = "disc image" },
  dmg = { label = "disk image" },
  psd = { label = "Photoshop document" },
  blend = { label = "Blender file" },
  epub = { label = "EPUB book" },
}

--- What `ext` is known to be, or nil.
---@param ext string|nil
---@return Hover.Format|nil
function M.of(ext)
  if type(ext) ~= "string" or ext == "" then
    return nil
  end
  return FORMATS[ext:lower()]
end

--- Human name for `ext`, or nil when the extension says nothing.
---@param ext string|nil
---@return string|nil
function M.label(ext)
  local format = M.of(ext)
  return format and format.label or nil
end

--- Whether `ext` names an office document — the group that can be shown as a
--- picture by way of a PDF, rather than only described.
---@param ext string|nil
---@return boolean
function M.is_office(ext)
  local format = M.of(ext)
  return format ~= nil and format.office == true
end

--- Whether `ext` names a video — the other group that can become a picture,
--- here by way of a frame rather than a page.
---@param ext string|nil
---@return boolean
function M.is_video(ext)
  local format = M.of(ext)
  return format ~= nil and format.video == true
end

return M
