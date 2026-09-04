---@diagnostic disable: need-check-nil
-- The test body is the guard; see the note in TESTS/bare_path_spec.lua
-- (`LLS-42`).

-- TESTS/shot_spec.lua -- a hovered link rendered by a headless browser.
--
-- **What is pinned here is the gating and the protections, not the render.**
-- Whether Chrome produces a picture needs Chrome, a network and a terminal
-- that can draw one; that is evidence a person collects
-- (`docs/MANUAL-EVIDENCE.md`). What a run can check is everything that
-- decides whether a browser is started at all -- and every one of those is a
-- decision that costs seconds or a disclosure when it is wrong:
--
--   1. **Two gates, not one.** `shot` says a link *may* be rendered; `eager`
--      says the *trigger* may do it. `auto_hover.url` cannot express the
--      difference, because the text preview and the screenshot are the same
--      target type -- which is the whole reason the second switch exists.
--   2. **`shot` implies `web` and never `fetch`.** A fetch is one `curl` GET
--      with a 2 MB cap; a render executes the page. A reader who asked for a
--      status code must not get a browser.
--   3. **Nothing is started for a picture that cannot be drawn.** With no
--      image provider the render would be twenty seconds spent on a file
--      nobody will see, so the check comes *before* the browser rather than
--      after it.
--   4. **`requested` is remembered.** A screenshot asked for with
--      `:Hover show` has to still be a screenshot after `F`, and not fall
--      back to text because the second render came from a keypress.

local config = require("hover.config")
local switches = require("hover.switches")
local shot = require("hover.preview.shot")

describe("the screenshot switches", function()
  before_each(function()
    config.reset()
    shot.reset()
    vim.g.hover_disable = nil
  end)

  after_each(function()
    config.reset()
    shot.reset()
    vim.g.hover_disable = nil
  end)

  it("is reachable as `:Hover links web shot`, under web and not under fetch", function()
    assert.same({ "links", "web", "shot" }, switches.route("shot"))
    assert.same({ "links", "web", "shot", "eager" }, switches.route("eager"))
  end)

  it("turns web on with it, and leaves fetching alone", function()
    -- The category line: a render is not a louder fetch, so switching one on
    -- must not switch the other on. A reader who asked for a status code
    -- getting a browser is the failure this prevents.
    switches.set("shot", true, { silent = true })
    assert.is_true(config.web_enabled(), "a render with no float to show it in")
    assert.is_false(config.fetch_enabled(), "a render implied a fetch")
    assert.is_true(config.shot_enabled())
  end)

  it("turns the render on with the trigger, since one without the other says nothing", function()
    switches.set("eager", true, { silent = true })
    assert.is_true(config.shot_enabled())
    assert.is_true(config.shot_eager())
  end)

  it("keeps the trigger shut while only the render is on", function()
    switches.set("shot", true, { silent = true })
    assert.is_true(config.shot_enabled())
    assert.is_false(config.shot_eager(), "the trigger may start a browser unasked")
  end)

  it("silences the render when the level above goes off, without demoting it", function()
    switches.set("eager", true, { silent = true })
    switches.set("web", false, { silent = true })
    assert.is_false(config.shot_enabled())
    assert.is_false(config.shot_eager())

    switches.set("web", true, { silent = true })
    assert.is_true(config.shot_eager(), "turning the parent back on demoted the child")
  end)

  it("names the second gate when the type still does not open by itself", function()
    local report = switches.on_report("shot")
    assert.is_truthy(report:find("Hover auto url", 1, true))
  end)

  it("says out loud what the render does, since that is the whole disclosure", function()
    local spec = switches.spec("shot")
    assert.is_truthy(spec.on_msg:find("JavaScript", 1, true), "the announcement hides what runs")
  end)

  it("carries the whole configured shape into the preview options", function()
    -- The one table every previewer is threaded. A field that never arrives
    -- here is a setting that silently does nothing.
    config.setup({
      links = {
        shot = {
          enabled = true,
          eager = true,
          timeout_ms = 5,
          width = 11,
          height = 22,
          cache_days = 3,
          delay_ms = 44,
          command = "/nowhere/browser",
        },
        web = true,
      },
    })
    local opts = config.preview_opts()
    assert.is_true(opts.shot_enabled)
    assert.is_true(opts.shot_eager)
    assert.same(5, opts.shot_timeout_ms)
    assert.same(11, opts.shot_width)
    assert.same(22, opts.shot_height)
    assert.same(3, opts.shot_cache_days)
    assert.same(44, opts.shot_delay_ms)
    assert.same("/nowhere/browser", opts.shot_command)
  end)

  it("drops the preview cache when it is thrown, since it changes what a preview is", function()
    local cache = require("hover.cache")
    cache.put("k", { lines = { "old" } })
    switches.set("shot", true, { silent = true })
    assert.is_nil(cache.get("k"), "a cached text preview survived the switch to pictures")
  end)
end)

