---@module 'hover.preview.git'
---@brief What a commit did, for an object id under the cursor.
---@description
--- Two git calls, both on the far side of the force gate -- see
--- `hover.bare_git` for the 41 ms that put them there.
---
--- `cat-file -e` first, because "that hex string is not a commit here" is the
--- common answer and it must be a sentence rather than a failed `git show`
--- with whatever git writes to stderr. Then `show --stat`, which is the
--- summary a reader of a log actually wants: subject, author, date, and which
--- files moved.
---
--- **Asynchronous, and guarded like every other async preview here.** The
--- generation counter in `hover` drops a result whose target the cursor has
--- already left, and the `pending` badge appears only if the answer takes
--- longer than `placeholder_grace_ms` -- a placeholder that merely flickers
--- is worse than none.
---
--- **`cwd` is the buffer's directory, not Neovim's.** A log opened from
--- elsewhere still asks the repository the file belongs to, which is the
--- repository the ids in it came from. Without that, hovering a SHA in a
--- review of another project answers about the wrong history -- or worse,
--- answers.
---
---@see hover.bare_git

local M = {}

local api = vim.api

---@internal
--- The directory to run git in: the buffer's own, falling back to the cwd
--- for a buffer that has no file behind it.
---@param bufnr? integer
---@return string
local function repo_dir(bufnr)
  if bufnr and api.nvim_buf_is_valid(bufnr) then
    local name = api.nvim_buf_get_name(bufnr)
    if name ~= "" then
      return vim.fs.dirname(name)
    end
  end
  return vim.uv.cwd() or "."
end

---@internal
--- A short answer in the shape every preview here returns.
---@param lines string[]
---@param title string
---@return Hover.Content
local function content(lines, title)
  return { lines = lines, title = title }
end

--- Preview the object `target.raw` names.
---
--- Answers through `on_result`, always -- a hex string that is not an object
--- gets a sentence saying so, because someone who asked about it outright is
--- owed an answer rather than silence.
---@param target Hover.Target
---@param opts Hover.PreviewOpts
---@param on_result fun(content: Hover.Content|nil)
---@param bufnr? integer
---@return Hover.Content pending placeholder
function M.preview(target, opts, on_result, bufnr)
  local sha = target.raw
  local cwd = repo_dir(bufnr)
  local max = opts.max_lines or 20

  -- Argv arrays, never an interpolated shell string (`SEC-01`): `sha` comes
  -- from a buffer and is not this plugin's to trust, even after the shape
  -- test.
  local ok_exists, exists = pcall(vim.system, {
    "git",
    "cat-file",
    "-e",
    sha .. "^{object}",
  }, { cwd = cwd, text = true })

  -- Returned, not emitted. A synchronous answer is the return value here --
  -- `build_async` emits whatever comes back when it is not `pending`, so
  -- doing both would emit twice and the placeholder would win.
  if not ok_exists then
    return content({ "git is not available" }, sha:sub(1, 8))
  end

  -- `wait()` *returns* the completed object; the handle itself carries no
  -- `code`. Reading it off the handle answers nil, which compares unequal to
  -- 0 and turns every existing object into "no such object".
  local done = exists:wait()
  if type(done) ~= "table" or done.code ~= 0 then
    return content({ ("no such object in %s"):format(vim.fs.basename(cwd)) }, sha:sub(1, 8))
  end

  local ok_show = pcall(vim.system, {
    "git",
    "show",
    "--stat",
    "--no-color",
    "--date=short",
    sha,
  }, { cwd = cwd, text = true }, function(out)
    vim.schedule(function()
      if out.code ~= 0 then
        on_result(content({ "git show failed" }, sha:sub(1, 8)))
        return
      end
      local lines = {}
      for line in (out.stdout or ""):gmatch("([^\n]*)\n?") do
        if #lines >= max then
          break
        end
        lines[#lines + 1] = line
      end
      -- `gmatch` on a trailing newline yields one empty string at the end;
      -- a float should not open with a blank final line.
      while #lines > 0 and lines[#lines] == "" do
        lines[#lines] = nil
      end
      if #lines == 0 then
        lines = { "(no output)" }
      end
      on_result(content(lines, sha:sub(1, 8)))
    end)
  end)

  if not ok_show then
    return content({ "git show could not be started" }, sha:sub(1, 8))
  end

  return vim.tbl_extend("force", content({ "reading the object…" }, sha:sub(1, 8)), {
    pending = true,
  })
end

return M
