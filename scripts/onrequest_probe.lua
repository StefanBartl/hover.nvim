-- scripts/onrequest_probe.lua -- the `on_request` path, against a real engine.
--
-- **Run from THIS repository's root** -- hover.nvim's checkout, not your
-- Neovim configuration directory. `-l` resolves the script path relative to
-- the working directory, and `vim.opt.rtp:append(vim.fn.getcwd())` below puts
-- *this* plugin on the runtime path, so anywhere else the answer is
-- `E5112: cannot open scripts/onrequest_probe.lua`.
--
--   cd /path/to/hover.nvim
--   nvim --clean --headless -l scripts/onrequest_probe.lua
--   nvim --clean --headless -l scripts/onrequest_probe.lua docker
--
-- **Why this is a script and not a spec.** A contribution marked `on_request`
-- is skipped by the automatic trigger and asked only for an explicit request.
-- The only shipped one is sandbox.nvim's container-image preview, and
-- answering it costs a container engine -- which no CI has. So the one thing
-- nothing automated can confirm is that a force-only contribution reaches the
-- screen at all. That is not hypothetical: `836a15a` was exactly a registered
-- position preview that no route could reach, and a live run found it, not
-- the suite.
--
-- This exists so that run is repeatable rather than rebuilt each time. It
-- asserts nothing and fails nothing; it prints what happened, and reading it
-- is the check.
--
-- With no argument it uses whatever sandbox.nvim's own detection picks, which
-- is the case that matters -- that is what a user gets. An argument forces one
-- engine, which is how a detected engine that cannot answer is told apart
-- from a path that is broken.
--
-- Dependencies are found the way scripts/minimal_init.lua finds them: an env
-- var, a `.deps/<name>` checkout, or a sibling directory.

vim.opt.rtp:append(vim.fn.getcwd())

-- The dependency probe lives in `scripts/probe_deps.lua`: it was written
-- here first, as a `{ vim.env[...], ... }` literal, and an unset variable put
-- a `nil` in slot 1 -- which makes `ipairs` stop before trying the `.deps`
-- checkout or the sibling directory. That is the same hole `ade6c1f` closed
-- in `minimal_init.lua`, still open in this copy, which is why there is no
-- copy any more.
local deps = dofile(vim.fn.getcwd() .. "/scripts/probe_deps.lua")

---@param env_var string
---@param name string
---@param marker string module `require()`d to confirm the directory is right
---@return boolean
local function add_dep(env_var, name, marker)
  return deps.add(env_var, name, marker, "scripts/onrequest_probe.lua")
end

if not add_dep("LIB_NVIM_DIR", "lib.nvim", "lib.nvim.notify") then
  os.exit(1)
end
if not add_dep("SANDBOX_NVIM_DIR", "sandbox.nvim", "sandbox") then
  os.exit(1)
end

local forced = (_G.arg or {})[1]