describe("hover.preview.shot", function()
  local target =
    { type = "url", raw = "https://example.com/page", url = "https://example.com/page" }

  before_each(function()
    config.reset()
    shot.reset()
  end)

  after_each(function()
    config.reset()
    shot.reset()
  end)

  ---@param overrides? table
  ---@return Hover.PreviewOpts
  local function opts(overrides)
    local o = config.preview_opts()
    for k, v in pairs(overrides or {}) do
      o[k] = v
    end
    return o
  end

  it("declines a scheme no browser can open, without looking for one", function()
    local content = shot.preview(
      { type = "url", raw = "mailto:a@b.c", url = "mailto:a@b.c" },
      opts(),
      function() end
    )
    assert.same({ "a@b.c" }, content.lines)
    assert.is_nil(content.pending, "a mailto: link was treated as something to render")
  end)

  it("says so rather than rendering when pictures are switched off", function()
    -- Before the browser, not after it: a render nothing can draw is twenty
    -- seconds spent on a file the reader will never see.
    local content = shot.preview(target, opts({ inline_images = false }), function() end)
    assert.is_truthy(table.concat(content.lines, "\n"):find("Hover images on", 1, true))
    assert.is_nil(content.pending)
  end)

  it("keeps the URL underneath every answer that is not a picture", function()
    -- The reader still gets what the offline preview would have said, so a
    -- refusal is never an empty float.
    local content = shot.preview(target, opts({ inline_images = false }), function() end)
    assert.is_truthy(vim.tbl_contains(content.lines, "example.com"))
  end)

  it("answers nothing cached for a page never rendered, and starts nothing to find out", function()
    -- `hover.zoom` asks this to decide whether a screenshot can be magnified.
    -- A question about capability must not have a twenty-second answer.
    assert.is_nil(shot.cached(target))
  end)

  it("answers nothing cached for a target that is not an http(s) link", function()
    assert.is_nil(shot.cached({ type = "url", raw = "mailto:a@b.c", url = "mailto:a@b.c" }))
    assert.is_nil(shot.cached({ type = "file", raw = "./x.txt", path = "/tmp/x.txt" }))
  end)

  it("takes a configured browser at its word, without searching", function()
    -- A search that overrode the setting would be unfixable from a config:
    -- the reader names one precisely because the search found the wrong one.
    assert.same("/nowhere/does-not-exist", shot.browser("/nowhere/does-not-exist"))
  end)

  it("searches when none is named, and answers nil rather than guessing", function()
    shot.forget_browser()
    local found = shot.browser(nil)
    -- Either a real browser on this machine or nothing -- both are correct
    -- answers, and neither may be a made-up path.
    if found ~= nil then
      assert.same(1, vim.fn.executable(found), ("%q is not executable"):format(found))
    end
  end)
end)

describe("what opens a browser, and what does not", function()
  -- The gating as `build` performs it, read off the same options the
  -- previewer is threaded. Written against `preview_opts` rather than by
  -- driving a real hover, because the branch under test is exactly the one
  -- that would otherwise start Chrome.

  before_each(function()
    config.reset()
  end)

  after_each(function()
    config.reset()
  end)

  ---@param o Hover.PreviewOpts
  ---@param requested boolean
  ---@return boolean
  local function renders(o, requested)
    -- The condition in `build`'s url branch, and the one thing this spec
    -- would rather not have as a second copy -- so it is written once here
    -- and the spec below holds the source against it.
    return o.shot_enabled == true and (o.shot_eager == true or requested)
  end

  it("matches the condition the source actually branches on", function()
    local source = assert(io.open(vim.fn.getcwd() .. "/lua/hover/init.lua", "r"))
    local text = source:read("*a")
    source:close()
    assert.is_truthy(
      text:find("opts.shot_enabled and (opts.shot_eager or opts.requested)", 1, true),
      "the url branch no longer gates on both switches plus the request"
    )
  end)

  it("renders nothing at all while the switch is off", function()
    local o = config.preview_opts()
    assert.is_false(renders(o, false))
    assert.is_false(renders(o, true), "an explicit request started a browser with the switch off")
  end)

  it("renders only for an explicit request while the trigger is not allowed", function()
    switches.set("shot", true, { silent = true })
    local o = config.preview_opts()
    assert.is_false(renders(o, false), "the trigger started a browser it was not allowed to")
    assert.is_true(renders(o, true))
  end)

  it("renders for the trigger once it is allowed", function()
    switches.set("eager", true, { silent = true })
    local o = config.preview_opts()
    assert.is_true(renders(o, false))
    assert.is_true(renders(o, true))
  end)
end)
