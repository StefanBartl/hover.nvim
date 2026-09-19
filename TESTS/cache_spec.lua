---@diagnostic disable: need-check-nil
-- The test body is the guard; see the note in TESTS/bare_path_spec.lua
-- (`LLS-42`).

-- TESTS/cache_spec.lua -- the identity a preview is cached under.
--
-- `M.key` had no spec of its own before this file. The one property that
-- matters is completeness: every parameter that can change what a preview
-- says has to be part of the key, or two different questions get answered
-- with one cached content (`PERF-46`). `target.raw` alone is not enough --
-- `bare_path.split_location` strips a source's own `:line` suffix off it
-- before `classify` ever sees the string, so `init.lua:42` and
-- `init.lua:100` reach `M.key` as the exact same `target.raw`.

local cache = require("hover.cache")

describe("hover.cache.key (PERF-46)", function()
  local target

  before_each(function()
    target = { type = "file", raw = "init.lua", path = nil, anchor = nil }
  end)

  it("is stable for the same target and the same line", function()
    assert.equals(cache.key(target, { line = 42 }), cache.key(target, { line = 42 }))
  end)

  it("differs for two different lines of the same target", function()
    -- The exact bug: hovering `init.lua:42` then `init.lua:100` must not
    -- serve the second from the first's cache entry.
    assert.is_not.equal(cache.key(target, { line = 42 }), cache.key(target, { line = 100 }))
  end)

  it("differs between a target with a named line and one with none", function()
    assert.is_not.equal(cache.key(target), cache.key(target, { line = 42 }))
  end)

  it("differs for two different ranges sharing the same start line", function()
    assert.is_not.equal(
      cache.key(target, { line = 10, line_end = 20 }),
      cache.key(target, { line = 10, line_end = 30 })
    )
  end)

  it("ignores opts fields that are not line/line_end", function()
    -- `opts` is the whole `Hover.PreviewOpts` table -- only the two fields
    -- that change *which* window of the file is shown belong in the key.
    assert.equals(
      cache.key(target, { line = 42, max_lines = 20 }),
      cache.key(target, { line = 42, max_lines = 999 })
    )
  end)

  it("still answers with no opts at all, the pre-existing call shape", function()
    assert.equals("string", type(cache.key(target)))
  end)
end)
