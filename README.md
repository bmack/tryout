# TYPO3 tryout

Get a working TYPO3 development setup in minutes. Clone, `ddev start`, done.

**tryout** is a DDEV-based scaffold for people who want to contribute to TYPO3 Core,
test Gerrit patches, or develop custom extensions against the latest Core source — without
wrestling with manual setup. It is aimed at Core contributors, extension developers, and
anyone who wants to quickly spin up a TYPO3 instance backed by the actual Core repository.

## Quick Start

Pick a folder name for your project (e.g. `my-typo3-site`) and run:

```bash
git clone --depth=1 https://github.com/bmack/tryout.git my-typo3-site
cd my-typo3-site
rm -rf .git && git init
ddev start
```

The DDEV project name is derived from the folder, so `my-typo3-site` becomes
`https://my-typo3-site.ddev.site/`.

The `--depth=1` plus `git init` gives you a clean repository with no history,
ready to be pushed somewhere as your own project.
On the first run this will:

1. Clone the TYPO3 Core repository
2. Install all Composer dependencies
3. Set up a TYPO3 instance

Once finished, open the backend:

- **URL:** https://tryout.ddev.site/typo3/
- **User:** `admin` / `Password.1`

## Commands

Everything is accessed through a single `ddev tryout` entry point:

```text
ddev tryout status              Show project overview
ddev tryout download            Clone or update TYPO3 Core
ddev tryout download --reset    Hard reset Core to current branch
ddev tryout checkout <branch>   Switch TYPO3 version (main, 13.4, 12.4, ...)
ddev tryout composer            Regenerate composer.json from Core sysexts
ddev tryout patch <change-id>   Apply a Gerrit patch
ddev tryout patch               Apply all patches from config
ddev tryout reset               Reset Core to current branch + rebuild
ddev tryout delete              Wipe DB + fileadmin, fresh setup

ddev cs                         Prepare instance for Core contribution
ddev cs doctor                  Check hooks, template, and push URL
ddev cs uninstall               Remove hooks and reset push URL
```

## Contributing to TYPO3 Core

`ddev start` keeps the instance read-only against Gerrit — you can pull and
test patches but not submit them. Run **`ddev cs`** once to turn the instance
into a full contribution workspace:

```bash
ddev cs             # prompts for your review.typo3.org username
ddev cs setup jdoe  # or pass it explicitly
```

This is opt-in (nothing runs automatically on `ddev start`) and installs:

1. The **Gerrit `commit-msg` hook** — adds a `Change-Id` footer to every commit.
2. The **TYPO3 Core `pre-commit` hook** — runs CGL / PHP-CS-Fixer checks.
3. A **commit-message template** — wired via `commit.template`, opens a
   TYPO3-style skeleton (`[BUGFIX]`, `Resolves:`, `Releases:` …) whenever
   you run `git commit` without `-m`.
4. The **Gerrit SSH push URL** on `origin` — so `git push origin HEAD:refs/for/main`
   submits your change for review.

Check the state at any time:

```bash
ddev cs doctor
```

