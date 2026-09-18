---@diagnostic disable: need-check-nil, duplicate-set-field
-- The test body is the guard; see the note in TESTS/bare_path_spec.lua
-- (`LLS-42`).

-- TESTS/git_spec.lua -- `hover.preview.git`, the two git calls behind an
-- object id, and the async/sync split around them.
--
-- Neither git call is a network request, and both go through `vim.system`,
-- which is a Neovim global rather than a `require()` upvalue -- so, per this
-- campaign's own convention, it is monkeypatched directly, the same way
-- `TESTS/bare_git_spec.lua` and `TESTS/external_spec.lua` already do. This
-- module had no dedicated spec before this file: `bare_git_spec.lua` covers
-- the shape test and the force gate, never the two `git` subprocess calls
-- or the output shaping around them.
--
-- Two behaviours worth pinning specifically:
--
--   1. **The result comes back through `wait()`, not the handle.** The
--      module doc calls this out explicitly (`wait()` *returns* the
--      completed object; the handle carries no `code` of its own) -- getting
--      this backwards would make every existing object read as "no such
--      object", silently.
--   2. **A synchronous return and an async `on_result` must never both
--      fire for the same outcome.** The placeholder is returned only when a
--      `git show` was actually started in the background.

local git = require("hover.preview.git")

