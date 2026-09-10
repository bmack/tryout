# Browser tests

Opt-in. The bats suites remain the default gate; nothing here runs unless you ask.

These answer one question bats cannot: **does the TYPO3 backend of each served
worktree actually log in?** A URL returning 200 does not prove that — the login
posts a form, sets a secure session cookie and redirects into a module. Getting
that wrong is invisible to `curl`, and this suite caught exactly such a bug: a
served site whose vhost never told PHP the request was TLS dropped to `http://`,
so the cookie was never returned and login failed with "Please activate Cookies".

## Running them

```bash
cd tests/e2e
npm install
npx playwright install chromium        # ~150 MB, once

TRYOUT_PROJECT=~/path/to/your-tryout-project npm test
```

`TRYOUT_PROJECT` must point at a provisioned DDEV project with at least one served
worktree. Without it every test skips with a message rather than failing.

The sites under test are discovered from `ddev tryout worktree list`, so serving
another worktree is covered without editing anything here.

## Why it is not in the default suite

The repository has no build step and no Node tooling; `package.json`, `node_modules`
and a browser download are a large dependency for one class of check. Keeping this
directory self-contained means someone who never runs it pays nothing.
