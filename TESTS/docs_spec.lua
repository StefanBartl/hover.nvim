---@diagnostic disable: need-check-nil
-- The test body is the guard; see the note in TESTS/bare_path_spec.lua
-- (`LLS-42`).

-- TESTS/docs_spec.lua -- the documents, read against the source they describe.
--
-- **The reason this file exists is counted, not feared.** On 2026-09-02 four
-- documented claims were wrong at the same time: the switch list of
-- `hover.set()` in the vimdoc named seven of nine, three hand-counted numbers
-- in `docs/INTEGRATIONS.md` were stale, a heading there said "the only
-- registry contributor today" with six of them, and `docs/ROADMAP.md` said
-- "four of the candidates are built" with five.
--
-- That is the same class that hit the *code* three times (`usrcmds.route_path`,
-- `switches.effective`, `preview/office.lua`): a second, hand-written copy of
-- something the source already knows. One step worse, though -- in the code a
-- spec eventually trips over it, in a document nobody does.
--
-- So: everything a document says that the source can be asked about gets
-- asked here.
--
--   1. The switch names the vimdoc lists for `hover.set()`, against
--      `switches.names()`, and every spelled-out count of switches in any
--      document against how many there are.
--   2. Every `:Hover` route, against what `usrcmds.routes()` declares -- both
--      directions, and for each of the three tables that carry the full list.
--   3. The target types a preview may claim, against the declared union and
--      against the dispatch chain that actually consumes them.
--   4. The augroups and highlight groups `docs/BINDINGS.md` tabulates,
--      against the names the source installs. This is the one that was wrong
--      most recently: two augroups still carried markdown.nvim's name
--      (`87a1017`), which is also why both tables counted two of four -- a
--      search for `Hover` in the source could not find them.
--   5. `docs/MANUAL-EVIDENCE.md` against its own two rules: every row carries
--      the fields that file says a row has, and every spelled-out count of
--      those rows -- in any document -- matches how many there are. That one
--      had already drifted when it was written: the zoom row arrived with
--      `204d083` and three sentences went on saying "three".
--
-- **What is deliberately not here: the integration tables.** They describe
-- other plugins. A spec that checked them would have to load all six, and
-- would then be testing this machine's installation rather than the document.
-- That claim stays a human one.

local switches = require("hover.switches")
local usrcmds = require("hover.bindings.usrcmds")

--- Read one file from the repo root. `scripts/test.sh` runs from there.
---@param rel string
---@return string
local function read(rel)
  local fd = assert(io.open(vim.fn.getcwd() .. "/" .. rel, "r"), rel .. " is not readable")
  local text = fd:read("*a")
  fd:close()
  return text
end