local out = {}
local function say(fmt, ...)
  out[#out + 1] = select("#", ...) > 0 and fmt:format(...) or fmt
end

-- hover.nvim first: `sandbox.setup` registers into its registry, so there has
-- to be one to register with.
local hover = require("hover")
hover.setup({})

-- `sandbox.setup` is what picks the engine, and it is also what registers the
-- integration -- which is the route a real config takes. Calling
-- `sandbox.hover.setup()` directly instead would skip the engine choice, and
-- every row below would then decline for a reason that is not the one under
-- test.
local sandbox = require("sandbox")
sandbox.setup(forced and { engine = forced } or {})

-- ---------------------------------------------------------------------------
-- Count engine calls, without touching sandbox's own code.
--
-- The integration asks `sandbox.get_engine()` afresh for every ask, so
-- wrapping the accessor -- rather than the table it hands back -- is what
-- survives. The count is the evidence for its central claim: "not pulled" is
-- a complete answer and costs one call, a hit costs two.
-- ---------------------------------------------------------------------------
local calls = 0
local real_get_engine = sandbox.get_engine
sandbox.get_engine = function(...)
  local engine = real_get_engine(...)
  if type(engine) ~= "table" then
    return engine
  end
  local proxy = setmetatable({}, { __index = engine })
  for _, name in ipairs({ "list_images", "list_containers" }) do
    if type(engine[name]) == "function" then
      proxy[name] = function(...)
        calls = calls + 1
        return engine[name](...)
      end
    end
  end
  return proxy
end

say(
  "engine            : %s (%s)",
  tostring(sandbox.resolve_engine_name()),
  forced and "forced" or "detected"
)
say(
  "sandbox.hover     : %s",
  require("sandbox.hover").registered() and "registered" or "NOT REGISTERED"
)

-- Can that engine answer at all? Asked separately, and first: a decline looks
-- identical whether the reference is wrong or the daemon is down, and on a
-- machine whose detected engine is installed but stopped, every row below
-- declines for a reason that has nothing to do with hover.nvim.
do
  local t0 = vim.uv.hrtime()
  local ok, images = pcall(function()
    return real_get_engine().list_images()
  end)
  local ms = (vim.uv.hrtime() - t0) / 1e6
  if ok and type(images) == "table" then
    say("engine answers    : yes, %d image(s) in %.0f ms", #images, ms)
  else
    say("engine answers    : NO, after %.0f ms -- every row below declines for that reason", ms)
  end
end

for _, contributor in ipairs(require("hover.registry").contributors()) do
  say(
    "contributor       : %-14s positions=%d on_request=%d",
    contributor.name,
    contributor.positions,
    contributor.on_request
  )
end

-- ---------------------------------------------------------------------------
-- One line per case, and the cursor lands inside the reference.
-- ---------------------------------------------------------------------------
local LINES = {
  "FROM alpine:edge",
  "image: lazyvim_starter:latest",
  "FROM nginx:1.27-alpine",
  "-- see init.lua:42 for the rule",
}

local buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(buf, vim.fn.getcwd() .. "/probe.Dockerfile")
vim.api.nvim_buf_set_lines(buf, 0, -1, false, LINES)
local win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(win, buf)

--- The reference in a line, and a 0-based column *inside* it.
---
--- Inside, not at its first character: the integration walks outward from
--- wherever the cursor is, and starting at the edge would leave that walk
--- untested.
---@param text string
---@return string reference
---@return integer col
local function reference_in(text)
  local first, last = text:find("[%w_][%w%._%-/]*:[%w%._%-]+")
  if not first then
    return text, 0
  end
  return text:sub(first, last), first - 1 + 2
end

say("")
say("%-22s %-6s %8s %6s  %s", "reference", "auto", "forced", "calls", "first line of the float")
say(("-"):rep(92))

for row = 1, #LINES do
  local reference, col = reference_in(LINES[row])
  vim.api.nvim_win_set_cursor(win, { row, col })

  -- The automatic trigger has to stay quiet on every row: that is the whole
  -- of what `on_request` buys, and a regression in it is silent otherwise --
  -- it would arrive as a stutter nobody connects back to a container engine.
  calls = 0
  local auto = hover.show_position(buf, { force = false })
  local auto_calls = calls
  hover.hide()

  -- Keypress to finished float. `show_position` is what `:Hover show` routes
  -- to, and the presenting happens inside it, so this is the whole trip
  -- rather than just the ask.
  calls = 0
  local t0 = vim.uv.hrtime()
  local shown = hover.show_position(buf, { force = true })
  local ms = (vim.uv.hrtime() - t0) / 1e6

  -- Reading the float back is the difference between "the pipeline returned
  -- true" and "something arrived on screen", and `836a15a` sat exactly in the
  -- gap between those two.
  local first = "(nothing shown)"
  if shown then
    local ok, text = pcall(function()
      local float_win = require("hover.float").win()
      local float_buf = float_win and vim.api.nvim_win_get_buf(float_win)
      return float_buf and vim.api.nvim_buf_get_lines(float_buf, 0, 1, false)[1]
    end)
    first = (ok and text) or "(open, but its lines could not be read)"
  end
  hover.hide()

  say("%-22s %-6s %7.0fms %6d  %s", reference, auto and "SHOWN" or "quiet", ms, calls, first)
  if auto_calls > 0 then
    say(
      "  ! the automatic trigger made %d engine call(s) -- `on_request` is not honoured",
      auto_calls
    )
  end
end

say("")
say("Read it as: `auto` is `quiet` on every row -- that is the flag doing its")
say("job, and it is the column a regression would break silently. `forced` is")
say("what asking on purpose costs; `calls` is 2 for a pulled image, 1 for one")
say("that is not, and 0 when the reference was declined before any process")
say("started.")

io.stdout:write(table.concat(out, "\n"), "\n")
