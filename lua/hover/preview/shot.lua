---@module 'hover.preview.shot'
---@brief A hovered link rendered by a headless browser, and drawn into the
---float like any other picture.
---@description
--- **This is a different category from `links.fetch`, not a louder setting of
--- it.** A fetch is one `curl` GET with a 2 MB cap: the page's markup arrives
--- as bytes and is read as text, and nothing in it ever runs. A screenshot
--- *executes* the page -- the site's own JavaScript, and every subresource it
--- asks for from whatever host it names. That is why `shot` implies `web` and
--- never `fetch`, why its own announcement says so out loud, and why the
--- automatic trigger is a second switch rather than the same one.
---
--- **Two protections that are not optional, both about the browser process.**
---
---  * **A throwaway profile.** Without `--user-data-dir` pointing somewhere
---    disposable, a headless Chrome can open the reader's *real* profile:
---    their cookies would go to the hovered host, and whatever they are
---    logged into would be rendered into the picture. The flag is the
---    difference between "render this page" and "render this page as me".
---  * **One process at a time, and a delay before it starts.** Measured
---    2026-09-04 on this machine, three runs against `about:blank` with no
---    network at all: **710, 715, 735 ms** for the browser start alone. A
---    real documentation page measured 3.9 s to 19.6 s -- the same URL, on
---    different runs, at both ends of that. Scrolling through a document made
---    of links must therefore not start one browser per link, so the
---    automatic path waits `shot.delay_ms` of stillness before committing,
---    and a request for another page kills the render still running.
---
--- **The cache is the same shape as `preview.office`'s and keyed
--- differently.** A converted document is keyed by path *and mtime*, so an
--- edited file converts again. A URL has no mtime this side of a request, so
--- the key is the URL plus the geometry it was captured at -- and a page that
--- has since changed answers with the old picture until `cache_days` expires
--- or the switch is thrown. That is a real trade rather than an oversight:
--- the alternative is a conditional request per hover, which is the cost this
--- whole module is arranged around.
---
--- Everything past the PNG is `preview.media`'s and unchanged: the canvas
--- sizing, the drawing, the crop that `>` performs, the panning. A screenshot
--- is a picture by the time anything is on screen.
---
---@see hover.preview.media
---@see hover.preview.url

local M = {}

local uv = vim.uv or vim.loop

---@type table<string, string> Rendered pages, keyed by URL and geometry.
local _shots = {}
---@type { key: string, handle: table }|nil The one render allowed to be running.
local _running = nil
---@type { key: string, timer: any }|nil A start the trigger has not committed to yet.
local _pending = nil
---@type boolean Whether this session has already swept the cache directory.
local _swept = false
---@type string|nil|false Resolved browser: a path, or `false` for "looked and found none".
local _browser = nil

---@internal
--- Executable names, in the order they are tried. Chrome and Chromium first:
--- the flags below are theirs, Edge merely happens to accept them.
---@type string[]
local NAMES = {
  "chrome",
  "google-chrome",
  "google-chrome-stable",
  "chromium",
  "chromium-browser",
  "brave",
  "msedge",
  "microsoft-edge",
}