--- Every lowercase word in `text`, in order -- what a prose list of names
--- comes down to once the commas and line breaks are gone.
---@param text string
---@return string[]
local function words(text)
  local out = {}
  for word in text:gmatch("%a+") do
    out[#out + 1] = word
  end
  return out
end

---@param list string[]
---@return table<string, true>
local function set(list)
  local out = {}
  for _, item in ipairs(list) do
    out[item] = true
  end
  return out
end

---@param items table<string, true>
---@return string[]
local function sorted(items)
  local out = {}
  for item in pairs(items) do
    out[#out + 1] = item
  end
  table.sort(out)
  return out
end

--- The `"a"|"b"|…` union `Hover.Target.type` is declared with.
---@return table<string, true>
local function declared_types()
  local union =
    read("lua/hover/@types/init.lua"):match("@class Hover%.Target.-@field type ([^\n]+)")
  assert(union, "Hover.Target no longer declares its type union")
  local out = {}
  for name in union:gmatch('"(%a+)"') do
    out[name] = true
  end
  return out
end

--- Every `:Hover …` route path declared, as `"paths code"`-shaped strings.
---
--- Read from `usrcmds.routes()` rather than from the composer registry: that
--- is where the routes are written, and `TESTS/switches_spec.lua` already
--- pins the step from there into the composer.
---@return table<string, true>
local function declared_routes()
  local out = {}
  for _, route in ipairs(usrcmds.routes()) do
    out[table.concat(route.path or {}, " ")] = true
  end
  return out
end

--- Every `:Hover …` a document names, as route paths.
---
--- Two shapes, and both have to be read exactly rather than greedily -- a
--- prose sentence continues after the command, so "match letters and spaces"
--- swallows the sentence along with it:
---
---   * a backticked span, `:Hover paths code on`, which is how every mention
---     in the markdown files and most of the vimdoc is written;
---   * an indented line of the vimdoc's command block, where the route is
---     separated from its description by a run of spaces.
---
--- A trailing state argument is not part of the path (`:Hover paths on` is
--- the `paths` route with an argument), and neither is a completion hint
--- (`[on|off|toggle]`). The state is stripped only while something is left:
--- a bare `:Hover off` is not a command, and reading it as the verb alone
--- would hide exactly that.
---@param text string
---@param vimdoc boolean Also read the indented command block.
---@return table<string, true>
local function documented_routes(text, vimdoc)
  -- Argument values, not just switch states: `mode` contributes auto and
  -- manual, `resize` contributes bigger and smaller. A document writing the
  -- concrete `:Hover resize bigger` still means the `resize` route.
  local STATES = {
    on = true,
    off = true,
    toggle = true,
    auto = true,
    manual = true,
    bigger = true,
    smaller = true,
  }
  local mentions = {}

  for mention in text:gmatch("`:Hover([^`]*)`") do
    mentions[#mentions + 1] = mention
  end
  if vimdoc then
    for line in text:gmatch("[^\n]+") do
      local mention = line:match("^%s%s+:Hover(%s+%S.-)%s%s")
        or line:match("^%s%s+:Hover(%s+%S.*)$")
      if mention then
        mentions[#mentions + 1] = mention
      end
    end
  end

  local out = {}
  for _, mention in ipairs(mentions) do
    local route = words((mention:gsub("%[.*$", "")))
    while #route > 1 and STATES[route[#route]] do
      table.remove(route)
    end
    -- A bare `:Hover` is the verb itself and always exists.
    if #route > 0 then
      out[table.concat(route, " ")] = true
    end
  end
  return out
end

---@type table<string, integer> Counts a document is likely to spell out.
local NUMBER = {
  one = 1,
  two = 2,
  three = 3,
  four = 4,
  five = 5,
  six = 6,
  seven = 7,
  eight = 8,
  nine = 9,
  ten = 10,
  eleven = 11,
  twelve = 12,
}

--- Every spelled-out count of `noun` a document claims, with the line it
--- stands in so a failure names the sentence rather than a number.
---
--- The adjective between the number and the noun varies ("Nine runtime
--- switches", "all seven switches") and the number is the part that goes
--- stale, so the window before the noun is searched rather than a fixed
--- phrase. `noun` is matched plainly, so a multi-word one ("paths above")
--- works and needs no escaping. Measured over the documents as they stand:
--- two hits for the switches, two for the evidence rows, no false ones.
---@param text string
---@param noun string
---@return { count: integer, line: string }[]
local function claimed_counts(text, noun)
  local out = {}
  for line in text:gmatch("[^\n]+") do
    local from = 1
    while true do
      local start, stop = line:find(noun, from, true)
      if not start then
        break
      end
      local count
      for word in line:sub(math.max(1, start - 40), start - 1):gmatch("%a+") do
        count = NUMBER[word:lower()] or count
      end
      if count then
        out[#out + 1] = { count = count, line = vim.trim(line) }
      end
      from = stop + 1
    end
  end
  return out
end

--- The `:Hover` path of one switch, read as its implication chain -- the same
--- derivation `usrcmds.route_path` performs, which is module-local there.
---@param name string
---@return string
local function switch_path(name)
  local path, cursor, guard = { name }, switches.spec(name), 0
  while cursor and cursor.implies and guard < 10 do
    table.insert(path, 1, cursor.implies)
    cursor = switches.spec(cursor.implies)
    guard = guard + 1
  end
  return table.concat(path, " ")
end

--- Every backticked span in `text` -- how a markdown table cell names things.
---@param text string
---@return table<string, true>
local function backticked(text)
  local out = {}
  for span in text:gmatch("`([^`]+)`") do
    out[span] = true
  end
  return out
end

--- The documents, and whether each is vimdoc.
---@return table<string, boolean>
local function all_documents()
  local out = { ["README.md"] = false, ["doc/hover.txt"] = true }
  -- Recursive: `docs/FEATURES/` arrived after this file did, and a document
  -- outside the glob is exactly how `MANUAL-EVIDENCE.md` came to say "three"
  -- while there were four.
  for _, file in ipairs(vim.fn.glob(vim.fn.getcwd() .. "/docs/**/*.md", false, true)) do
    out[(vim.fn.fnamemodify(file, ":."):gsub("\\", "/"))] = false
  end
  return out
end

-- The three documents that each carry a *complete* route table. Each one is a
-- separate copy of the same list, which is why each one is checked.
local ROUTE_TABLES =
  { ["README.md"] = false, ["doc/hover.txt"] = true, ["docs/BINDINGS.md"] = false }

describe("doc/hover.txt against the source", function()
  it("lists exactly the switches hover.set() accepts, in the same order", function()
    -- `Names: links, web, … office -- hover.switches.names() is the list.`
    -- The vimdoc says out loud where its list comes from; this is that
    -- sentence held to it.
    local listed = read("doc/hover.txt"):match("Names:(.-)%-%-")
    assert.is_truthy(listed, "doc/hover.txt no longer names the switches for hover.set()")
    assert.same(switches.names(), words(listed))
  end)

  it("names every target type a preview can be keyed on", function()
    local listed = read("doc/hover.txt"):match("Target types a preview can claim:(.-)%.")
    assert.is_truthy(listed, "doc/hover.txt no longer names the claimable target types")
    -- The declared union is the source of truth: `Hover.Target.type` is what
    -- `registry.preview_for(target.type)` is handed, whatever produced it.
    assert.same(sorted(declared_types()), sorted(set(words(listed))))
  end)
end)

describe("what the documents count", function()
  it("spells out the right number of switches, wherever it spells one out", function()
    -- `docs/installation.md` said "the mode and all seven switches" while
    -- there were nine, in the page that explains `:Hover status`. A number in
    -- prose has no consumer that would notice.
    local want = #switches.names()
    local wrong = {}
    for file in pairs(all_documents()) do
      for _, claim in ipairs(claimed_counts(read(file), "switches")) do
        if claim.count ~= want then
          wrong[#wrong + 1] = ("%s says %d, there are %d: %s"):format(
            file,
            claim.count,
            want,
            claim.line
          )
        end
      end
    end
    table.sort(wrong)
    assert.same({}, wrong)
  end)

  it("names every switch in the README's feature table", function()
    -- The cell that carries the list, and the count in its own first column.
    local counted, cell = read("README.md"):match("|%s*(%a+) runtime switches%s*|([^|]*)|")
    assert.is_truthy(counted, "README.md no longer has a row for the runtime switches")
    assert.equals(#switches.names(), NUMBER[counted:lower()])

    local named = backticked(cell)
    local missing = {}
    for _, name in ipairs(switches.names()) do
      local path = switch_path(name)
      if not named[path] then
        missing[#missing + 1] = path
      end
    end
    assert.same({}, missing)
  end)
end)

describe("the :Hover routes against the documents", function()
  it("documents every declared route, in every table that carries one", function()
    local routes = declared_routes()
    local missing = {}
    for file, vimdoc in pairs(ROUTE_TABLES) do
      local named = documented_routes(read(file), vimdoc)
      for path in pairs(routes) do
        if not named[path] then
          missing[#missing + 1] = ("%s is missing `:Hover %s`"):format(file, path)
        end
      end
    end
    table.sort(missing)
    assert.same({}, missing)
  end)

  it("names no command that is not declared", function()
    -- The document side of the check `switches_spec` already runs over
    -- `lua/`. A float telling someone to type a command that does not exist
    -- is bad; a document doing it is worse, because it is read before
    -- anything is typed at all.
    local routes = declared_routes()
    local bad = {}
    for file, vimdoc in pairs(all_documents()) do
      for path in pairs(documented_routes(read(file), vimdoc)) do
        if not routes[path] then
          bad[#bad + 1] = ("%s names `:Hover %s`"):format(file, path)
        end
      end
    end
    table.sort(bad)
    assert.same({}, bad)
  end)
end)

describe("the target types against each other", function()
  it("previews every type a target can declare, and no type it cannot", function()
    -- The third copy of the same list, and the one that decides what a reader
    -- actually sees: the `if target.type == …` chain in `build`. Bounded to
    -- that function, because `target.type` is compared elsewhere for other
    -- questions -- whether a URL may be fetched, whether a preview scrolls by
    -- page -- and those are not dispatch.
    local chain = read("lua/hover/init.lua"):match("\nlocal function build%(.-\nend\n")
    assert.is_truthy(chain, "the preview dispatch is no longer a top-level `build` function")

    local dispatched = {}
    for name in chain:gmatch('target%.type == "(%a+)"') do
      dispatched[name] = true
    end

    assert.same(sorted(declared_types()), sorted(dispatched))
  end)
end)

describe("the borrowed keys against the defaults", function()
  -- Added when `zoom_keys` was: two documents tabulate every key list with
  -- its default, and a new pair is two more rows nobody fails to write.
  local DEFAULTS = require("hover.config.DEFAULTS")

  --- Every key named in one table cell, in either notation the documents
  --- use: `docs/BINDINGS.md` writes them as separate spans -- `q`, `<Esc>` --
  --- and the README as the Lua literal it would be configured with,
  --- `{ "q", "<Esc>" }`.
  ---@param cell string
  ---@return string[]
  local function keys_in(cell)
    local out = {}
    for span in cell:gmatch("`([^`]+)`") do
      if span:find('"') then
        for key in span:gmatch('"([^"]+)"') do
          out[#out + 1] = key
        end
      else
        out[#out + 1] = span
      end
    end
    return out
  end

  --- The default at a dotted option path, as a list.
  ---@param path string
  ---@return string[]|nil
  local function default_keys(path)
    -- `any`, because walking a dotted path leaves `Hover.Config` at the first
    -- step and every step after that is a different type (`LLS-30`: a
    -- narrowing declared once beats a cast per assignment).
    ---@type any
    local node = DEFAULTS
    for key in path:gmatch("[^.]+") do
      if type(node) ~= "table" then
        return nil
      end
      node = node[key]
    end
    if type(node) == "string" then
      return { node }
    end
    return type(node) == "table" and node or nil
  end

  --- Every `| \`something_keys…\` | keys |` row of a document.
  ---@param text string
  ---@return table<string, string[]>
  local function tabulated_keys(text)
    local out = {}
    for row in text:gmatch("[^\n]+") do
      local name, rest = row:match("^|%s*`([%a][%w_]*_keys[%w_.]*)`%s*|(.*)$")
      if name then
        out[name] = keys_in(rest:match("^([^|]*)") or "")
      end
    end
    return out
  end

  local FILES = { "README.md", "docs/BINDINGS.md" }

  it("tabulates the keys each list actually holds", function()
    local wrong = {}
    for _, file in ipairs(FILES) do
      for name, documented in pairs(tabulated_keys(read(file))) do
        local actual = default_keys(name)
        if not actual then
          wrong[#wrong + 1] = ("%s documents `%s`, which is not an option"):format(file, name)
        elseif not vim.deep_equal(actual, documented) then
          wrong[#wrong + 1] = ("%s says %s is %s, it is %s"):format(
            file,
            name,
            vim.inspect(documented, { newline = " ", indent = "" }),
            vim.inspect(actual, { newline = " ", indent = "" })
          )
        end
      end
    end
    table.sort(wrong)
    assert.same({}, wrong)
  end)

  it("leaves no key list undocumented, in either table", function()
    -- The direction that catches a *new* pair rather than a changed one.
    local expected = {}
    for name, value in pairs(DEFAULTS) do
      -- Two shapes, and the `type` check is not only for the annotation: an
      -- option ending in `_keys` that is neither is a shape this check does
      -- not understand, and skipping it silently would be the same "it looked
      -- covered" this whole file exists against.
      if name:match("_keys$") and type(value) == "table" then
        if vim.islist(value) then
          expected[name] = true
        else
          for sub in pairs(value) do
            expected[name .. "." .. sub] = true
          end
        end
      end
    end
    assert.is_true(vim.tbl_count(expected) > 0, "found no key lists in the defaults")

    local missing = {}
    for _, file in ipairs(FILES) do
      local documented = tabulated_keys(read(file))
      for name in pairs(expected) do
        if not documented[name] then
          missing[#missing + 1] = ("%s never tabulates `%s`"):format(file, name)
        end
      end
    end
    table.sort(missing)
    assert.same({}, missing)
  end)
end)

describe("docs/BINDINGS.md against the groups the source installs", function()
  --- The `Group` column of one table of `docs/BINDINGS.md`, from its header
  --- row down to the blank line that ends it.
  ---@param after string Text the table follows.
  ---@return table<string, true>
  local function tabulated(after)
    local table_text = read("docs/BINDINGS.md"):match(after .. ".-\n(| `.-)\n\n")
    assert(table_text, "docs/BINDINGS.md no longer tabulates the groups after " .. after)
    local out = {}
    for row in table_text:gmatch("[^\n]+") do
      -- The first cell only: the rest of the row names events and highlight
      -- links, which are backticked too.
      local name = row:match("^|%s*`([%w<>]+)`")
      if name then
        -- `HoverBuf<n>` is one group per buffer; the source writes only the
        -- prefix, and the suffix is the buffer number.
        out[(name:gsub("<n>$", ""))] = true
      end
    end
    return out
  end

  it("tabulates every augroup, and no augroup that is gone", function()
    -- Until `87a1017` two of these were called `MarkdownHoverDismiss` and
    -- `MarkdownNvimHoverMedia` -- visible under `:autocmd` as markdown.nvim's,
    -- and invisible to anyone grepping the source for `Hover`. Both tables
    -- listed two groups where there were four, for exactly that reason.
    local installed = {}
    for _, file in ipairs(vim.fn.glob(vim.fn.getcwd() .. "/lua/**/*.lua", false, true)) do
      local text = read((vim.fn.fnamemodify(file, ":."):gsub("\\", "/")))
      for name in text:gmatch('autocmd%.group%("(Hover%a*)"') do
        installed[name] = true
      end
      for name in text:gmatch('group = "(Hover%a*)"') do
        installed[name] = true
      end
    end
    assert.is_true(vim.tbl_count(installed) > 0, "found no augroups in the source")
    assert.same(sorted(installed), sorted(tabulated("## Autocmds")))
  end)

  it("tabulates every highlight group, with the group it links to", function()
    local defaults = read("lua/hover/float.lua"):match("local HL_DEFAULTS = {(.-)}")
    assert.is_truthy(defaults, "float.lua no longer declares HL_DEFAULTS")

    local links = {}
    for name, link in defaults:gmatch('(%a+)%s*=%s*"(%a+)"') do
      links[name] = link
    end

    -- Read as pairs, not as two lists: "which group does HoverInfo link to"
    -- is the claim a reader acts on, and a table can name all three groups
    -- while pointing one of them at the wrong colour.
    local documented = {}
    local table_text = read("docs/BINDINGS.md"):match("## Highlight groups.-\n(| `.-)\n\n")
    assert.is_truthy(table_text, "docs/BINDINGS.md no longer tabulates the highlight groups")
    for name, link in table_text:gmatch("|%s*`(%a+)`%s*|%s*`(%a+)`") do
      documented[name] = link
    end

    assert.same(links, documented)
  end)
end)
describe("docs/MANUAL-EVIDENCE.md against its own rules", function()
  -- The one document with no source to be read against: it records what a
  -- person saw on a machine, and nothing in `lua/` knows about that. What it
  -- *does* have is two rules it states about itself, and those are checkable
  -- -- which matters, because it had already broken one of them before this
  -- block existed. `204d083` added the zoom row and three sentences went on
  -- saying "three paths".

  --- Every row under `## What no CI covers`, heading and body.
  ---
  --- Bounded by the next `## `, so the office paragraph and the two sections
  --- that follow the rows are outside it.
  ---@return { heading: string, body: string }[]
  local function evidence_rows()
    local section = read("docs/MANUAL-EVIDENCE.md"):match("\n## What no CI covers\n(.-)\n## ")
    assert(section, "docs/MANUAL-EVIDENCE.md no longer has a `What no CI covers` section")
    local starts = {}
    for pos, heading in section:gmatch("()\n### ([^\n]+)") do
      starts[#starts + 1] = { pos = pos, heading = heading }
    end
    local out = {}
    for i, entry in ipairs(starts) do
      local stop = starts[i + 1] and starts[i + 1].pos - 1 or #section
      out[#out + 1] = { heading = entry.heading, body = section:sub(entry.pos, stop) }
    end
    return out
  end

  it("gives every row the fields it says a row has", function()
    -- The field names are read from `## How to read a row` rather than
    -- written out here: the file defines what evidence is, and a second copy
    -- of that definition in a spec is the exact mistake this whole file is
    -- against. A row missing one of them is not evidence by the document's
    -- own account -- an undated row reads as a check that happened, and a row
    -- with no `How` cannot be repeated.
    local legend = read("docs/MANUAL-EVIDENCE.md"):match("\n## How to read a row\n(.-)\n## ")
    assert.is_truthy(legend, "docs/MANUAL-EVIDENCE.md no longer explains how to read a row")

    local fields = {}
    for cell in legend:gmatch("\n|%s*([^|\n]-)%s*|") do
      if cell ~= "" and cell ~= "Column" and not cell:match("^%-+$") then
        fields[#fields + 1] = cell
      end
    end
    assert.is_true(#fields > 0, "the legend table names no fields")

    local rows = evidence_rows()
    assert.is_true(#rows > 0, "no rows under `What no CI covers`")

    local missing = {}
    for _, row in ipairs(rows) do
      for _, field in ipairs(fields) do
        if not row.body:find("**" .. field .. "**", 1, true) then
          missing[#missing + 1] = ("%s has no %s"):format(row.heading, field)
        end
      end
    end
    table.sort(missing)
    assert.same({}, missing)
  end)

  it("counts its own rows, wherever a document spells that number out", function()
    -- Two phrasings, in two files: "one of the five paths above" here, "the
    -- five things no CI can check" in the README. Both are counted by hand
    -- and neither has a consumer that would notice going stale -- which is
    -- how they came to say three while there were four.
    local want = #evidence_rows()
    local wrong = {}
    for file in pairs(all_documents()) do
      local text = read(file)
      for _, noun in ipairs({ "paths above", "things no CI can check" }) do
        for _, claim in ipairs(claimed_counts(text, noun)) do
          if claim.count ~= want then
            wrong[#wrong + 1] = ("%s says %d, there are %d: %s"):format(
              file,
              claim.count,
              want,
              claim.line
            )
          end
        end
      end
    end
    table.sort(wrong)
    assert.same({}, wrong)
  end)
end)
