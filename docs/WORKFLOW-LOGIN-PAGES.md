# Workflow — a link that shows a login page

You hover a link and the float shows a single-sign-on form, a "please log in"
page, or nothing useful at all. This page is the whole path from there to
something worth reading: what is going on, which of three tools answers it, how
to set each one up, and how to find out which step is failing.

For the reasoning behind each tool, see [PINS.md](FEATURES/PINS.md),
[AUTH.md](FEATURES/AUTH.md) and [SHOT.md](FEATURES/SHOT.md). For the day-to-day
side of the plugin, see [WORKFLOW.md](WORKFLOW.md).

---

## Why the hover shows a login page

**The hover is anonymous, and that is deliberate.** Every way it can look at a
link starts without your cookies:

| Way of looking | Why it has no session |
| --- | --- |
| text preview (`links.fetch`) | one `curl` request with no cookies and no headers of yours |
| PDF download (`links.pdf`) | the same, written to a file |
| page render (`links.shot`) | a headless browser started with a **throwaway profile**, because without one it could open your real profile and send your cookies to the hovered host |

A page behind single sign-on therefore answers all three with the login form.
No renderer is "better" at this; the request is simply from nobody.

There are three ways out. They are not alternatives for the same job — each
fits a different kind of link.

## Pick the tool

```text
Does the link answer with a document (PDF export, attachment)?
├── yes ──> authenticate the request          (links.auth, then links.pdf)
└── no, it is a page
    └── do you know what it looks like?
        ├── yes ──> pin a PDF or PNG of it    (links.pins)
        └── no ──> open it in the browser     (<CR> on the float)
```

| Tool | Shows | Needs | Cost |
| --- | --- | --- | --- |
| **Pin** — `links.pins` | a file you made, as that link | a PDF/PNG you saved once | nothing leaves the machine |
| **Auth** — `links.auth` | the real document, first page | an API token, `links.fetch` and `links.pdf` on | one extra request per link |
| **Open** — `<CR>` | the real page, in your own browser | nothing | leaves Neovim |

What no tool does: render a *logged-in page* inside the float. A page that is a
JavaScript application (Confluence, Jira) answers an authenticated request with
the same application, and the browser render has no session. For a page as it
looks, pin it.

---

## Recipe 1 — pin a page

Use this when the link is a page and you know what it looks like.

1. **Make the file.** In the browser, open the page while logged in, then either
   print it to PDF (`Ctrl+P`, destination *Save as PDF*) or take a full-page
   screenshot (DevTools: `Ctrl+Shift+P`, *Capture full size screenshot*).
2. **Put it somewhere stable**, for example `~/hover-pins/`.
3. **Add the pin:**

   ```lua
   require("hover").setup({
     links = {
       pins = {
         { match = "wiki.example.com/display/TEAM/*", show = "~/hover-pins/team.pdf" },
         { match = { "wiki.example.com/a", "wiki.example.com/b" }, show = "~/hover-pins/ab.png" },
       },
     },
   })
   ```

4. **Hover the link.** A PDF is paged with `<C-Down>` / `<C-Up>` and magnified
   with `>`; `F` takes the whole screen.

How `match` works — it is a glob with one wildcard:

| You write | It matches |
| --- | --- |
| `wiki.example.com` | that host, any path — and **not** `wiki.example.com.evil.net` |
| `*.example.com` | every subdomain |
| `example.com/wiki/*` | host + path prefix (`*` crosses `/`) |
| `example.com/view?id=42` | one page; `?` is a literal question mark |

Scheme, `#fragment` and case never matter. The first pin that matches wins, so
put the specific one before the general one. `show` expands `~` and environment
variables; a relative path is relative to your Neovim config directory.

Pins need no switch and work with `links.web = false`: a pinned link is read
from disk. A pinned PDF or image opens by itself; any other file type opens on
`:Hover show`.

**Things to know:**

- A pinned link does not update. When the page changes, make the file again.
- If the file is gone the float says `pinned file not found (links.pins: …)`
  instead of falling back to the login page.
- `<CR>` on a pinned float opens the **real URL**, not the file.

