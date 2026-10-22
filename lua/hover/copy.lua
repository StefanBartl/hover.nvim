---@module 'hover.copy'
---@brief Take what the float shows: its text into the registers, or the
---picture on screen as a file whose path goes into the registers.
---@description
--- The float is `focusable = false` (see `float.lua`), so nothing in it can
--- be selected or yanked the ordinary way. `:Hover copy` is the way out, and
--- it takes **what is on screen**, not what the target is: the lines the float
--- holds right now, or the very picture drawn into it -- the crop of a zoomed
--- view, the page of a PDF as rendered, the screenshot of a link.
---
--- **A picture is never put on the clipboard as an image.** That would be a
--- branch per platform (`Set-Clipboard`, `wl-copy`, `xclip`, `osascript`),
--- each with its own failure, for something a path already does: the file is
--- copied out of this plugin's caches -- which sweep themselves -- into a
--- directory of its own, and its path goes into the registers. Paste it into
--- a file dialog, a command line or an attachment field.
---
--- The copies are swept like every other cache here, once per session, after
--- `KEEP_DAYS`.
---
---@see hover.init

local M = {}

local uv = vim.uv or vim.loop

---@internal
--- How long a copied picture is kept. Not a setting: a copy is taken to be
--- used now, and a week covers "the ticket I attach it to tomorrow".
local KEEP_DAYS = 7

---@type boolean Whether this session has already swept the directory.
local _swept = false

--- Where copied pictures go. Public for the specs.
---@return string
function M.dir()
  return vim.fn.stdpath("cache") .. "/hover.nvim/copies"
end

---@internal
--- Delete copies older than `KEEP_DAYS`, once per session, and only files in
--- this module's own directory.
---@return nil
local function sweep()
  if _swept then
    return
  end
  _swept = true
  local dir = M.dir()
  if not uv.fs_stat(dir) then
    return
  end
  local ok, entries = pcall(vim.fn.readdir, dir)
  if not ok or type(entries) ~= "table" then
    return
  end
  local cutoff = os.time() - KEEP_DAYS * 24 * 60 * 60
  for _, name in ipairs(entries) do
    local file = dir .. "/" .. name
    local st = uv.fs_stat(file)
    if st and st.type == "file" and st.mtime and st.mtime.sec < cutoff then
      pcall(os.remove, file)
    end
  end
end

