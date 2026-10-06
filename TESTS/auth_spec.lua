---@diagnostic disable: need-check-nil
-- The test body is the guard; see the note in TESTS/bare_path_spec.lua
-- (`LLS-42`).

-- TESTS/auth_spec.lua -- `links.auth`: a credential for the hosts the reader
-- named, and for no one else.
--
-- **Every case here is a way to leak a token**, so each one asserts the
-- *absence* of the credential as hard as the presence:
--
--   1. **The host glob has no wildcard.** `*.example.net` would hand the token
--      to every tenant, an attacker's included; such a rule is skipped.
--   2. **Lookalike hosts get nothing**: a longer host, a userinfo trick, the
--      host written into another host's path.
--   3. **HTTPS only.**
--   4. **The token is never in argv**, in either request that carries it.
--   5. **Redirects are held to https.**
--   6. **An unset variable sends nothing** -- and does not fall through to the
--      next rule.

local config = require("hover.config")
local auth = require("hover.auth")
local uv = vim.uv or vim.loop

local TOKEN = "s3cr3t-token-value"

describe("hover.auth", function()
  before_each(function()
    config.reset()
    uv.os_setenv("HOVER_TEST_TOKEN", TOKEN)
    uv.os_unsetenv("HOVER_TEST_UNSET")
  end)

  after_each(function()
    config.reset()
    uv.os_unsetenv("HOVER_TEST_TOKEN")
  end)

  ---@param rules_ table[]
  local function rules(rules_)
    config.setup({ links = { auth = rules_ } })
  end

  describe("which rules are usable", function()
    it("is empty by default and sends nothing", function()
      assert.same({}, auth.list())
      assert.is_nil(auth.for_url("https://acme.atlassian.net/wiki"))
    end)

    it("refuses a wildcard in the host part, which would hand out the token", function()
      rules({
        { match = "*.atlassian.net", token_env = "HOVER_TEST_TOKEN" },
        { match = "acme.*", token_env = "HOVER_TEST_TOKEN" },
        { match = "acme.atlassian.net*", token_env = "HOVER_TEST_TOKEN" },
        { match = "*", token_env = "HOVER_TEST_TOKEN" },
      })
      assert.same({}, auth.list())
      assert.is_nil(auth.for_url("https://evil.atlassian.net/x"))
    end)

    it("allows a wildcard in the path part", function()
      rules({ { match = "acme.atlassian.net/wiki/*", token_env = "HOVER_TEST_TOKEN" } })
      assert.equals(1, #auth.list())
      assert.is_truthy(auth.for_url("https://acme.atlassian.net/wiki/spaces/A"))
      assert.is_nil(auth.for_url("https://acme.atlassian.net/jira/x"))
    end)

    it("is all or nothing for a rule with a list of globs", function()
      rules({
        { match = { "acme.atlassian.net", "*.atlassian.net" }, token_env = "HOVER_TEST_TOKEN" },
      })
      assert.same({}, auth.list(), "a half-applied credential rule must not survive")
    end)

    it("skips a rule without a usable token variable name or user", function()
      rules({
        { match = "a.example.com" },
        { match = "b.example.com", token_env = "not a name" },
        { match = "c.example.com", token_env = "HOVER_TEST_TOKEN", user = "" },
        { match = "d.example.com", token_env = 5 },
        "x",
      })
      assert.same({}, auth.list())
    end)

    it("is replaced, not merged, by a second setup", function()
      rules({
        { match = "a.example.com", token_env = "HOVER_TEST_TOKEN" },
        { match = "b.example.com", token_env = "HOVER_TEST_TOKEN" },
      })
      assert.equals(2, #auth.list())
      rules({ { match = "a.example.com", token_env = "HOVER_TEST_TOKEN" } })
      assert.equals(1, #auth.list())
    end)
  end)

  describe("which URLs get the credential", function()
    before_each(function()
      rules({
        { match = "acme.atlassian.net", user = "me@acme.com", token_env = "HOVER_TEST_TOKEN" },
      })
    end)

    it("gives the host its credential, with the token read from the environment", function()
      local credential = auth.for_url("https://acme.atlassian.net/wiki/spaces/A/pages/1")
      assert.equals("me@acme.com", credential.user)
      assert.equals(TOKEN, credential.token)
    end)

    it("gives nothing to a lookalike host", function()
      assert.is_nil(auth.for_url("https://acme.atlassian.net.evil.com/wiki"))
      assert.is_nil(auth.for_url("https://acme.atlassian.net@evil.com/wiki"))
      assert.is_nil(auth.for_url("https://evil.com/acme.atlassian.net"))
      assert.is_nil(auth.for_url("https://xacme.atlassian.net/wiki"))
      assert.is_nil(auth.for_url("https://other.atlassian.net/wiki"))
    end)

    it("never sends it over http", function()
      assert.is_nil(auth.for_url("http://acme.atlassian.net/wiki"))
      assert.is_nil(auth.for_url("ftp://acme.atlassian.net/wiki"))
    end)

    it("sends nothing when the variable is unset, and does not try the next rule", function()
      rules({
        { match = "acme.atlassian.net", token_env = "HOVER_TEST_UNSET" },
        { match = "acme.atlassian.net", token_env = "HOVER_TEST_TOKEN" },
      })
      assert.is_nil(auth.for_url("https://acme.atlassian.net/wiki"))
    end)
  end)

  describe("how it reaches curl", function()
    it("is HTTP Basic with a user, and Bearer without", function()
      rules({
        { match = "cloud.example.com", user = "me@acme.com", token_env = "HOVER_TEST_TOKEN" },
        { match = "dc.example.com", token_env = "HOVER_TEST_TOKEN" },
      })

      local basic = { raw_args = { "-L" } }
      assert.is_true(auth.apply("https://cloud.example.com/x", basic))
      assert.same({ user = "me@acme.com", pass = TOKEN }, basic.auth)
      assert.is_nil(basic.bearer_token)

      local bearer = {}
      assert.is_true(auth.apply("https://dc.example.com/x", bearer))
      assert.equals(TOKEN, bearer.bearer_token)
      assert.is_nil(bearer.auth)
    end)

    it("holds redirects to https, and keeps what the request already had", function()
      rules({
        { match = "cloud.example.com", user = "me@acme.com", token_env = "HOVER_TEST_TOKEN" },
      })
      local request = { raw_args = { "-L", "--max-filesize", "2000000" } }
      auth.apply("https://cloud.example.com/x", request)
      assert.same(
        { "-L", "--max-filesize", "2000000", "--proto-redir", "=https" },
        request.raw_args
      )
    end)

    it("leaves a request for any other host untouched", function()
      rules({
        { match = "cloud.example.com", user = "me@acme.com", token_env = "HOVER_TEST_TOKEN" },
      })
      local request = { raw_args = { "-L" } }
      assert.is_false(auth.apply("https://elsewhere.example.com/x", request))
      assert.same({ raw_args = { "-L" } }, request)
    end)

    it("writes a curl config for a caller that builds its own command line", function()
      rules({
        { match = "cloud.example.com", user = "me@acme.com", token_env = "HOVER_TEST_TOKEN" },
        { match = "dc.example.com", token_env = "HOVER_TEST_TOKEN" },
      })
      assert.equals(
        ('user = "me@acme.com:%s"\n'):format(TOKEN),
        auth.stdin("https://cloud.example.com/x")
      )
      assert.equals(
        ('header = "Authorization: Bearer %s"\n'):format(TOKEN),
        auth.stdin("https://dc.example.com/x")
      )
      assert.is_nil(auth.stdin("https://elsewhere.example.com/x"))
    end)
  end)

  describe("the two requests that carry it", function()
    local real_curl, real_system, captured

    before_each(function()
      rules({
        { match = "cloud.example.com", user = "me@acme.com", token_env = "HOVER_TEST_TOKEN" },
      })
      captured = nil
      real_curl = package.loaded["lib.nvim.net.curl"]
      real_system = vim.system
    end)

    after_each(function()
      package.loaded["lib.nvim.net.curl"] = real_curl
      vim.system = real_system
    end)

    ---@param value any
    ---@return boolean
    local function in_argv(value)
      return vim.inspect(value):find(TOKEN, 1, true) ~= nil
    end

    it("hands the fetch the credential through curl's own option, not a header in argv", function()
      local real = require("lib.nvim.net.curl")
      package.loaded["lib.nvim.net.curl"] = setmetatable({
        fetch_raw = function(url, request)
          captured = { url = url, request = request }
        end,
      }, { __index = real })
      local url = require("hover.preview.url")
      url.reset()

      local classify = require("hover.classify")
      url.fetch(classify.classify("https://cloud.example.com/wiki/x", nil), {}, function() end)

      assert.equals("https://cloud.example.com/wiki/x", captured.url)
      assert.same({ user = "me@acme.com", pass = TOKEN }, captured.request.auth)
      assert.is_nil(captured.request.headers.Authorization)
      assert.is_false(in_argv(captured.request.raw_args))
      assert.is_true(vim.tbl_contains(captured.request.raw_args, "--proto-redir"))

      url.reset()
      url.fetch(classify.classify("https://other.example.com/", nil), {}, function() end)
      assert.is_nil(captured.request.auth)
      assert.is_nil(captured.request.bearer_token)
    end)

    it("downloads a document with the credential on stdin and never in argv", function()
      vim.system = function(argv, opts)
        captured = { argv = argv, opts = opts }
        return {}
      end
      local webpdf = require("hover.preview.webpdf")
      webpdf.reset()

      local classify = require("hover.classify")
      local target =
        classify.classify("https://cloud.example.com/report-" .. uv.hrtime() .. ".pdf", nil)
      webpdf.preview(
        target,
        { headers = { ["content-type"] = "application/pdf", ["content-length"] = "1000" } },
        { url_pdf_max_bytes = 25000000 },
        function() end
      )

      assert.is_truthy(captured, "the download was not started")
      assert.is_false(in_argv(captured.argv), "the token is on the command line")
      assert.equals(('user = "me@acme.com:%s"\n'):format(TOKEN), captured.opts.stdin)
      assert.is_true(vim.tbl_contains(captured.argv, "-K"))
      assert.is_true(vim.tbl_contains(captured.argv, "--proto-redir"))

      captured = nil
      webpdf.reset()
      local other = classify.classify("https://other.example.com/r-" .. uv.hrtime() .. ".pdf", nil)
      webpdf.preview(
        other,
        { headers = { ["content-type"] = "application/pdf", ["content-length"] = "1000" } },
        { url_pdf_max_bytes = 25000000 },
        function() end
      )
      assert.is_nil(captured.opts.stdin)
      assert.is_false(vim.tbl_contains(captured.argv, "-K"))
    end)
  end)
end)