## Recipe 2 — authenticate a document download

Use this when the link answers with `application/pdf`: a PDF export of a page,
or an attachment.

1. **Create a token** in the service. For Atlassian Cloud:
   <https://id.atlassian.com/manage-profile/security/api-tokens> → *Create API
   token*. For a Data Center Confluence: profile → *Settings* → *Personal Access
   Tokens*. Copy it when it is shown; it is shown once.
2. **Store it as an environment variable**, never in a file in a repository:

   ```powershell
   setx CONFLUENCE_TOKEN "<the token>"
   ```

   then restart Neovim — a running session keeps the environment it started with.
3. **Add the rule and turn the pieces on:**

   ```lua
   require("hover").setup({
     links = {
       web = true,
       fetch = true,
       pdf = { enabled = true },
       auth = {
         -- Atlassian Cloud: HTTP Basic, account email + API token.
         { match = "acme.atlassian.net", user = "me@acme.com", token_env = "CONFLUENCE_TOKEN" },
         -- Data Center: Bearer, a personal access token (no `user`).
         { match = "wiki.acme.com", token_env = "WIKI_PAT" },
       },
     },
   })
   ```

4. **Check it:** `:checkhealth hover` reports each rule and whether its variable
   is set (never the value).

What the rules enforce, so that a mistake sends *nothing* rather than too much:

- The token is read from the **variable named by `token_env`**; there is no
  field for the token itself.
- The **host part of `match` has no wildcard.** `*.atlassian.net` would hand
  your token to every Atlassian tenant, including an attacker's; such a rule is
  skipped. The path part may use `*`.
- **HTTPS only**, and redirects may only go to https.
- The credential reaches `curl` on **stdin**, never on a command line.
- It is **not** used by `links.shot`.

Before blaming the plugin, test the request itself:

```bash
curl -sS -o /dev/null -w "%{http_code} %{content_type}\n" \
  -u "me@acme.com:$CONFLUENCE_TOKEN" "https://acme.atlassian.net/wiki/..."
```

`200 application/pdf` (or a redirect ending there) means the hover can do it
too. `401`/`403` means the token, the email or the permissions — not hover.nvim.

A downloaded document is cached under `stdpath("cache")/hover.nvim/webpdf` for
`links.pdf.cache_days`. A document you needed a token for is therefore on disk
for that long.

## Recipe 3 — just open it

`<CR>` on the float opens the link in your default opener, which is your own
browser with your own session. For a page you only need to look at once, this is
often the right answer and costs nothing to set up.

---

## When it does not work

Work from the position to the installation:

| Symptom | Ask | Usually |
| --- | --- | --- |
| nothing hovers on a URL | `:Hover why` | `links.web` is off and no pin matches. Pins make a URL findable; an unpinned one is still refused |
| a pin is ignored | `require("hover.pins").matches(url, glob)` | the glob: a `/` makes it match host + path, no `/` host only; the first match wins |
| `pinned file not found` | `:checkhealth hover` | the file moved; health lists every pin whose file is missing |
| auth sends nothing | `:checkhealth hover` | the variable is unset in *this* Neovim (restart after `setx`), or the rule was skipped for a wildcard host |
| auth rule skipped | `:checkhealth hover` | a `*` in the host part, or a `token_env` that is not a variable name |
| still a login form | the `curl` test above | the URL is a page, not a document — pin it |
| `HTTP 401` in the float | the `curl` test above | wrong email, expired token, or the token was revoked |

`:Hover why` says `pinned: …` when a pin is what a hover is showing.

## What this does not cover

- **Cookie-based sessions.** The plugin never reads your browser's cookies:
  Chrome encrypts them to the application, and handing them to a page-running
  browser is the leak the throwaway profile prevents.
- **OAuth flows.** A token that has to be refreshed per request (Microsoft 365,
  SharePoint) is not a static value an environment variable can hold. Pin the
  page instead.
- **A logged-in browser render.** A persistent, separate browser profile that
  you log in to once is possible in principle and not built; the cost is a
  session that expires and private page content in the cache.
