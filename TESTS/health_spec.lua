---@diagnostic disable: need-check-nil, duplicate-set-field
-- The test body is the guard; see the note in TESTS/bare_path_spec.lua
-- (`LLS-42`).

-- TESTS/health_spec.lua -- `:checkhealth hover`, and the one bug pattern a
-- cross-repo campaign keeps finding elsewhere: a "dependency X is missing"
-- branch that goes on to call further into X anyway, crashing instead of
-- degrading to the warning it just printed.
--
-- `hover.health` had no spec at all before this file, despite being the
-- single largest branch surface in the plugin outside `init.lua`. What makes
-- it worth pinning rather than trusting by inspection: `M.check()` is the
-- *only* entry point Neovim ever calls (`:checkhealth` invokes it directly),
-- and every `pcall(require, ...)` inside it exists specifically so a missing
-- dependency degrades instead of throwing -- which is exactly the property
-- that must be exercised, not just read.
--
-- `vim.health` is stubbed with a recorder rather than left real: the point
-- is not what a health buffer renders, it is which of `.ok`/`.warn`/`.error`/
-- `.info` fired, and in what order relative to `.start`. `require(...)` for
-- a module this plugin only *optionally* depends on is made to fail by
-- clearing `package.loaded` and installing a throwing `package.preload`
-- entry -- `package.loaded[name] = false` would not do it: `require` returns
-- a cached value, even `false`, without re-running the loader, so
-- `pcall(require, ...)` would still report success.
--
-- **The recorder patches `vim.health`'s own fields, not the `vim.health`
-- global itself.** `hover.health` binds `local health = vim.health` once, at
-- module load time -- reassigning `vim.health = fake` afterwards leaves that
-- local pointing at the real table, and every call in this spec would then
-- run the real `vim.health.start`, which throws outside a real `:checkhealth`
-- buffer. Overwriting the real table's fields is visible through the
-- already-captured reference, the same way `TESTS/bare_git_spec.lua` patches
-- `vim.system` itself rather than a copy of it.

local config = require("hover.config")
local health = require("hover.health")