---@internal
--- Where an installer puts one when it does not extend PATH.
---
--- **Measured rather than assumed, 2026-09-04:** on the Windows machine this
--- was built on, Chrome is installed at the first entry below and `chrome` is
--- on no PATH -- so a PATH-only search reports "no browser" on a machine with
--- a browser plainly on it. `docs/install.json` already documents the same
--- problem for `soffice`, which is how it was expected here.
---@return string[]
local function install_paths()
  local out = {}
  local function add(path)
    if type(path) == "string" and path ~= "" then
      out[#out + 1] = path
    end
  end

  if vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1 then
    local roots = {
      os.getenv("PROGRAMFILES"),
      os.getenv("ProgramFiles(x86)"),
      os.getenv("LOCALAPPDATA"),
    }
    local tails = {
      [[\Google\Chrome\Application\chrome.exe]],
      [[\Chromium\Application\chrome.exe]],
      [[\BraveSoftware\Brave-Browser\Application\brave.exe]],
      [[\Microsoft\Edge\Application\msedge.exe]],
    }
    for _, tail in ipairs(tails) do
      for _, root in ipairs(roots) do
        add(root and (root .. tail) or nil)
      end
    end
    return out
  end

  if vim.fn.has("mac") == 1 then
    add("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
    add("/Applications/Chromium.app/Contents/MacOS/Chromium")
    add("/Applications/Brave Browser.app/Contents/MacOS/Brave Browser")
    add("/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge")
    return out
  end

  add("/usr/bin/google-chrome")
  add("/usr/bin/chromium")
  add("/usr/bin/chromium-browser")
  add("/snap/bin/chromium")
  return out
end

--- The browser this would run, or nil when there is none.
---
--- Public because `:checkhealth hover` needs the same answer, and a second
--- search written there would be the hand-kept copy this repository keeps
--- finding stale. Resolved once per session and remembered -- including the
--- negative answer, so a machine with no browser does not stat six paths on
--- every hover.
---@param configured? string An explicit `links.shot.command`, which wins outright.
---@return string|nil
function M.browser(configured)
  if type(configured) == "string" and configured ~= "" then
    return configured
  end
  if _browser ~= nil then
    return _browser or nil
  end

  for _, name in ipairs(NAMES) do
    if vim.fn.executable(name) == 1 then
      _browser = name
      return name
    end
  end
  for _, path in ipairs(install_paths()) do
    if vim.fn.executable(path) == 1 then
      _browser = path
      return path
    end
  end

  _browser = false
  return nil
end

--- Forget the resolved browser, so the next question searches again. For the
--- test suite, and for a session that installed one meanwhile.
---@return nil
function M.forget_browser()
  _browser = nil
end

---@internal
--- Where rendered pages live. One place, so `sweep` and `output_path` cannot
--- disagree about which directory this plugin owns.
---@return string
local function cache_dir()
  return vim.fn.stdpath("cache") .. "/hover.nvim/shots"
end

---@internal
--- Identity of a render: the URL, and the geometry it was taken at. The
--- geometry is in it because a capture at another size is a different
--- picture, not a scaled one -- the page lays itself out against the
--- viewport.
---@param url string
---@param opts Hover.PreviewOpts
---@return string
local function key_for(url, opts)
  return ("%s %dx%d"):format(url, opts.shot_width or 1280, opts.shot_height or 900)
end

---@internal
--- Where the PNG goes. Named after the host (so a stray file in the cache
--- directory is identifiable) plus a digest of the key (so two pages on one
--- host, and two geometries of one page, do not collide).
---@param url string
---@param key string
---@return string
local function output_path(url, key)
  local dir = cache_dir()
  vim.fn.mkdir(dir, "p")
  local host = (url:match("^https?://([^/]+)") or "page"):gsub("[^%w%-_.]", "_")
  return ("%s/%s-%s.png"):format(dir, host, vim.fn.sha256(key):sub(1, 16))
end

---@internal
--- Delete rendered pages older than `days`, once per session.
---
--- Only ever touches `*.png` directly inside this plugin's own cache
--- directory. Same sweep `preview.office` performs on its converted PDFs, and
--- for the same reason: these outlive the session on purpose, and a cache that
--- only grows is a bug with a slow fuse.
---@param days integer
---@return nil
local function sweep(days)
  if _swept then
    return
  end
  _swept = true
  if type(days) ~= "number" or days <= 0 then
    return
  end

  local dir = cache_dir()
  local ok, entries = pcall(vim.fn.readdir, dir)
  if not ok or type(entries) ~= "table" then
    return
  end

  local cutoff = os.time() - days * 24 * 60 * 60
  for _, name in ipairs(entries) do
    if type(name) == "string" and name:sub(-4) == ".png" then
      local file = dir .. "/" .. name
      local st = uv.fs_stat(file)
      if st and st.mtime and st.mtime.sec < cutoff then
        pcall(os.remove, file)
      end
    end
  end
end

---@internal
--- A line, and the URL underneath it. Used for every answer that is not a
--- picture: the reader still gets what the offline preview would have said.
---@param target Hover.Target
---@param note string
---@param pending? boolean
---@return Hover.Content
local function say(target, note, pending)
  local content = require("hover.preview.url").offline(target)
  table.insert(content.lines, 1, note)
  if pending then
    content.pending = true
  end
  return content
end

--- The rendered page for this target, if one is already on disk.
---
--- Never starts a browser, and that is the whole contract: `hover.zoom` asks
--- this to decide whether a screenshot can be magnified, and a question about
--- capability must not have a twenty-second answer.
---@param target Hover.Target
---@param opts? Hover.PreviewOpts
---@return string|nil path
function M.cached(target, opts)
  local url = target.url or target.raw
  if type(url) ~= "string" or not url:match("^https?://") then
    return nil
  end
  opts = opts or require("hover.config").preview_opts()

  local key = key_for(url, opts)
  local png = _shots[key]
  if not png then
    -- Not in this session's table, but the file name is a pure function of
    -- the key -- so a render from an *earlier* session is findable by looking
    -- where it would be. Same move `preview.office` makes, and what lets the
    -- cache outlive the session at all.
    local candidate = output_path(url, key)
    if uv.fs_stat(candidate) then
      png = candidate
      _shots[key] = candidate
    end
  end
  if png and uv.fs_stat(png) then
    return png
  end
  if png then
    -- A temp sweeper took it. Not a cache entry any more, a dangling path.
    _shots[key] = nil
  end
  return nil
end

---@internal
--- Hand a rendered page to the picture pipeline, as if the reader had hovered
--- the PNG itself. Everything past this point -- the canvas sizing, the
--- drawing, the crop `>` performs -- is `preview.media`'s, unchanged.
---@param png string
---@param opts Hover.PreviewOpts
---@param on_result fun(content: Hover.Content): nil
---@return Hover.Content
local function picture_of(png, opts, on_result)
  local media = require("hover.preview.media")
  if (opts.zoom or 0) > 0 then
    -- **`zoomed` answers nil when it cannot cut the picture at all** -- an
    -- unreadable PNG, or no `images.convert` to run the crop -- and nil is not
    -- an answer either caller can use: both hand this straight back as
    -- `M.preview`'s content. The page rendered; the plain picture is still
    -- correct, only not magnified, so that is what is shown.
    --
    -- It is also what `zoomed` itself does when the crop fails *after* it has
    -- returned: `on_result(nil)`, and the picture on screen stays. The two
    -- answers should not differ by which half of the run noticed.
    return media.zoomed(png, opts, on_result) or media.canvas_for(png, opts)
  end
  return media.canvas_for(png, opts)
end

---@internal
--- Stop whatever render is in flight, and forget any start not yet committed
--- to. Called when another page is asked for: one browser at a time is the
--- protection, and a killed render is cheaper than a second concurrent one.
---@return nil
local function cancel()
  if _pending then
    pcall(function()
      _pending.timer:stop()
    end)
    _pending = nil
  end
  if _running then
    -- `pcall`: the process may have exited between the check and here, and a
    -- render nobody is waiting for is not worth an error message.
    pcall(function()
      _running.handle:kill(9)
    end)
    _running = nil
  end
end

--- Drop the session's renders, the running process and the resolved browser.
--- For the test suite, and for anything that wants the next hover to render
--- again. The files on disk are left alone -- they are the cache, and `sweep`
--- owns their lifetime.
---@return nil
function M.reset()
  cancel()
  _shots = {}
  _swept = false
  _browser = nil
end

---@internal
--- The flags, assembled for one render.
---
--- **`--user-data-dir` is the security-relevant one** and is not optional:
--- see the module header. It points at a directory under this plugin's own
--- cache, so the browser starts with no cookies, no extensions and no session
--- of the reader's -- the picture is what an anonymous visitor sees.
---
--- Deliberately **no** `--no-sandbox`. It is the usual cure for a browser
--- that will not start in a container, and it is exactly wrong here: the page
--- being rendered is untrusted by construction, and the sandbox is what stands
--- between it and the machine. A browser that needs it can be named through
--- `links.shot.command` wrapped in a script, which is a decision the reader
--- makes rather than one this plugin makes for them.
---
--- `--virtual-time-budget` rather than waiting for the network to fall quiet:
--- the latter needs the DevTools protocol and a socket, which is a great deal
--- more code for a preview -- and measured, the budget is not a wait. The
--- probe page above rendered in 768 ms with the budget set to 5000.
---@param browser string
---@param url string
---@param out string
---@param opts Hover.PreviewOpts
---@return string[]
local function argv(browser, url, out, opts)
  return {
    browser,
    "--headless=new",
    "--disable-gpu",
    "--hide-scrollbars",
    "--disable-extensions",
    "--disable-background-networking",
    "--disable-sync",
    "--disable-default-apps",
    "--no-first-run",
    "--no-default-browser-check",
    "--mute-audio",
    "--user-data-dir=" .. cache_dir() .. "/profile",
    "--virtual-time-budget=" .. tostring(math.max(1000, (opts.shot_timeout_ms or 20000) / 4)),
    ("--window-size=%d,%d"):format(opts.shot_width or 1280, opts.shot_height or 900),
    "--screenshot=" .. out,
    url,
  }
end

---@internal
--- Run the browser for one page, and report through `on_result`.
---@param target Hover.Target
---@param url string
---@param key string
---@param opts Hover.PreviewOpts
---@param on_result fun(content: Hover.Content): nil
---@return nil
local function render(target, url, key, opts, on_result)
  local browser = M.browser(opts.shot_command)
  if not browser then
    on_result(say(target, "(no headless browser found -- see :checkhealth hover)"))
    return
  end

  local out = output_path(url, key)
  local ok_spawn, handle = pcall(vim.system, argv(browser, url, out, opts), {
    text = false,
    timeout = opts.shot_timeout_ms or 20000,
  }, function()
    -- The exit lands in a fast event context, where opening a window and
    -- reading a file are both out of bounds.
    vim.schedule(function()
      _running = nil
      if not uv.fs_stat(out) then
        -- The browser's own exit code is unhelpfully cheerful about a page
        -- that never loaded, so the file is the verdict: either there is a
        -- picture or there is not.
        on_result(say(target, "(the page did not render -- it may be slower than the timeout)"))
        return
      end
      _shots[key] = out
      local content = picture_of(out, opts, on_result)
      -- `picture_of` answers at once for a picture that needs no crop, and
      -- hands back a placeholder otherwise. Either is worth showing: by now
      -- the reader has waited through a browser start.
      on_result(content)
    end)
  end)

  if not ok_spawn then
    on_result(say(target, "(the browser would not start)"))
    return
  end
  _running = { key = key, handle = handle }
end

--- Preview a link as the rendered page.
---
--- Contract matches `preview.media.pdf` and `preview.office.preview`: the
--- returned content is what to show *now* -- final, or marked `pending` when
--- something is on its way -- and `on_result` receives the real thing when it
--- lands.
---@param target Hover.Target
---@param opts Hover.PreviewOpts
---@param on_result fun(content: Hover.Content): nil
---@return Hover.Content
function M.preview(target, opts, on_result)
  local url = target.url or target.raw

  -- Only http(s) can be rendered; `mailto:` and friends stay offline.
  if not url:match("^https?://") then
    return require("hover.preview.url").offline(target)
  end

  -- **Asked before the browser rather than after it**, which is the whole
  -- point of asking here: a page rendered into a picture nothing can draw is
  -- twenty seconds spent on a file the reader will never see. The same
  -- degradation `inline_images` produces everywhere else, one step earlier.
  local ok_provider, provider = pcall(function()
    return require("lib.nvim.image_preview").detect()
  end)
  if opts.inline_images == false then
    return say(target, "(pictures are switched off -- `:Hover images on`)")
  end
  if not (ok_provider and provider) then
    return say(target, "(no image provider installed, so a rendered page cannot be drawn)")
  end

  -- Before anything is started, and before the sweep: a page already rendered
  -- is the answer, and this is what makes a second hover over the same link
  -- free.
  local key = key_for(url, opts)
  local png = M.cached(target, opts)
  if png then
    return picture_of(png, opts, on_result)
  end

  -- Already rendering this exact page. Without this, every `CursorHold` while
  -- the browser runs would start another one: a `pending` result is never
  -- cached, so the request arrives here again each time.
  if _running and _running.key == key then
    return say(target, "rendering the page…", true)
  end
  if _pending and _pending.key == key then
    return say(target, "rendering the page…", true)
  end

  if not M.browser(opts.shot_command) then
    return say(target, "(no headless browser found -- see :checkhealth hover)")
  end

  -- Another page is being rendered, or was about to be. One at a time.
  cancel()

  -- Once per session, before the first render: retire what has gone stale.
  -- Here rather than at startup, so a session that never renders a page never
  -- reads the directory at all.
  sweep(opts.shot_cache_days)

  local delay = opts.requested and 0 or math.max(0, opts.shot_delay_ms or 1000)
  if delay == 0 then
    render(target, url, key, opts, on_result)
  else
    -- The trigger has not committed yet. `delay_ms` is a quarter of a second
    -- -- the right wait for a free preview and the wrong one for 0.7 s of
    -- process start plus up to twenty of page, so this waits again before
    -- anything is spawned. Moving to another link cancels it, having spent
    -- nothing.
    local timer = vim.defer_fn(function()
      _pending = nil
      render(target, url, key, opts, on_result)
    end, delay)
    _pending = { key = key, timer = timer }
  end

  return say(target, "rendering the page…", true)
end

return M