describe("hover.preview.git.preview", function()
  local real_system

  before_each(function()
    real_system = vim.system
  end)

  after_each(function()
    vim.system = real_system
  end)

  it("answers synchronously that git is not available when the call itself cannot start", function()
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.system = function()
      error("git: command not found")
    end

    local content = git.preview({ raw = "deadbeef" }, { max_lines = 20 }, function() end, 0)

    assert.is_truthy(table.concat(content.lines, "\n"):find("git is not available", 1, true))
    assert.equals("deadbeef", content.title)
    assert.is_nil(content.pending)
  end)

  it("reads the exit code off wait()'s return value, not off the handle", function()
    local seen_cwd
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.system = function(argv, opts, cb)
      if argv[2] == "cat-file" then
        assert.equals("git", argv[1])
        seen_cwd = opts.cwd
        -- A handle with no `code` field of its own -- exactly the shape
        -- that would make `done.code` (read off the handle) always compare
        -- unequal to 0, if the module ever regressed to reading it there
        -- instead of off `wait()`'s return.
        return {
          wait = function()
            return { code = 0, signal = 0 }
          end,
        }
      end
      assert.equals("show", argv[2])
      -- `git show` is asked for next, and left pending: the point of this
      -- spec is the synchronous return value alone.
      return true
    end

    local content = git.preview({ raw = "cafef00d" }, { max_lines = 20 }, function() end, 0)

    assert.is_true(content.pending)
    assert.is_truthy(table.concat(content.lines, "\n"):find("reading the object", 1, true))
    assert.is_string(seen_cwd)
  end)

  it("reports 'no such object' by basename when cat-file exits non-zero", function()
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.system = function(argv, opts)
      assert.equals("cat-file", argv[2])
      return {
        wait = function()
          return { code = 1 }
        end,
      }
    end

    local api = vim.api
    local buf = api.nvim_create_buf(false, true)
    api.nvim_buf_set_name(buf, vim.fn.tempname() .. "/repo/file.lua")
    -- The directory need not exist for repo_dir's dirname split alone.

    local content = git.preview({ raw = "0000000" }, { max_lines = 20 }, function() end, buf)

    assert.is_nil(content.pending, "a definite miss must not be reported as in flight")
    assert.is_truthy(table.concat(content.lines, "\n"):find("no such object in", 1, true))
    assert.equals("0000000", content.title)

    pcall(api.nvim_buf_delete, buf, { force = true })
  end)

  it("never starts 'git show' once cat-file has said the object does not exist", function()
    local show_started = false
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.system = function(argv)
      if argv[2] == "show" then
        show_started = true
      end
      return {
        wait = function()
          return { code = 1 }
        end,
      }
    end

    git.preview({ raw = "0000000" }, { max_lines = 20 }, function() end, 0)

    assert.is_false(show_started)
  end)

  it(
    "delivers the show output through on_result, capped at max_lines with no trailing blank",
    function()
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.system = function(argv, opts, cb)
        if argv[2] == "cat-file" then
          return {
            wait = function()
              return { code = 0 }
            end,
          }
        end
        assert.equals("show", argv[2])
        -- `out.stdout` ends with the newline `git show` always writes; the
        -- module must not hand that back as a blank final line.
        local stdout = ""
        for i = 1, 10 do
          stdout = stdout .. ("line %d\n"):format(i)
        end
        vim.schedule(function()
          cb({ code = 0, stdout = stdout })
        end)
        return true
      end

      local result
      git.preview({ raw = "cafef00d" }, { max_lines = 3 }, function(content)
        result = content
      end, 0)

      vim.wait(500, function()
        return result ~= nil
      end, 10)

      assert.is_not_nil(result, "on_result was never called")
      assert.equals(3, #result.lines)
      assert.equals("line 1", result.lines[1])
      assert.equals("line 3", result.lines[3])
    end
  )

  it("reports 'git show failed' through on_result when show exits non-zero", function()
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.system = function(argv, opts, cb)
      if argv[2] == "cat-file" then
        return {
          wait = function()
            return { code = 0 }
          end,
        }
      end
      vim.schedule(function()
        cb({ code = 1, stdout = "" })
      end)
      return true
    end

    local result
    git.preview({ raw = "cafef00d" }, { max_lines = 20 }, function(content)
      result = content
    end, 0)

    vim.wait(500, function()
      return result ~= nil
    end, 10)

    assert.is_not_nil(result)
    assert.is_truthy(table.concat(result.lines, "\n"):find("git show failed", 1, true))
  end)

  it("falls back to (no output) when show succeeds with nothing to show", function()
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.system = function(argv, opts, cb)
      if argv[2] == "cat-file" then
        return {
          wait = function()
            return { code = 0 }
          end,
        }
      end
      vim.schedule(function()
        cb({ code = 0, stdout = "\n" })
      end)
      return true
    end

    local result
    git.preview({ raw = "cafef00d" }, { max_lines = 20 }, function(content)
      result = content
    end, 0)

    vim.wait(500, function()
      return result ~= nil
    end, 10)

    assert.is_not_nil(result)
    assert.same({ "(no output)" }, result.lines)
  end)

  it("runs git in the buffer's own directory, not Neovim's cwd", function()
    local api = vim.api
    local seen_cwd
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.system = function(argv, opts)
      seen_cwd = opts.cwd
      return {
        wait = function()
          return { code = 1 }
        end,
      }
    end

    local dir = vim.fs.normalize(vim.fn.tempname())
    local buf = api.nvim_create_buf(false, true)
    api.nvim_buf_set_name(buf, dir .. "/sub/file.lua")

    git.preview({ raw = "0000000" }, { max_lines = 20 }, function() end, buf)

    assert.equals(vim.fs.dirname(dir .. "/sub/file.lua"), seen_cwd)
    pcall(api.nvim_buf_delete, buf, { force = true })
  end)

  it("falls back to the process cwd for a buffer with no file name", function()
    local api = vim.api
    local seen_cwd
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.system = function(argv, opts)
      seen_cwd = opts.cwd
      return {
        wait = function()
          return { code = 1 }
        end,
      }
    end

    local buf = api.nvim_create_buf(false, true) -- unnamed
    git.preview({ raw = "0000000" }, { max_lines = 20 }, function() end, buf)

    assert.equals(vim.uv.cwd(), seen_cwd)
    pcall(api.nvim_buf_delete, buf, { force = true })
  end)
end)