--- The float's lines as one text, without the blank lines a preview pads its
--- end with, and without the marker a truncated preview ends on (`…`, or
--- `… (N entries)` under a directory): those say "there is more", they are
--- not part of what is there.
---@param lines string[]
---@return string text
---@return integer count Lines in `text`.
function M.text(lines)
  local last = #lines
  while last > 0 do
    local line = vim.trim(lines[last])
    if line == "" or line == "…" or line:sub(1, #"… (") == "… (" then
      last = last - 1
    else
      break
    end
  end
  local out = {}
  for i = 1, last do
    out[i] = lines[i]
  end
  return table.concat(out, "\n"), last
end

--- A name for the copy of `source`: what the hover was about, when that says
--- something, and the time, so two copies of one picture never collide.
---
--- A URL loses its query, its fragment and any `user:pw@` before a name is
--- taken from it -- the name ends up in the registers. A local path keeps a
--- `#`, which is an ordinary character in a filename.
---@param source string The picture on screen.
---@param hint string|nil A path or URL the picture belongs to.
---@param stamp string
---@return string
local function name_for(source, hint, stamp)
  local ext = source:match("%.(%w+)$") or "png"
  local base = ""
  if type(hint) == "string" and hint ~= "" then
    local h = hint
    if h:match("^%a[%w+.-]*://") then
      h = h:gsub("^(%a[%w+.-]*://)[^/@]*@", "%1"):gsub("[?#].*$", "")
    end
    base = h:gsub("[/]+$", ""):match("([^/]+)$") or ""
    base = base:gsub("%.%w+$", ""):gsub("[^%w%-_.]", "_"):sub(1, 60)
  end
  if base == "" then
    base = "hover"
  end
  return ("%s-%s.%s"):format(base, stamp, ext:lower())
end

--- Copy the picture on screen into `M.dir()`.
---
--- **The copy's clock is set to now.** `fs_copyfile` keeps the source's
--- mtime (`CopyFileW` on Windows, `clonefile` on macOS), and the sweep reads
--- the mtime: a picture from 2023 would have been copied as a week-old file
--- and deleted by the next session, with its path still in the clipboard.
---@param source string The file drawn into the float.
---@param hint string|nil A path or URL the picture belongs to, for the name.
---@return string|nil path
---@return string|nil err
function M.picture(source, hint)
  if type(source) ~= "string" or not uv.fs_stat(source) then
    return nil, "the picture on screen is no longer on disk"
  end
  sweep()
  local dir = M.dir()
  local made, mkdir_err = pcall(vim.fn.mkdir, dir, "p", "0700")
  if not made then
    return nil, "could not make " .. dir .. ": " .. tostring(mkdir_err)
  end
  local name = name_for(source, hint, os.date("%Y%m%d-%H%M%S"))
  local dest = dir .. "/" .. name
  local n = 1
  while uv.fs_stat(dest) do
    n = n + 1
    dest = dir .. "/" .. (name:gsub("(%.%w+)$", "-" .. n .. "%1"))
  end
  local ok, err = uv.fs_copyfile(source, dest)
  if not ok then
    return nil, "could not copy the picture: " .. tostring(err)
  end
  local now = os.time()
  pcall(uv.fs_utime, dest, now, now)
  return dest, nil
end

--- Put `text` into the unnamed register and onto the clipboard.
---
--- The unnamed register always takes it; the clipboard is lib.nvim's, which
--- checks that the write actually happened rather than trusting `setreg`.
---
--- **The clipboard is written last, and a linewise text ends in a newline
--- there.** A clipboard provider keeps no register type: with
--- `clipboard=unnamedplus` the `"` register *is* the clipboard, and `p` after
--- a linewise copy pasted the lines into the middle of the current one.
---@param text string
---@param linewise boolean
---@return boolean clipboard Whether the clipboard took it too.
function M.put(text, linewise)
  vim.fn.setreg('"', text, linewise and "l" or "v")
  local ok, copy = pcall(require, "lib.nvim.cross.copy_to_clipboard")
  if not ok or type(copy) ~= "function" then
    return false
  end
  local ok_copy, took = pcall(copy, linewise and (text .. "\n") or text)
  return ok_copy and took == true
end

--- Take what a float shows, and say in one line what was taken.
---
--- A picture wins over text: a drawn hover's buffer is blank lines sized to
--- the picture, and copying those would be copying the frame.
---
--- `refused` is the hover's own reason it has nothing to take -- a video
--- playing (the buffer holds block characters, the picture is in extmarks),
--- a placeholder still rendering -- and is said instead of copying.
---@param view { image_path?: string, lines?: string[], hint?: string, refused?: string }
---@return boolean ok
---@return string message
function M.take(view)
  if type(view.refused) == "string" then
    return false, view.refused
  end
  if type(view.image_path) == "string" and view.image_path ~= "" then
    local path, err = M.picture(view.image_path, view.hint)
    if not path then
      return false, err or "could not copy the picture"
    end
    local clip = M.put(path, false)
    return true,
      ("copied the picture on screen to %s (path in %s)"):format(
        path,
        clip and "the register and the clipboard" or "the unnamed register"
      )
  end
  local text, count = M.text(view.lines or {})
  if count == 0 then
    return false, "nothing to copy in this hover"
  end
  local clip = M.put(text, true)
  return true,
    ("copied %d line(s) to %s"):format(
      count,
      clip and "the register and the clipboard" or "the unnamed register"
    )
end

--- Forget the session's sweep. For the specs.
---@return nil
function M.reset()
  _swept = false
end

return M
