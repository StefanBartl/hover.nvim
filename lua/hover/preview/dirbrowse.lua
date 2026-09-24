---@module 'hover.preview.dirbrowse'
---@brief Directory entries as data: scan, sort, render.
---@description
--- Deliberately cut apart from everything stateful -- there is no selection,
--- no window, no keymap in here, only `Hover.DirEntry[]` in and lines out.
---
--- **That separation is not tidiness for its own sake.** The mini filetree a
--- directory hover now shows is the first thing this plugin needed that looks
--- like `filetree.nvim`'s job rather than hover.nvim's, and filetree.nvim has
--- no engine of its own to reuse today -- it is an adapter around neo-tree,
--- nvim-tree, oil and friends, none of which can be embedded in a float that
--- is `focusable = false` and vanishes on the next `CursorMoved`. So this
--- module is written as the seam a later extraction would cut along: pure
--- functions over a plain list of entries, nothing reaching into `hover.init`
--- or `hover.float`. `hover.init` owns the selection, the extmark, and which
--- window a file opens into -- state that belongs to *this* plugin's float,
--- not to directory scanning.
---@see hover.init

local M = {}

local uv = vim.uv or vim.loop

--- Scan `dir`'s immediate children, directories first, both groups
--- alphabetical by name -- the order the directory preview has always shown.
---@param dir string absolute directory path
---@return Hover.DirEntry[]|nil nil when the directory cannot be read
function M.scan(dir)
  local handle = uv.fs_scandir(dir)
  if not handle then
    return nil
  end

  local dirs, files = {}, {}
  while true do
    local name, kind = uv.fs_scandir_next(handle)
    if not name then
      break
    end
    local path = vim.fs.joinpath(dir, name)
    -- A symlink is reported as `kind == "link"`, whatever it points at --
    -- `is_dir` is now what decides an *action* (enter it vs. open it as a
    -- file), not only how a line is drawn, so a symlinked directory answering
    -- `false` here would try to `:edit` a directory instead of listing it.
    -- `fs_stat` follows the link; a broken one answers nil and falls back to
    -- "not a directory", which is the least-wrong guess for a target that
    -- cannot be resolved at all.
    local is_dir = kind == "directory"
    if kind == "link" then
      local stat = uv.fs_stat(path)
      is_dir = stat ~= nil and stat.type == "directory"
    end
    local entry = { name = name, path = path, is_dir = is_dir }
    if entry.is_dir then
      dirs[#dirs + 1] = entry
    else
      files[#files + 1] = entry
    end
  end

  local function by_name(a, b)
    return a.name < b.name
  end
  table.sort(dirs, by_name)
  table.sort(files, by_name)

  local out = {}
  for _, e in ipairs(dirs) do
    out[#out + 1] = e
  end
  for _, e in ipairs(files) do
    out[#out + 1] = e
  end
  return out
end

--- Render `entries` into display lines, one per entry, in the order given --
--- a directory gets a trailing `/`, a file does not. Truncation is the
--- caller's job: this never looks at how many there are, only at the ones
--- handed to it, so the line a reader clicks and the entry it resolves to are
--- always the same index.
---@param entries Hover.DirEntry[]
---@return string[]
function M.render(entries)
  local out = {}
  for i, e in ipairs(entries) do
    out[i] = e.is_dir and (e.name .. "/") or e.name
  end
  return out
end

--- Clamp a 1-based selection index into `[1, count]`.
---@param index integer|nil
---@param count integer
---@return integer|nil nil when `count` is 0 -- nothing to select
function M.clamp(index, count)
  if count <= 0 then
    return nil
  end
  return math.max(1, math.min(index or 1, count))
end

return M
