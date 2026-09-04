---@diagnostic disable: need-check-nil
-- The test body is the guard; see the note in TESTS/bare_path_spec.lua
-- (`LLS-42`).

-- TESTS/url_spec.lua -- the page's own text, pulled out of a body that was
-- downloaded anyway.
--
-- **Why this is patterns and not a parser, and why that is testable at all.**
-- A hover does not justify an HTML parser, and the failure mode of a
-- pattern-based reader is the right one: a page it reads badly produces prose
-- with some navigation in it, never an error, and the status line, the title
-- and the URL are still above it. So what is pinned here is not "this parses
-- HTML" -- it does not -- but the four decisions that make the output
-- readable, each of which is silently reversible by a plausible edit:
--
--   1. **Order.** Comments before everything, or a commented-out `</main>`
--      ends the extract early. Dropped elements before the block breaks, or a
--      `<nav>` whose `</p>`s have already become newlines is no longer one
--      string to remove. Entities *last*, or a decoded `&lt;` is mistaken for
--      a tag by the strip that follows.
--   2. **The frontier.** `<nav>` is dropped and `<navbar>` is not, which is a
--      `%f[%W]` and nothing else -- `[^>]*` alone takes both.
--   3. **Wrapping is this module's job, not the float's.** The window sets
--      `wrap` and `linebreak`, so a long line *looks* right -- and the height
--      is wrong, because `float.measure` counts list entries rather than the
--      rows they occupy.
--   4. **The budget is what the caller has room for**, so a hover put full
--      screen shows a screenful of the page rather than twenty lines of it.

local url = require("hover.preview.url")

--- `page_text` with the defaults these specs mostly want: a wide box and
--- room for everything, so a spec about *content* never fails on a cap.
---@param html string
---@param opts? { max_width?: integer, max_lines?: integer }
---@return string[]
local function text(html, opts)
  opts = opts or {}
  return url.page_text(html, {
    max_width = opts.max_width or 200,
    max_lines = opts.max_lines or 100,
  })
end

describe("hover.preview.url.page_text", function()
  it("takes what the author marked as the page, not the page", function()
    assert.same(
      { "The real text." },
      text(
        "<body><nav><p>Home</p></nav>"
          .. "<main><p>The real text.</p></main>"
          .. "<footer><p>bye</p></footer></body>"
      )
    )
  end)

  it("falls back to article, then to body, then to the whole thing", function()
    assert.same(
      { "From an article." },
      text("<body><article><p>From an article.</p></article></body>")
    )
    assert.same(
      { "From the body." },
      text("<html><head><title>t</title></head><body><p>From the body.</p></body></html>")
    )
    assert.same({ "Bare." }, text("<p>Bare.</p>"))
  end)

  it("drops the elements whose text is actively misleading, with their content", function()
    assert.same(
      { "Real." },
      text(
        "<body><nav><p>Home</p><p>Docs</p></nav>"
          .. "<p>Real.</p>"
          .. "<script>var x = '<p>not text</p>';</script>"
          .. "<style>p { color: red }</style></body>"
      )
    )
  end)

  it("ends a tag name where it is written, so navbar is not nav", function()
    -- `[^>]*` alone takes both, and the symptom is a page that loses a
    -- paragraph rather than an error.
    assert.same({ "Kept." }, text("<body><navbar><p>Kept.</p></navbar></body>"))
  end)

  it("reads comments away before they can end the extract early", function()
    -- A commented-out `</main>` is the case that decides the order: with the
    -- comments still in, the match stops at the first one it sees.
    assert.same(
      { "All of it." },
      text("<body><main><p>All of it.</p><!-- </main> --></main><p>after</p></body>")
    )
  end)

  it("keeps a list a list, because losing it makes a list read as nonsense", function()
    assert.same(
      { "• one", "• two", "• three" },
      text("<body><ul><li>one</li><li>two</li><li>three</li></ul></body>")
    )
  end)

  it("breaks lines where a block element does, and nowhere an inline one does", function()
    assert.same(
      { "First.", "Second.", "Third and a bold word." },
      text(
        "<body><p>First.</p><p>Second.</p>"
          .. "<p>Third and a <strong>bold</strong> word.</p></body>"
      )
    )
  end)

  it("takes a <br> as the break it is", function()
    assert.same({ "one", "two" }, text("<body><p>one<br>two</p></body>"))
  end)

  it("collapses every run of whitespace into one, which is HTML's own rule", function()
    assert.same({ "a b c" }, text("<body><p>\n      a\n\n      b\t\tc\n    </p></body>"))
  end)

  it("resolves the character references a page actually writes", function()
    assert.same(
      { "a & b — c ‘d’" },
      text("<body><p>a &amp; b &mdash; c &lsquo;d&rsquo;</p></body>")
    )
  end)

  it("resolves numeric references in both spellings", function()
    assert.same({ "——" }, text("<body><p>&#8212;&#x2014;</p></body>"))
  end)

  it("leaves a name it does not know exactly as written", function()
    -- Better than a question mark: the reader can see what the page said.
    assert.same({ "&nonesuch;" }, text("<body><p>&nonesuch;</p></body>"))
  end)

  it("does not invent markup out of an escaped escape", function()
    -- `&amp;lt;` is how a page writes a literal `&lt;`. Decoding `&amp;`
    -- first, in its own pass, would turn it into `<`.
    assert.same({ "&lt;" }, text("<body><p>&amp;lt;</p></body>"))
  end)

  it("decodes after stripping, so a decoded < is never read as a tag", function()
    assert.same({ "if a < b then" }, text("<body><p>if a &lt; b then</p></body>"))
  end)

  it("wraps at the width it is given, because the float counts entries not rows", function()
    local lines = text("<body><p>alpha beta gamma delta epsilon</p></body>", { max_width = 12 })
    assert.is_true(#lines > 1, "one line came back for a paragraph wider than the box")
    for _, line in ipairs(lines) do
      assert.is_true(#line <= 12, ("%q is wider than the box"):format(line))
    end
    assert.same("alpha beta gamma delta epsilon", table.concat(lines, " "))
  end)

  it("hands over a word wider than the box whole, rather than cutting into it", function()
    -- Cutting by columns means cutting inside a multi-byte character, and the
    -- float wraps one over-long word correctly by itself. Only the count is
    -- off, by one row.
    assert.same(
      { "supercalifragilistic" },
      text("<body><p>supercalifragilistic</p></body>", {
        max_width = 8,
      })
    )
  end)

  it("stops at the budget it is given", function()
    local html = "<body>"
    for i = 1, 20 do
      html = html .. ("<p>paragraph %d</p>"):format(i)
    end
    assert.same(3, #text(html .. "</body>", { max_lines = 3 }))
  end)

  it("answers nothing at all for a budget of nothing", function()
    assert.same({}, text("<body><p>something</p></body>", { max_lines = 0 }))
    assert.same({}, text("<body><p>something</p></body>", { max_lines = -1 }))
  end)

  it("answers nothing for a page that is only markup", function()
    assert.same({}, text("<body><div><span></span></div></body>"))
  end)
end)

describe("hover.preview.url.offline", function()
  -- The always-available half, unchanged by the page text above it: nothing
  -- here touches the network, and that is the promise `:Hover links web on`
  -- makes on its own.
  it("takes the URL apart without asking anyone", function()
    local content = url.offline({ type = "url", raw = "https://example.com/a/b?q=one%20two" })
    assert.same({ "example.com", "/a/b", "? q=one two" }, content.lines)
    assert.same("https", content.title)
  end)
end)