Doctor reports whether each piece is wired up and probes Gerrit SSH live
(requires a public key uploaded at https://review.typo3.org/settings/#SSHKeys).

The username is resolved from (in order): command argument → `TRYOUT_GERRIT_USER`
environment variable → cached `tryout.gerritUser` git config → interactive prompt.
To persist it across instances, set it in `.ddev/config.local.yaml`:

```yaml
web_environment:
  - TRYOUT_GERRIT_USER=jdoe
```

To revert everything:

```bash
ddev cs uninstall
```

## Working with Gerrit Patches

Apply a patch directly from [review.typo3.org](https://review.typo3.org) by its change number:

```bash
ddev tryout patch 56947
```

The latest patchset is resolved automatically via the Gerrit REST API,
fetched, and cherry-picked onto your local Core branch.

Check what is currently applied:

```bash
ddev tryout status
```

Start over:

```bash
ddev tryout reset
```

### Auto-Applying Patches

To have patches applied on every `ddev start` or `ddev restart`,
list their change IDs in `.ddev/config.patches.yaml`:

```yaml
web_environment:
  - TRYOUT_PATCHES=56947,12345
```

On start the Core is reset to the current branch and the listed patches
are cherry-picked in order.

## Switching TYPO3 Versions

By default tryout clones the `main` branch (latest development). To work
against a different major version:

```bash
ddev tryout checkout 13.4
```

This single command switches the Core branch, regenerates `composer.json`,
and rebuilds everything. Run without arguments to see all available branches.

Different TYPO3 versions ship different sets of system extensions.
`checkout` handles this automatically: a PHP script scans
`typo3-core/typo3/sysext/*/composer.json` and rewrites the `require`
section to match exactly what exists on disk.

You can also regenerate `composer.json` independently at any time:

```bash
ddev tryout composer
```

To pin the branch via environment variable (e.g. in `.ddev/config.local.yaml`):

```yaml
web_environment:
  - TRYOUT_BRANCH=13.4
```

## Custom Extensions

The `packages/` directory is a Composer path repository. Drop an extension
folder in there and require it:

```bash
ddev composer require myvendor/my-extension:@dev
ddev typo3 extension:setup
```

Composer resolves it from the local path — no Packagist publish required.
Run `ddev typo3 extension:setup` after every `composer require` to activate
the extension and run its database schema updates.
This makes it easy to develop an extension side-by-side with Core.

## Running Multiple Instances

The DDEV project name is derived from the folder name automatically
(`config.yaml` has no `name` field). Every clone or worktree gets its
own isolated DDEV project and URL — no extra configuration needed.

```bash
# Main checkout
git clone <this-repo> tryout
cd tryout && ddev start         # → project "tryout", https://tryout.ddev.site

# Worktree for a feature branch
git worktree add ../tryout-wip
cd ../tryout-wip && ddev start  # → project "tryout-wip", https://tryout-wip.ddev.site

# Separate clone
git clone <this-repo> tryout-v12
cd tryout-v12 && ddev start     # → project "tryout-v12", https://tryout-v12.ddev.site
```

Each instance has its own database, TYPO3 installation, and set of patches.

To use a custom name instead of the folder name:

```bash
ddev config --project-name=my-custom-name
ddev start
```

## How It Works

### Directory Layout

```text
tryout/
├── .ddev/
│   ├── commands/web/
│   │   ├── tryout                # The ddev tryout command
│   │   └── cs                    # Contribution-setup command (ddev cs)
│   ├── scripts/
│   │   ├── functions.sh          # Shared helpers (Gerrit API, patching, hooks)
│   │   ├── post-start.sh         # Runs on ddev start (clone, patch, setup)
│   │   └── sync-composer.php     # Regenerates composer.json from sysexts
│   ├── templates/
│   │   └── gitmessage.txt        # Commit-message template installed by `ddev cs`
│   ├── config.yaml               # DDEV settings (PHP, DB, env, hooks)
│   └── config.patches.yaml       # Gerrit patch list (optional)
├── config/system/additional.php  # TYPO3 DB + mail + GFX config for DDEV
├── packages/                     # Custom extensions (path repository)
├── composer.json                 # Path repos for Core sysexts + packages
└── typo3-core/                   # TYPO3 Core clone (gitignored, created on first start)
```

### Composer Path Repositories

`composer.json` declares two path repositories:

```json
{
  "repositories": [
    { "type": "path", "url": "packages/*" },
    { "type": "path", "url": "typo3-core/typo3/sysext/*", "options": { "symlink": true } }
  ]
}
```

Every system extension inside the Core clone is required at `@dev`. Composer
resolves them from the local path and creates symlinks, so any edit inside
`typo3-core/` is immediately active — no reinstall needed.

The same mechanism applies to `packages/*`: local extensions are symlinked
into `vendor/` and behave as if they were installed from Packagist.

### DDEV Configuration

- **`config.yaml`** — tracked in git, contains all shared settings:
  PHP 8.4, MariaDB 10.11, Apache, Node 22, environment variables,
  and the post-start hook. The `name` field is omitted so DDEV derives
  the project name from the folder — this is what makes worktrees work.
- **`config.patches.yaml`** — tracked in git, defines `TRYOUT_PATCHES` for
  auto-applying Gerrit changes on start.
- **`config.local.yaml`** — gitignored, for personal overrides (PHP version,
  xdebug, etc.). DDEV merges it on top of `config.yaml`.

### Post-Start Hook

On every `ddev start` the post-start script runs inside the web container:

1. **Clone** — if `typo3-core/` does not exist, clones from GitHub and adds a
   Gerrit remote.
2. **Patch** — if `TRYOUT_PATCHES` is set, resets Core to the current branch
   and cherry-picks each change via the Gerrit REST API.
3. **Composer install** — resolves all dependencies from the path repositories.
4. **TYPO3 setup** — on first run, creates `settings.php` and sets up the database.
5. **Extension setup + cache flush** — activates extensions and clears caches.

### Gerrit Integration

Patches are resolved through the Gerrit REST API at `https://review.typo3.org`.
Given a change number (e.g. `56947`), the API returns the latest patchset ref
(e.g. `refs/changes/47/56947/12`). That ref is fetched and cherry-picked.

Merged or abandoned changes are detected and skipped. Conflicts abort the
cherry-pick automatically and report the failure.

## Requirements

- [DDEV](https://ddev.readthedocs.io/en/stable/) v1.24+
- Docker Desktop or Colima
- Git

## Contributing

tryout itself lives at [github.com/bmack/tryout](https://github.com/bmack/tryout).
If you have improvements to the scaffold — better defaults, new `ddev tryout`
subcommands, fixes to the post-start hook, documentation tweaks — pull requests
and issues are welcome there.

Note that contributions to **TYPO3 Core** itself do not go through this repo.
Core development happens on [review.typo3.org](https://review.typo3.org) via Gerrit.
tryout is just a local environment for working on Core; once you have a patch ready,
push it to Gerrit as usual.

## License

MIT — see [LICENSE](LICENSE).
