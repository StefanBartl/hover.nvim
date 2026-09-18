---@diagnostic disable: need-check-nil
-- The test body is the guard; see the note in TESTS/bare_path_spec.lua
-- (`LLS-42`).

-- TESTS/bare_url_spec.lua -- finding a URL by shape in plain text, with no
-- link syntax to lean on.
--
-- Everything interesting here is byte-offset arithmetic: `M.spans` hands
-- back 0-based `col`/`col_end` the same way `nvim_win_get_cursor` reports
-- them, and `M.under_cursor` compares one against the other directly with no
-- conversion in between. A one-off in either direction, or a switch to
-- display columns on a line with any multibyte text, would silently move
-- the hover to the wrong end of the URL rather than error -- so both the
-- pure span-finder and the cursor comparison are asserted here, in bytes.
--
-- This module had no dedicated spec before this file: every other spec that
-- exercises the bare-URL source does so through `hover.target_under_cursor`,
-- never by asking what `M.spans` itself decided a span's bounds were.

local bare_url = require("hover.bare_url")

describe("hover.bare_url.spans", function()
  it("finds a plain https URL and reports 0-based byte bounds", function()
    local line = "see https://example.com for it"
    local spans = bare_url.spans(line)
    assert.equals(1, #spans)
    assert.equals("https://example.com", spans[1].url)
    -- "see " is 4 bytes, so the URL starts at 0-based column 4.
    assert.equals(4, spans[1].col)
    assert.equals(4 + #"https://example.com" - 1, spans[1].col_end)
  end)

  it("accepts the Windows backslash typo for a scheme separator", function()
    local spans = bare_url.spans([[see http:\\example.com\a\b here]])
    assert.equals(1, #spans)
    assert.equals([[http:\\example.com\a\b]], spans[1].url)
  end)

  it("finds a mailto: link", function()
    local spans = bare_url.spans("write to mailto:someone@example.com now")
    assert.equals(1, #spans)
    assert.equals("mailto:someone@example.com", spans[1].url)
  end)

  it("finds a www.host with no scheme", function()
    local spans = bare_url.spans("see www.example.com/a for it")
    assert.equals(1, #spans)
    assert.equals("www.example.com/a", spans[1].url)
  end)

  it("returns an empty list for a line with no URL shape, and for an empty line", function()
    assert.same({}, bare_url.spans("just plain prose, nothing to see"))
    assert.same({}, bare_url.spans(""))
  end)

  it("strips trailing sentence punctuation that is never part of the URL", function()
    local spans = bare_url.spans("see https://example.com/a.")
    assert.equals("https://example.com/a", spans[1].url)
  end)

  it("keeps a closing paren the URL itself opened", function()
    local spans = bare_url.spans("(see https://en.wikipedia.org/wiki/Vim_(text_editor))")
    assert.equals("https://en.wikipedia.org/wiki/Vim_(text_editor)", spans[1].url)
  end)

  it("drops a closing paren that belongs to the surrounding prose, not the URL", function()
    local spans = bare_url.spans("(see https://example.com/a)")
    assert.equals("https://example.com/a", spans[1].url)
  end)

  it("does not re-report the www. tail of a URL the https pattern already claimed", function()
    -- `www.` sits inside `https://www.example.com`; the looser pattern must
    -- not produce a second, overlapping span for the same text.
    local spans = bare_url.spans("see https://www.example.com/a for it")
    assert.equals(1, #spans)
    assert.equals("https://www.example.com/a", spans[1].url)
  end)

  it("finds two separate URLs on the same line, each with its own bounds", function()
    local line = "https://a.example.com and https://b.example.com"
    local spans = bare_url.spans(line)
    assert.equals(2, #spans)
    assert.equals("https://a.example.com", spans[1].url)
    assert.equals("https://b.example.com", spans[2].url)
    assert.is_true(spans[2].col > spans[1].col_end)
  end)

  it("requires a two-character scheme, so a Windows drive letter is not read as one", function()
    -- `C:\Users\me` is a one-letter "scheme" followed by a backslash
    -- separator -- exactly what the two-or-more-character rule in the module
    -- doc exists to exclude. Confirmed here rather than only in classify_spec,
    -- since this is the module that would otherwise offer it to the URL
    -- previewer.
    assert.same({}, bare_url.spans([[open C:\Users\me\file.txt now]]))
  end)
end)

describe("hover.bare_url.under_cursor", function()
  local api = vim.api
  local win, prev_buf, buf

  before_each(function()
    win = api.nvim_get_current_win()
    prev_buf = api.nvim_win_get_buf(win)
    buf = api.nvim_create_buf(false, true)
    api.nvim_win_set_buf(win, buf)
  end)

  after_each(function()
    pcall(api.nvim_win_set_buf, win, prev_buf)
    pcall(api.nvim_buf_delete, buf, { force = true })
  end)

  ---@param line string
  ---@param marker string substring whose first byte the cursor lands on
  ---@return Hover.Source|nil
  local function source_at(line, marker)
    api.nvim_buf_set_lines(buf, 0, -1, false, { line })
    local at = line:find(marker, 1, true)
    api.nvim_win_set_cursor(win, { 1, at - 1 })
    return bare_url.under_cursor(buf)
  end

  it("answers when the cursor sits anywhere inside the URL span, start through end", function()
    local line = "see https://example.com/a for it"
    api.nvim_buf_set_lines(buf, 0, -1, false, { line })
    local span = bare_url.spans(line)[1]

    api.nvim_win_set_cursor(win, { 1, span.col })
    local at_start = bare_url.under_cursor(buf)
    assert.is_not_nil(at_start)
    assert.equals("https://example.com/a", at_start.target)
    assert.equals("bare_url", at_start.kind)

    -- The inclusive upper bound (`col_end`) is exactly what a byte/display
    -- mismatch would get wrong first: land on the URL's very last byte.
    api.nvim_win_set_cursor(win, { 1, span.col_end })
    local at_end = bare_url.under_cursor(buf)
    assert.is_not_nil(at_end)
    assert.equals("https://example.com/a", at_end.target)
  end)

  it("answers nil when the cursor sits one byte past col_end", function()
    local line = "see https://example.com/a for it"
    api.nvim_buf_set_lines(buf, 0, -1, false, { line })
    local span = bare_url.spans(line)[1]

    api.nvim_win_set_cursor(win, { 1, span.col_end + 1 })
    assert.is_nil(bare_url.under_cursor(buf))
  end)

  it("answers nil on a line with prose but no URL shape", function()
    assert.is_nil(source_at("nothing to see here", "nothing"))
  end)

  it("answers nil when the buffer given is not the one in the current window", function()
    local other = api.nvim_create_buf(false, true)
    api.nvim_buf_set_lines(other, 0, -1, false, { "see https://example.com for it" })
    assert.is_nil(bare_url.under_cursor(other))
    pcall(api.nvim_buf_delete, other, { force = true })
  end)

  it(
    "reports the col/col_end it returns in the same 0-based byte units nvim_win_get_cursor uses",
    function()
      local line = "x https://example.com y"
      local src = source_at(line, "https")
      -- "x " is 2 bytes, so the URL's 0-based start column is 2.
      assert.equals(2, src.col)
      assert.equals(2 + #"https://example.com" - 1, src.col_end)
    end
  )
end)
