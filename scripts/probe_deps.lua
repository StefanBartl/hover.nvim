-- scripts/probe_deps.lua -- how a probe script finds the plugins it needs.
--
-- Shared by `scripts/onrequest_probe.lua` and `scripts/pdfzoom_probe.lua`,
-- which both run outside the test harness and therefore outside
-- `scripts/minimal_init.lua`. Three candidates, in descending order of
-- explicitness: an environment variable, a `.deps/<name>` checkout, and a
-- sibling directory -- the same order and the same reasoning as
-- `minimal_init.lua`, which cannot be reused here because it also brings up
-- plenary and a runtimepath a probe has no use for.
--
-- **Built with explicit indices, not a `{a, b, c}` literal**, and that is the
-- whole reason this file exists rather than a second copy of five lines. The
-- environment variable is `nil` whenever it is unset -- the normal case, since
-- the sibling layout is what a development machine has -- and a table literal
-- with `nil` in its first slot makes `ipairs` stop immediately, silently
-- skipping every candidate after it. `minimal_init.lua` had exactly that hole
-- and it cost three defects hiding behind one plausible-looking skip
-- (`ade6c1f`); the copy in `onrequest_probe.lua` still had it when this file
-- was written, which is the fourth time this class has turned up here.

local M = {}

--- Put `name` on the runtimepath if `marker` cannot already be required.
---@param env_var string Environment variable naming the checkout, if set
---@param name string Repository directory name
---@param marker string Module `require()`d to confirm the directory is right
---@param who string Script name, for the failure message
---@return boolean found
function M.add(env_var, name, marker, who)
  if pcall(require, marker) then
    return true
  end

  local candidates = {}
  local from_env = vim.env[env_var]
  if from_env and from_env ~= "" then
    candidates[#candidates + 1] = from_env
  end
  candidates[#candidates + 1] = vim.fn.getcwd() .. "/.deps/" .. name
  candidates[#candidates + 1] = vim.fs.dirname(vim.fn.getcwd()) .. "/" .. name

  for _, dir in ipairs(candidates) do
    if vim.fn.isdirectory(dir) == 1 then
      vim.opt.rtp:append(dir)
      if pcall(require, marker) then
        return true
      end
    end
  end

  io.stderr:write(
    ("%s: %s not found. Set %s, clone it to .deps/%s, or place it beside this repo.\n"):format(
      who,
      name,
      env_var,
      name
    )
  )
  return false
end

return M