---@return table calls
---@return fun() restore
local function fake_health()
  local calls = { start = {}, ok = {}, warn = {}, error = {}, info = {} }
  local real = {
    start = vim.health.start,
    ok = vim.health.ok,
    warn = vim.health.warn,
    error = vim.health.error,
    info = vim.health.info,
  }
  vim.health.start = function(name)
    calls.start[#calls.start + 1] = name
  end
  vim.health.ok = function(msg)
    calls.ok[#calls.ok + 1] = msg
  end
  vim.health.warn = function(msg, advice)
    calls.warn[#calls.warn + 1] = { msg = msg, advice = advice }
  end
  vim.health.error = function(msg, advice)
    calls.error[#calls.error + 1] = { msg = msg, advice = advice }
  end
  vim.health.info = function(msg)
    calls.info[#calls.info + 1] = msg
  end
  local function restore()
    vim.health.start = real.start
    vim.health.ok = real.ok
    vim.health.warn = real.warn
    vim.health.error = real.error
    vim.health.info = real.info
  end
  return calls, restore
end

---@param list table list of strings, or of `{ msg = string }` tables
---@param needle string
---@return boolean
local function any_contains(list, needle)
  for _, entry in ipairs(list) do
    local msg = type(entry) == "table" and entry.msg or entry
    if type(msg) == "string" and msg:find(needle, 1, true) then
      return true
    end
  end
  return false
end

--- Run `fn` with `require(name)` made to fail, as if the module were not
--- installed at all -- not merely absent from `package.loaded`.
---@param name string
---@param fn fun()
local function without_module(name, fn)
  local had_loaded = package.loaded[name] ~= nil
  local prev_loaded = package.loaded[name]
  local prev_preload = package.preload[name]
  package.loaded[name] = nil
  package.preload[name] = function()
    error(("%s not found (stubbed missing for a test)"):format(name))
  end

  local ok, err = pcall(fn)

  package.preload[name] = prev_preload
  package.loaded[name] = had_loaded and prev_loaded or nil

  if not ok then
    error(err, 0)
  end
end

describe("hover.health, the hard dependency", function()
  after_each(function()
    config.reset()
  end)

  it(
    "reports one error and returns -- never calling into the dependency it just reported missing",
    function()
      local calls, restore = fake_health()

      -- The property under test: `M.check()` itself must not raise. A crash
      -- here is exactly what the campaign's bug pattern (a) looks like --
      -- the "missing" branch reaching further into the thing it just said
      -- was missing.
      local ok = pcall(without_module, "lib.nvim.notify", function()
        health.check()
      end)
      restore()

      assert.is_true(ok, "M.check() raised instead of degrading")
      assert.equals(1, #calls.start, "something ran after the hard dependency was reported missing")
      assert.equals("hover.nvim", calls.start[1])
      assert.equals(1, #calls.error)
      assert.is_truthy(calls.error[1].msg:find("lib.nvim: not found", 1, true))
      assert.equals(0, #calls.ok, "nothing should have reached an ok() with lib.nvim missing")
      assert.equals(0, #calls.warn, "nothing should have reached a warn() with lib.nvim missing")
    end
  )

  it("warns, not errors, when lib.nvim is present but one used submodule is not", function()
    local calls, restore = fake_health()

    local ok = pcall(without_module, "lib.nvim.debounce", function()
      health.check()
    end)
    restore()

    assert.is_true(ok, "M.check() raised on a partial lib.nvim")
    assert.equals(0, #calls.error, "a partial install is a warning, not an error")
    assert.is_true(
      any_contains(calls.warn, "lib.nvim.debounce"),
      "the missing module was not named"
    )
    -- And configuration/contributors/external-tools still ran afterwards --
    -- a partial lib.nvim degrades one line, it does not stop the report.
    assert.is_true(#calls.start >= 4, "the report stopped after the partial-lib.nvim warning")
  end)

  it(
    "reports lib.nvim fully available when every module this plugin uses is really there",
    function()
      -- Unstubbed: this environment's own lib.nvim sibling checkout is the
      -- fixture, the same one the rest of this suite already depends on to
      -- run at all.
      local calls, restore = fake_health()

      local ok = pcall(health.check)
      restore()

      assert.is_true(ok)
      assert.is_true(any_contains(calls.ok, "lib.nvim: available"))
    end
  )
end)

describe("hover.health, configuration diagnostics", function()
  local real_mouse

  before_each(function()
    config.reset()
    real_mouse = vim.o.mouse
  end)

  after_each(function()
    vim.o.mouse = real_mouse
    config.reset()
  end)

  ---@return table calls
  local function run()
    local calls, restore = fake_health()
    local ok = pcall(health.check)
    restore()
    assert.is_true(ok, "M.check() raised")
    return calls
  end

  it("warns when mode is off, and says nothing hovers", function()
    config.setup({ mode = "off" })
    local calls = run()
    assert.is_true(any_contains(calls.warn, "mode: off"))
  end)

  it("reports the mode with ok() when it is not off", function()
    config.setup({ mode = "auto" })
    local calls = run()
    assert.is_true(any_contains(calls.ok, "mode: auto"))
  end)

  it("warns when auto_hover opens nothing by itself", function()
    -- `{}` merges onto the (non-empty) DEFAULTS.auto_hover key by key and
    -- changes nothing; the boolean form is what turns every type off at
    -- once, per `auto_hover_for`'s own `type(auto) == "boolean"` branch.
    config.setup({ auto_hover = false })
    local calls = run()
    assert.is_true(any_contains(calls.warn, "auto_hover: nothing opens by itself"))
  end)

  it("warns about manual mode with no key bound to show a hover", function()
    config.setup({ mode = "manual", keymaps = { show = "" } })
    local calls = run()
    assert.is_true(any_contains(calls.warn, "manual mode with no key bound"))
  end)

  it("does not warn about manual mode once a show key is bound", function()
    config.setup({ mode = "manual", keymaps = { show = "<leader>k" } })
    local calls = run()
    assert.is_false(any_contains(calls.warn, "manual mode with no key bound"))
  end)

  it("warns when persist is on but lib.nvim.cache.disk cannot be reached", function()
    config.setup({ persist = true })
    local calls, restore = fake_health()
    local ok = pcall(without_module, "lib.nvim.cache.disk", function()
      health.check()
    end)
    restore()
    assert.is_true(ok, "M.check() raised instead of degrading persist")
    assert.is_true(any_contains(calls.warn, "lib.nvim.cache.disk is not there"))
  end)

  it("warns when page screenshots are on and no browser is found", function()
    config.setup({ links = { web = true, shot = { enabled = true } } })
    local real_shot = package.loaded["hover.preview.shot"]
    package.loaded["hover.preview.shot"] = {
      browser = function()
        return nil
      end,
    }
    local calls = run()
    package.loaded["hover.preview.shot"] = real_shot
    assert.is_true(any_contains(calls.warn, "no headless browser was found"))
  end)

  it(
    "reports a browser found off PATH as reconciled, not contradicting the tools section",
    function()
      config.setup({ links = { web = true, shot = { enabled = true } } })
      local real_shot = package.loaded["hover.preview.shot"]
      package.loaded["hover.preview.shot"] = {
        browser = function()
          return [[C:\Program Files\Chrome\chrome.exe]]
        end,
      }
      local calls = run()
      package.loaded["hover.preview.shot"] = real_shot
      assert.is_true(any_contains(calls.ok, "found off PATH"))
    end
  )

  it("warns when page screenshots are on but images are switched off", function()
    -- The config key is `inline_images`, not `images` -- `images` is only
    -- the switch's *name* (`:Hover images off`); `M.images_enabled()` itself
    -- reads `inline_images`.
    config.setup({ links = { web = true, shot = { enabled = true } }, inline_images = false })
    local real_shot = package.loaded["hover.preview.shot"]
    package.loaded["hover.preview.shot"] = {
      browser = function()
        return "chrome"
      end,
    }
    local calls = run()
    package.loaded["hover.preview.shot"] = real_shot
    assert.is_true(any_contains(calls.warn, "pictures are switched off"))
  end)

  it("warns when the resize wheel is bound but 'mouse' is empty", function()
    vim.o.mouse = ""
    config.reset() -- resize_keys.wheel_* are on by default
    local calls = run()
    assert.is_true(any_contains(calls.warn, "no wheel event arrives"))
  end)

  it("does not warn about the wheel once 'mouse' is set", function()
    vim.o.mouse = "a"
    config.reset()
    local calls = run()
    assert.is_false(any_contains(calls.warn, "no wheel event arrives"))
  end)

  it("warns when a zoom key is shadowed by a resize key bound to the same lhs", function()
    config.setup({ zoom_keys = { into = { "+" } } }) -- resize_keys.larger defaults to "+"
    local calls = run()
    assert.is_true(any_contains(calls.warn, "is also a resize key"))
  end)

  it("warns when every preview class is switched off", function()
    config.setup({
      links = false,
      paths = false,
      positions = false,
      -- The "images" switch reads `inline_images`, a sibling of the three
      -- above rather than a child of any of them -- left on, it alone would
      -- keep `any` true and the warning would never fire.
      inline_images = false,
    })
    local calls = run()
    assert.is_true(any_contains(calls.warn, "every preview class is switched off"))
  end)

  it(
    "reports a code-taught capture family as a warning, since it can only narrow the feature",
    function()
      config.setup({ paths = { scope = { code = { "comment" } } } })
      local calls = run()
      assert.is_true(any_contains(calls.warn, "taught as code"))
    end
  )

  it("reports a prose-taught capture family as info, not a warning", function()
    config.setup({ paths = { scope = { prose = { "comment" } } } })
    local calls = run()
    assert.is_true(any_contains(calls.info, "taught as prose"))
    assert.is_false(any_contains(calls.warn, "taught as prose"))
  end)
end)

describe("hover.health, optional contributors (the soft() helper)", function()
  before_each(function()
    config.reset()
  end)

  after_each(function()
    config.reset()
    package.loaded["images.info"] = nil
  end)

  it(
    "reports info, not warn or error, for an optional dependency that is simply not installed",
    function()
      local calls, restore = fake_health()
      local ok = pcall(without_module, "images.info", function()
        health.check()
      end)
      restore()
      assert.is_true(ok)
      assert.is_true(any_contains(calls.info, "images.info: not installed"))
      assert.is_false(any_contains(calls.warn, "images.info"))
      assert.is_false(any_contains(calls.error, "images.info"))
    end
  )

  it(
    "warns, rather than silently degrading, when a module is present but too old to have the entry point used",
    function()
      package.loaded["images.info"] = { some_other_field = true } -- no .collect
      local calls, restore = fake_health()
      local ok = pcall(health.check)
      restore()
      assert.is_true(ok)
      package.loaded["images.info"] = nil
      assert.is_true(any_contains(calls.warn, "images.info.collect is missing"))
    end
  )

  it("reports ok when the module is present with the entry point this plugin calls", function()
    package.loaded["images.info"] = { collect = function() end }
    local calls, restore = fake_health()
    local ok = pcall(health.check)
    restore()
    assert.is_true(ok)
    package.loaded["images.info"] = nil
    assert.is_true(any_contains(calls.ok, "images.info: available"))
  end)
end)
