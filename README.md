# TYPO3 tryout

Get a working TYPO3 development setup in minutes. Clone, `make init`, done.

**tryout** is a DDEV-based scaffold for people who want to contribute to TYPO3 Core,
test Gerrit patches, or develop custom extensions against the latest Core source — without
wrestling with manual setup. It is aimed at Core contributors, extension developers, and
anyone who wants to quickly spin up a TYPO3 instance backed by the actual Core repository.

## Quick Start

```bash
git clone <this-repo> tryout
cd tryout
make init
```

On the first run this will:

1. Create a DDEV project named after your folder
2. Clone the TYPO3 Core repository
3. Install all Composer dependencies
4. Set up a TYPO3 instance

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
ddev tryout patch <change-id>   Apply a Gerrit patch
ddev tryout patch               Apply all patches from config
ddev tryout reset               Reset Core to current branch + rebuild
ddev tryout delete              Wipe DB + fileadmin, fresh setup
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

On start the Core is reset to `origin/main` and the listed patches
are cherry-picked in order.

## Switching TYPO3 Versions

By default tryout clones the `main` branch (latest development). To work
against a different major version:

```bash
# 1. Switch the Core clone to the desired branch
ddev tryout checkout 13.4

# 2. Regenerate composer.json to match that branch's system extensions
make composer

# 3. Install the updated dependencies
ddev composer install
```

Different TYPO3 versions ship different sets of system extensions.
`make composer` scans `typo3-core/typo3/sysext/` and rewrites the `require`
section of `composer.json` to match exactly what exists on disk — no manual
editing needed.

Run `ddev tryout checkout` without arguments to see all available branches.

You can also pin the branch via environment variable in a DDEV config override
(e.g. `.ddev/config.local.yaml`):

```yaml
web_environment:
  - TRYOUT_BRANCH=13.4
```

## Custom Extensions

The `packages/` directory is a Composer path repository. Drop an extension
folder in there and require it:

```bash
ddev composer require myvendor/my-extension:@dev
```

Composer resolves it from the local path — no Packagist publish required.
This makes it easy to develop an extension side-by-side with Core.

## Running Multiple Instances

The DDEV project name is derived from the folder name. Because `.ddev/config.yaml`
is gitignored and generated per-instance by `make init`, every clone or
worktree gets its own isolated DDEV project and URL.

```bash
# Main checkout
git clone <this-repo> tryout
cd tryout && make init          # → project "tryout", https://tryout.ddev.site

# Worktree for a feature branch
git worktree add ../tryout-wip
cd ../tryout-wip && make init   # → project "tryout-wip", https://tryout-wip.ddev.site

# Separate clone
git clone <this-repo> tryout-v12
cd tryout-v12 && make init      # → project "tryout-v12", https://tryout-v12.ddev.site
```

Each instance has its own database, TYPO3 installation, and set of patches.

## How It Works

### Directory Layout

```text
tryout/
├── .ddev/
│   ├── commands/web/tryout       # The ddev tryout command
│   ├── scripts/
│   │   ├── functions.sh          # Shared helpers (Gerrit API, patching, rebuild)
│   │   └── post-start.sh        # Runs on ddev start (clone, patch, setup)
│   ├── config.tryout.yaml        # Shared DDEV settings (PHP, DB, env)
│   └── config.patches.yaml       # Gerrit patch list (optional)
├── config/system/additional.php  # TYPO3 DB + mail + GFX config for DDEV
├── packages/                     # Custom extensions (path repository)
├── composer.json                 # Path repos for Core sysexts + packages
├── Makefile                      # make init → creates config.yaml + starts DDEV
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

### DDEV Configuration Split

DDEV merges all `config.*.yaml` files on top of `config.yaml`:

- **`config.yaml`** — contains only `name: <foldername>`, gitignored, generated
  by `make init`. This is what makes multiple instances possible.
- **`config.tryout.yaml`** — tracked in git, holds all shared settings:
  PHP 8.4, MariaDB 10.11, Apache, Node 22, environment variables, and the
  post-start hook.
- **`config.patches.yaml`** — tracked in git, defines `TRYOUT_PATCHES` for
  auto-applying Gerrit changes.

### Post-Start Hook

On every `ddev start` the post-start script runs inside the web container:

1. **Clone** — if `typo3-core/` does not exist, clones from GitHub and adds a
   Gerrit remote.
2. **Patch** — if `TRYOUT_PATCHES` is set, resets Core to `origin/main` and
   cherry-picks each change via the Gerrit REST API.
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
- Make
