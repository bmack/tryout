[![add-on registry](https://img.shields.io/badge/DDEV-Add--on_Registry-blue)](https://addons.ddev.com)
[![tests](https://github.com/bmack/tryout/actions/workflows/tests.yml/badge.svg?branch=main)](https://github.com/bmack/tryout/actions/workflows/tests.yml?query=branch%3Amain)
[![last commit](https://img.shields.io/github/last-commit/bmack/tryout)](https://github.com/bmack/tryout/commits)
[![release](https://img.shields.io/github/v/release/bmack/tryout)](https://github.com/bmack/tryout/releases/latest)

# TYPO3 tryout

Get a working TYPO3 development setup in minutes — backed by the real TYPO3 Core
git repository, with Gerrit patches one command away.

**tryout** is a DDEV add-on for people who want to contribute to TYPO3 Core, test
Gerrit patches, or develop custom extensions against the latest Core source — without
wrestling with manual setup. It is aimed at Core contributors, extension developers, and
anyone who wants to quickly spin up a TYPO3 instance backed by the actual Core repository.

## Quick Start

Pick a folder name for your project (e.g. `my-typo3-site`) and run:

```bash
mkdir my-typo3-site && cd my-typo3-site
ddev config --project-type=typo3 --docroot=public --php-version=8.5
ddev add-on get bmack/tryout
ddev start
```

On the first run this will:

1. Clone the TYPO3 Core repository into `typo3-core/`
2. Resolve every Core system extension through Composer
3. Set up a TYPO3 instance

Once finished, open the backend:

- **URL:** `https://my-typo3-site.ddev.site/typo3/`
- **User:** `admin` / `Password.1`

To update the add-on later, run `ddev add-on get bmack/tryout` again; to remove it,
`ddev add-on remove tryout`.

### Optional but recommended

Two host tools make the add-on considerably nicer to use. Neither is installed by the
add-on, and **everything works without them** — install them because they improve the
experience, not because anything depends on them.

**[gum](https://github.com/charmbracelet/gum)** — draws the tables, prompts and
spinners. With it, `ddev tryout worktree list` is a real table, `ddev tryout status` a
bordered report, and any command missing an argument offers a pick-from-a-list chooser
instead of asking you to type the answer. Without it every command prints the same
information as plain text with a typed prompt; the unit suite runs both ways in CI, so
the no-gum path stays honest. Installation mentions it once and carries on.

```bash
brew install gum              # macOS
sudo apt-get install gum      # Debian/Ubuntu
sudo dnf install gum          # Fedora
sudo pacman -S gum            # Arch
```

**[herdr](https://herdr.dev)** — a terminal multiplexer built around coding agents,
needed only for `ddev tryout herdr`. That one command opens each Core worktree as its
own workspace, with a Claude tab, a shell and a command panel all rooted at that
worktree — see [Opening worktrees in herdr](#opening-worktrees-in-herdr). It also needs
[`jq`](https://jqlang.github.io/jq/download/), because herdr answers in JSON. Without
either, `ddev tryout herdr` exits with the install command for your platform and every
other command is unaffected.

```bash
# macOS
brew install herdr jq

# everywhere else — plus jq from your package manager
curl -fsSL https://herdr.dev/install.sh | sh
```

No Linux distribution packages herdr, so the installer — not an `apt-get` line that
would fail — is the honest answer there. See [herdr's install
docs](https://herdr.dev/docs/install/) for the details.

### Installing from the repository

`ddev add-on get` takes a local directory, a GitHub repo or a tarball URL, so you can
install an unreleased version — a branch, a commit, or a working checkout — the same
way you install a release.

**From a local checkout** — what you want when developing the add-on itself. No
commit, push or release is needed; DDEV copies the working tree as it is:

```bash
git clone https://github.com/bmack/tryout.git ~/src/tryout

mkdir my-typo3-site && cd my-typo3-site
ddev config --project-type=typo3 --docroot=public --php-version=8.5
ddev add-on get ~/src/tryout
ddev start
```

Re-run `ddev add-on get ~/src/tryout` after every change you want to try; it
overwrites the installed payload in `.ddev/` and leaves your data alone.

**From a branch or commit** — `--version` takes a tag, a branch name, or a SHA:

```bash
ddev add-on get bmack/tryout --version main        # the default branch
ddev add-on get bmack/tryout --version v1.2.0      # a tag
ddev add-on get bmack/tryout --version b50ac77     # a commit
```

**From a fork:**

```bash
ddev add-on get ochorocho/tryout --version main
```

After any of these, `ddev restart` picks up changed DDEV config, and `ddev start`
provisions Core on a fresh project. To see what is installed:

```bash
ddev add-on list --installed
```

> Removing the add-on leaves `packages/` alone — those are your extensions, not
> the add-on's — along with `typo3-core*`, your `composer.json` and your patch list.

> An install **overwrites** every file the add-on owns — those carrying a
> `#ddev-generated` marker. Files you have taken ownership of by deleting that line
> are left alone, as are your `config.yaml`, your `composer.json`, the Gerrit patch
> list and the `typo3-core*` checkouts.

### Adding tryout to an existing project

tryout can be installed into a project that already has its own `composer.json`.
It never rewrites that file: Composer is pointed at an overlay
(`composer.tryout.json`) which pulls your `composer.json` in as an include, so your
own dependencies keep resolving alongside the Core sysexts.

### Migrating from the old template layout

tryout used to be a template repository — you cloned it, ran `rm -rf .git && git init`,
and the scaffold *was* your project. That layout is superseded. To move an existing
tryout to the add-on:

```bash
cd your-existing-tryout
rm -rf .ddev/scripts .ddev/templates .ddev/commands/host/cs \
       .ddev/config.patches.yaml .ddev/commands/host/tryout
ddev add-on get bmack/tryout
ddev restart
```

Your `.ddev/config.yaml` stays as it is. Two things change:

- **`ddev cs` is now `ddev tryout cs`** — a two-letter command was too likely to
  collide with other add-ons.
- **Composer moves to an overlay.** Your generated `composer.json` is replaced by
  `composer.tryout.json`; delete the old `composer.json` and `composer.lock` unless
  you added your own dependencies to them, in which case keep `composer.json` — it
  is merged into the overlay from now on.

Your `typo3-core/` checkout, database and patches are untouched.

## Commands

Everything is accessed through a single `ddev tryout` entry point:

```text
ddev tryout status              Show project overview
ddev tryout download            Clone or update TYPO3 Core
ddev tryout download --reset    Hard reset Core to current branch
ddev tryout checkout <branch>   Switch TYPO3 version (main, 13.4, 12.4, ...)
ddev tryout composer            Regenerate the Composer overlay from Core sysexts
                                (it does not run Composer — that is `ddev composer`)
ddev tryout patch <change-id>   Apply a Gerrit patch
ddev tryout patch               Browse the open changes and pick one or several
                                (or apply the configured list, if there is one)
ddev tryout reset               Reset Core to current branch + rebuild
ddev tryout delete              Wipe DB + fileadmin, fresh setup
ddev tryout help                Show the built-in help

ddev tryout worktree            Manage side-by-side Core checkouts (own help)
ddev tryout exec <site> <cmd>   Run a command in a site's PHP, root and database
ddev tryout launch              Open the worktree you are in, in the browser
ddev tryout launch <worktree>   Open that worktree's site (--backend for /typo3/)

ddev tryout herdr               Open every Core worktree as a herdr workspace
ddev tryout herdr new           Create a worktree and open it

ddev tryout cs                  Prepare instance for Core contribution
ddev tryout cs doctor           Check hooks, template, and push URL
ddev tryout cs uninstall        Remove hooks and reset push URL
```

Once you serve more than one site, `patch`, `reset`, `checkout` and `delete` take an
optional site name and `delete` takes `--all` — see
[Serving several sites at once](#serving-several-sites-at-once). Leave the name off
and `exec`, `reset` and `delete` ask which site you mean, showing what each one is:

```text
Reset which site?
> primary       https://my-typo3-site.ddev.site
  v13           https://v13.my-typo3-site.ddev.site  PHP 8.4
  v12           https://v12.my-typo3-site.ddev.site  PHP 8.2
```

`delete` adds an "every site" entry to that list, so wiping everything is a pick
rather than a flag to remember.

The `worktree` subcommands do the same with checkouts — `use`, `serve`, `unserve`,
`remove` and `rename` show which branch each one is on, whether it has uncommitted
work, and what it serves:

```text
Serve which worktree?
> main            main                  c76e554c343  clean  ← primary
  v13             (detached)            aa6a5bdadce  clean
  bugfix          bugfix-9421           1f3a2b8c9d0  dirty
```

Each list is filtered to what the command can actually act on: `serve` offers only
unserved checkouts, `unserve` only served ones, `use` and `remove` leave out the
primary. A bare `adopt` lists the stray checkouts it found and lets you pick which
to move in.

### Keeping an installed project up to date

`ddev add-on get` copies the add-on into a project once; it is not refreshed
afterwards. A project installed before an update therefore keeps the older command
*and* the older tab-completion — both still work, they just offer the previous set
of verbs and flags, which looks a lot like completion being broken. `ddev tryout
status` says so when it notices:

```text
  ! This project runs an older copy of the tryout add-on
    the command and its tab-completion offer the previous feature set
    → ddev add-on get <path-to-tryout> && ddev restart
```

Re-running `ddev add-on get` is always safe: your `composer.tryout.json`, patch
list and `additional.php` are preserved.

### Tab completion

Every command, subcommand and flag completes with <kbd>Tab</kbd>, each with a short
description, and so do the names the add-on knows about at that moment — only the
ones that make sense where you are:

```console
$ ddev tryout <TAB>
status    -- Show project overview
download  -- Clone or update Core
checkout  -- Switch TYPO3 version (main, 13.4, 12.4, ...)
worktree  -- Manage side-by-side Core checkouts
...

$ ddev tryout worktree serve <TAB>            # only worktrees not served yet
fancy-pants  -- not served
main         -- primary — at the project URL

$ ddev tryout worktree unserve <TAB>          # only the served ones
benni   -- served · PHP 8.5
jochen  -- served · PHP 8.2

$ ddev tryout worktree serve wonka --php <TAB>   # what that Core's composer.json accepts
8.5  -- default for wonka

$ ddev tryout worktree add <TAB>
name for the new worktree (becomes typo3-core-<name>)

$ ddev tryout checkout <TAB>
main  -- latest development — checked out
14.3  -- release branch
13.4  -- release branch
...

$ ddev tryout exec <TAB>
@primary  -- the primary site at the project URL
benni     -- served worktree · PHP 8.5
```

Flags already on the line are not offered again, `use` and `remove` leave out the
primary, `--` shows flags alone, and where the next word is free text a hint says
what it is for. Descriptions show in Zsh and Fish (Bash needs 4.4+; older versions
just show the names). One limit is DDEV's: it cannot suppress file-name completion,
so under a hint your shell still lists files.

Branches come from the refs already in `typo3-core/`, never from the network, so a
<kbd>Tab</kbd> never stalls; `ddev tryout download` and `checkout` both fetch, so the
list stays current. Everything else is a directory listing or a marker file — a
<kbd>Tab</kbd> answers in a few tens of milliseconds.

### Guided commands

Leave an argument out and the command asks for it instead of failing:

```console
$ ddev tryout worktree serve          # pick from the worktrees not served yet
Serve which worktree?
> fancy-pants
  main
  wonka

$ ddev tryout checkout                # pick a branch: main, then releases newest first
$ ddev tryout worktree add            # asks for the name, then the branch
$ ddev tryout worktree rename         # pick the worktree, then type the new name
$ ddev tryout exec                    # pick the site, then type the command
```

`use`, `remove`, `unserve` and `herdr new` ask the same way, each offering only
what makes sense — `unserve` lists served worktrees, `use` leaves out the primary.
<kbd>Esc</kbd> cancels. In a script or a pipe there is no one to ask, so the
commands print their usage line and exit 1 exactly as before.

This needs DDEV's own shell completion to be installed — the add-on cannot do that
for you. Homebrew installs the scripts with DDEV, but Bash also needs
`brew install bash-completion` and Zsh needs `$(brew --prefix)/share/zsh/site-functions`
on `FPATH` before `compinit`. See
[DDEV's shell completion docs](https://docs.ddev.com/en/stable/users/install/shell-completion/)
for your shell and platform.

## Contributing to TYPO3 Core

`ddev start` keeps the instance read-only against Gerrit — you can pull and
test patches but not submit them. Run **`ddev tryout cs`** once to turn the instance
into a full contribution workspace:

```bash
ddev tryout cs             # prompts for your review.typo3.org username
ddev tryout cs setup jdoe  # or pass it explicitly
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
ddev tryout cs doctor
```

Doctor reports whether each piece is wired up and probes Gerrit SSH live
(requires a public key uploaded at https://review.typo3.org/settings/#SSHKeys) —
twice: from inside the container, where `ddev auth ssh` supplies the keys, and
from the host, whose own agent is what a `git push` from a host shell uses.

The username is resolved from (in order): command argument → `TRYOUT_GERRIT_USER`
environment variable → cached `tryout.gerritUser` git config → interactive prompt.
To persist it across instances, set it in `.ddev/config.local.yaml`:

```yaml
web_environment:
  - TRYOUT_GERRIT_USER=jdoe
```

To revert everything:

```bash
ddev tryout cs uninstall
```

## Working with Gerrit Patches

Apply a patch directly from [review.typo3.org](https://review.typo3.org) by its change number:

```bash
ddev tryout patch 56947
```

The latest patchset is resolved automatically via the Gerrit REST API,
fetched, and cherry-picked onto your local Core branch.

### Browsing what is open

Run it bare and it asks which site to patch first, then shows what is currently up
for review **on that site's branch** — a 13.4 site is offered 13.4's changes, not
main's. Pick one or several; gum's own footer names the toggle key:

```bash
ddev tryout patch
```

```text
Apply which changes?
  95347   [TASK] Skip database setup for database-free…   Wouter Wolters    CR+1 V+1
> 95074   [BUGFIX] Avoid stale deleted state on reproc…   Benni Mack        CR+2 V+2
  95671   [BUGFIX] Ensure numeric site identifiers sta…   Oli Bartsch       CR+1 V+1
  94993   [FEATURE] Add table-specific hidden record v…   Matthias Vogel    V-2
x toggle • ←↓↑→ navigate • enter submit • ctrl+a select all
```

The columns are the change number, its subject, its owner and its review state
(`CR` is Code-Review, `V` is Verified). Changes still marked work-in-progress are
prefixed `WIP`. Everything picked is applied in the order shown, with a single
rebuild at the end, and you are asked once afterwards whether to add them to your
patch list so they come back on the next `ddev start` — listed by number *and*
subject, since that is what ends up in a file you keep:

```text
  Add to your patch list, so they reapply on every ddev start:
    95347 - [TASK] Skip database setup for database-free functional tests
    93838 - [FEATURE] Translate forms in the backend

  Add them? [y/N]
```

`--all-branches` widens the list beyond the branch in use. The picker needs a
terminal and [gum](https://github.com/charmbracelet/gum); without either — in
`ddev start`, or any script — a bare `patch` applies the configured list exactly
as it always did.

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
list their change IDs in `.ddev/config.tryout-patches.yaml`:

```yaml
web_environment:
  - TRYOUT_PATCHES=56947,12345
```

On start the Core is reset to the current branch and the listed patches
are cherry-picked in order.

## Switching TYPO3 Versions

Important

TYPO3 uses a `main`-based commit workflow. Usually only mergers commit to a non-main branch only. Even if your fix targets an earlier version, please provide patches against `main`.

By default tryout clones the `main` branch (latest development). To work
against a different major version:

```bash
ddev tryout checkout 14.3
```

This single command switches the Core branch, regenerates the Composer overlay,
and rebuilds everything. Run without arguments to see all available branches.

Different TYPO3 versions ship different sets of system extensions.
`checkout` handles this automatically: a PHP script scans
`typo3-core/typo3/sysext/*/composer.json` and rewrites the `require`
section of `composer.tryout.json` to match exactly what exists on disk.

You can also regenerate the overlay independently at any time:

```bash
ddev tryout composer
```

To pin the branch via environment variable (e.g. in `.ddev/config.local.yaml`):

```yaml
web_environment:
  - TRYOUT_BRANCH=14.3
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

Every tryout is an ordinary DDEV project, so running several side by side is just
a matter of creating several of them. Each gets its own database, TYPO3
installation, and set of patches:

```bash
mkdir tryout-main && cd tryout-main
ddev config --project-type=typo3 --docroot=public --php-version=8.5
ddev add-on get bmack/tryout && ddev start   # → https://tryout-main.ddev.site

mkdir ../tryout-v13 && cd ../tryout-v13
ddev config --project-type=typo3 --docroot=public --php-version=8.5
ddev add-on get bmack/tryout && ddev start   # → https://tryout-v13.ddev.site
```

`ddev config` derives the project name from the folder; pass
`--project-name=my-custom-name` to override it.

If what you actually want is several TYPO3 versions inside *one* project — sharing
a single Core object store, and optionally all reachable at once — use
`ddev tryout worktree` instead. See
[Multiple Core Checkouts Side by Side](#multiple-core-checkouts-side-by-side).

## How It Works

### Directory Layout

After `ddev add-on get` the add-on's payload lives under `.ddev/`, and your project
root holds the Core checkout and the Composer overlay:

```text
my-typo3-site/
├── .ddev/
│   ├── commands/host/
│   │   ├── tryout                # The ddev tryout entry point (host: prompts, herdr)
│   │   └── autocomplete/
│   │       └── tryout            # Tab-completion for it (DDEV runs this on TAB)
│   ├── tryout/                   # Add-on payload, namespaced so it cannot collide
│   │   ├── functions.sh          # Shared helpers (Gerrit API, patching, worktrees, herdr)
│   │   ├── commands.sh           # The verbs' work, run inside the web container
│   │   ├── tryout-container.sh   # In-container dispatcher the host command calls
│   │   ├── post-start.sh         # Runs on ddev start, in the container (clone, patch, setup)
│   │   ├── sync-composer.php     # Regenerates the overlay from Core sysexts
│   │   ├── site-composer.php     # Builds a served site's own composer root
│   │   ├── tryout-php-fpm.sh     # Extra php-fpm master for a site on another PHP
│   │   ├── resolve-patch-ref.sh  # Fetches + parses a Gerrit change (runs in-container)
│   │   ├── resolve-gerrit-account.sh  # Looks up a Gerrit account (runs in-container)
│   │   ├── gitmessage.txt        # Commit template installed by `ddev tryout cs`
│   │   └── …                     # Templates copied out on install (see below)
│   ├── config.yaml               # Yours, from `ddev config` (name, docroot, PHP, DB)
│   ├── config.tryout.yaml        # Add-on: TYPO3 env vars + the post-start hook
│   ├── config.tryout-patches.yaml  # Gerrit patch list (yours to edit)
│   ├── config.worktrees.yaml     # Generated by `worktree serve` — hostnames + daemons
│   └── web-build/Dockerfile.tryout  # Builds git ≥ 2.48 into the web image (see below)
├── config/system/additional.php  # TYPO3 DB + mail + GFX config for DDEV
├── packages/                     # Custom extensions (path repository)
├── composer.tryout.json          # Composer overlay (add-on owned, generated)
├── composer.json                 # Yours, if you have one — never rewritten
├── typo3-core                    # Symlink to the active checkout (see worktrees)
├── typo3-core-main/              # The Core clone (gitignored, created on first start)
├── typo3-core-<name>/            # Further worktrees, one per `worktree add`
└── sites/<name>/                 # A served site's own root (`worktree serve`)
```

Four files in `tryout/` are templates rather than runtime code: `additional.php`,
`composer.tryout.json`, `gitignore` and `patches.yaml` are copied out to the project
on install, which is where the entries above them come from.

Everything the add-on owns carries a `#ddev-generated` marker. DDEV refuses to
overwrite a file whose marker you removed, and removes only marked files on
uninstall — so deleting that line is how you take ownership of any of them.

### The Composer Overlay

An add-on must not rewrite the `composer.json` of the project it is installed
into. So tryout ships its own **overlay**, `composer.tryout.json`, and points
Composer at it with `COMPOSER=composer.tryout.json` in `config.tryout.yaml`.

The overlay declares two path repositories:

```json
{
  "repositories": [
    { "type": "path", "url": "packages/*" },
    { "type": "path", "url": "typo3-core/typo3/sysext/*", "options": { "symlink": true } }
  ],
  "extra": {
    "merge-plugin": { "include": ["composer.json"] }
  }
}
```

Every system extension inside the Core clone is required at `@dev`. Composer
resolves them from the local path and creates symlinks, so any edit inside
`typo3-core/` is immediately active — no reinstall needed. The same mechanism
applies to `packages/*`: local extensions are symlinked into `vendor/` and behave
as if they were installed from Packagist.

`composer-merge-plugin` pulls your own `composer.json` in as an include, so if the
project had dependencies before you installed tryout they keep resolving. Your file
is only ever read, never written.

The `require` block of the overlay is generated: `sync-composer.php` scans
`typo3-core/typo3/sysext/*/composer.json` and rewrites it, which is what keeps the
sysext list correct across `ddev tryout checkout`. Anything you add to the overlay
that is not a `typo3/cms-*` or `typo3/theme-*` package is preserved.

### DDEV Configuration

- **`config.yaml`** — yours, created by `ddev config`. Project name, docroot,
  PHP and database versions live here.
- **`config.tryout.yaml`** — installed by the add-on. Carries the TYPO3
  environment variables, the `COMPOSER` overlay selection and the post-start hook.
  Deliberately sets no `name`, `type`, `docroot` or `php_version`: those are yours.
- **`config.tryout-patches.yaml`** — defines `TRYOUT_PATCHES` for auto-applying
  Gerrit changes on start. Not marked generated, so your patch list survives
  add-on updates.
- **`config.local.yaml`** — gitignored, for personal overrides (PHP version,
  xdebug, etc.). DDEV merges `config.*.yaml` files in lexicographic order, so
  anything sorting after `config.tryout.yaml` wins.

### Where the work runs

`ddev tryout` is a host command, and the host keeps what only the host can do:
the prompts and pick-lists, the confirmation before `delete`, tab completion, and
everything to do with herdr. **The work of every other verb runs inside the web
container** — the host resolves the arguments, then makes one `ddev exec` into
`.ddev/tryout/tryout-container.sh`. In there git, Composer, PHP, curl and the
database clients are the container's own, so a Core clone, a cherry-pick, a
`composer install` or a Gerrit lookup all use the same tools TYPO3 itself runs on,
and never a host PHP or a host Composer.

Two consequences are worth knowing:

- **Git worktrees are shared between both sides.** A worktree's metadata records
  paths, and an absolute path is right on one side of the container boundary only.
  tryout therefore runs the Core repository with `worktree.useRelativePaths`, which
  git learned in 2.48, so a worktree the container created reads fine in your host
  editor, in herdr and in `git status` on the host — and vice versa. Debian trixie,
  the base of DDEV's web image, ships git 2.47, so the add-on builds git 2.53 into
  the image from a checksum-pinned tarball (`.ddev/web-build/Dockerfile.tryout`).
  That costs about a minute the first time the image is built and nothing after.
  A host git older than 2.48 still reads such worktrees; installation notes it.
- **SSH keys come from `ddev-ssh-agent`** when something inside the container talks
  to Gerrit over SSH. Run `ddev auth ssh` once to hand it your host keys. Pushing
  from a host shell keeps using your host agent, and `ddev tryout cs doctor` reports
  both.

### Post-Start Hook

On every `ddev start` the post-start script runs inside the web container, as an
`exec` hook:

1. **Clone** — if `typo3-core/` does not exist, clones from GitHub and adds a
   Gerrit remote.
2. **Patch** — if `TRYOUT_PATCHES` is set, resets Core to the current branch
   and cherry-picks each change via the Gerrit REST API.
3. **Sync + Composer install** — regenerates `composer.tryout.json` from the
   sysexts in this Core checkout, then resolves everything from the path repositories.
   The clone happened right where Composer runs, so nothing waits on a file sync.
4. **TYPO3 setup** — on first run, creates `settings.php` and sets up the database.
5. **Extension setup + cache flush** — activates extensions and clears caches.

### Gerrit Integration

Patches are resolved through the Gerrit REST API at `https://review.typo3.org`.
Given a change number (e.g. `56947`), the API returns the latest patchset ref
(e.g. `refs/changes/47/56947/12`). That ref is fetched and cherry-picked.

Merged or abandoned changes are detected and skipped. Conflicts abort the
cherry-pick automatically and report the failure.

## Multiple Core Checkouts Side by Side

Within a single tryout you can keep several TYPO3 Core checkouts and switch
between them instantly. They are git worktrees of the Core clone you already
have, so they share one object store: one fetch, a fraction of the disk, and
no second clone.

```bash
ddev tryout worktree add v13 13.4   # create typo3-core-v13 at origin/13.4
ddev tryout worktree list           # show all, marking the active one
ddev tryout worktree use v13        # make it the active Core, then rebuild (drops vendor/)
ddev tryout worktree serve v13      # give it its own URL, PHP and database
ddev tryout worktree unserve v13    # drop that site, keep the worktree
ddev tryout worktree remove v13     # remove the worktree itself
ddev tryout worktree rename v13 old # rename the checkout, keep the branch
ddev tryout worktree help           # flags and the full picture
```

Without `--php`, a served worktree gets **the highest PHP its own Core accepts** —
read from `require.php` in that branch's `composer.json`, not from the project's
PHP version. A 13.4 worktree (`^8.2`) and a main one (`^8.5`) therefore get the
right runtime each, and a branch with an upper bound like `>=8.2 <8.4` gets 8.3.

The same constraint guards every Composer run. A project on PHP 8.4 with Core
`main` (`^8.5`), or a `--php` the branch rejects, stops **before** `composer
install` with the constraint, the version in use and the command that changes
it — `ddev config --php-version=8.5 && ddev restart` for the project, `worktree
serve <name> --php <version>` for a site — instead of Composer's resolver trace.

`add` takes `--branch` (a real local branch instead of a detached HEAD), `--serve`,
`--php 8.2` (which implies `--serve`), and `--herdr` to open it as a
[herdr workspace](#opening-worktrees-in-herdr) straight away.

> `use`, `remove` and `unserve` take their flag **after** the name —
> `worktree use v13 --force`, not `worktree use --force v13`.

The first `worktree add` moves your existing `typo3-core/` to
`typo3-core-main/` and turns `typo3-core` into a symlink pointing at whichever
checkout is active. Every path keeps working, so nothing else in the project
changes.

```text
typo3-core        -> typo3-core-v13   (symlink: the active Core)
typo3-core-main/                      (the clone; owns the git object store)
typo3-core-v13/                       (worktree, branch v13 tracking origin/13.4)
```

Typical use: run a Gerrit patch against v13 while keeping main untouched.

```bash
ddev tryout worktree add v13 13.4
ddev tryout worktree use v13
ddev tryout patch 56947
ddev tryout worktree use main        # back to main, patch stays on v13
```

New worktrees get a **branch named after the worktree**, tracking the branch they
were created from — `worktree add v13 13.4` makes a branch `v13` on top of
`origin/13.4`. Not named after the base, because git allows one worktree per
branch and a second checkout off `13.4` would be refused.

The upstream is what `ddev tryout download <name>` rebases onto, so a worktree
knows where to update from. Gerrit is unaffected either way: pushes go to
`refs/for/<branch>` from `HEAD`, never from a local branch. Pass `--detach` for
a throwaway checkout with no branch at all.

Because `use` swaps the Core underneath Composer, it always runs
`composer install` afterwards — without it `vendor/` would keep pointing at
the previous checkout. `ddev tryout status` warns if the two ever drift apart.

Two guards worth knowing: you cannot remove the active worktree, and switching
away from one with uncommitted changes is refused (`--force` overrides).
Since all worktrees share one object store, a single `ddev tryout cs` sets up the
Gerrit hooks and commit template for all of them.

### Serving several sites at once

`use` gives you one site at the project URL. To have every worktree reachable
**at the same time**, each on its own hostname, PHP version and database, serve
it instead:

```bash
ddev tryout worktree add v13 13.4 --php 8.2 --serve
ddev restart          # registers the hostname and issues its certificate
```

```text
https://tryout-git.ddev.site       → typo3-core        PHP 8.5   db
https://v13.tryout-git.ddev.site   → typo3-core-v13    PHP 8.2   db_v13
```

Both run in the same container: the served site gets its own php-fpm on its own
socket, its own vhost, its own `sites/<name>/` tree with its own `vendor/`, and
its own database. Roughly 175 MB per extra site — the Core object store stays
shared.

The `ddev restart` is only needed when the set of hostnames changes — DDEV owns
the routing rule and the TLS certificate, and both are keyed on it. **Re-serving a
site that already exists applies immediately**, with no restart: the webserver is
reloaded in place, and the other sites keep serving throughout. So changing a
served site's PHP version, for instance, costs a reload rather than a full
container rebuild:

```bash
ddev tryout worktree serve v13 --php 8.3   # applied without a restart
```

#### Stopping a site

```bash
ddev tryout worktree unserve v13    # keeps the database
ddev restart                        # releases the hostname
```

`unserve` removes the site's vhost and its whole `sites/v13/` tree — including that
`vendor/`, so the ~175 MB comes back — but **keeps the database and the git
worktree**. Serving it again later restores the site with its content intact. Add
`--drop-db` to discard the database too.

To remove the checkout as well, use `ddev tryout worktree remove v13`; it unserves
first if it has to.

The site-scoped commands take an optional site name, defaulting to the primary
so existing usage is unchanged:

```bash
ddev tryout patch 93202 v13     # cherry-pick onto that site's Core only
ddev tryout reset v13
ddev tryout checkout 13.4 v13
ddev tryout delete v13          # only that site's DB and fileadmin
ddev tryout delete --all        # every site, named in the confirmation
ddev tryout exec v13 vendor/bin/typo3 cache:flush
ddev tryout launch v13          # open its URL in the browser
```

### Opening a site in the browser

`launch` opens the site of the worktree you are standing in, so from inside a
checkout it needs no argument at all:

```bash
cd typo3-core-v13
ddev tryout launch              # https://v13.<project>.ddev.site
ddev tryout launch --backend    # ...and straight into /typo3/
```

Outside a worktree it asks, listing each served site with the URL it would open.
A worktree that is not served has no URL, and `launch` says so rather than
opening some other site's: give it one with `worktree serve`, or make it the
primary with `worktree use`.

In the herdr panel the two forms are the last two rows, **launch frontend** and
**launch backend**. They are the only rows that run in the panel itself instead
of a popup — they raise the browser, so a popup would only sit in front of it.

### Opening worktrees in herdr

If you use [herdr](https://herdr.dev) — a terminal multiplexer built around coding
agents — one command lays out every Core worktree:

```bash
ddev tryout herdr              # every worktree
ddev tryout herdr v13          # just that one
ddev tryout herdr --no-agent   # a plain shell instead of claude
```

Each worktree becomes its own herdr workspace, labelled `core-<name>` so it is
unambiguous in the sidebar, holding a Claude session and a shell both rooted at that
worktree:

```text
workspace "core-main"              workspace "core-v13"
├── claude   (typo3-core-main)     ├── claude   (typo3-core-v13)
└── shell    (typo3-core-main)     └── shell    (typo3-core-v13)
```

A fresh project with only the plain `typo3-core/` clone and no worktrees yet gets
one workspace for it, named after its branch (`core-main`). That is the name the
checkout keeps when a later `worktree add` moves it to the worktree layout.

**To see each worktree's branch in the sidebar**, add this to
`~/.config/herdr/config.toml`:

```toml
[ui.sidebar.spaces]
rows = [["state_icon", "workspace"], ["branch", "$wt_branch", "git_status"]]
```

herdr's own `branch` row is computed from a workspace's *repository* root, which
for a linked worktree is the origin clone — so without this only the main checkout
shows a branch. The add-on reports `$wt_branch` per workspace instead, refreshed
whenever it opens or reconciles them and after a `worktree`/`checkout` run from the
panel. A detached checkout reads `detached` rather than going blank.

Worktrees already open are skipped, so it is safe to re-run, and the first Core
workspace is focused when it is done (`--focus` is the default; `--no-focus` stays put). On the first run in
a worktree Claude asks you to trust the folder — the command says so rather than
waiting.

**It runs in a herdr session of its own**, `tryout-<project>`, started on demand, and
drops you straight into it. Your default session is never touched, so Core worktrees
stay out of your everyday sidebar.

Where attaching is not possible it prints what to do instead: with no terminal (a
script or CI) it gives you `herdr session attach tryout-my-typo3-site`, and from
inside herdr — which refuses to nest — it tells you to switch to that session.

Pass `--no-attach` to always print rather than attach.

### Creating a worktree from herdr

`ddev tryout herdr new <name> [<branch>]` creates a Core worktree and opens it in one
step. Run it bare in a terminal and it asks for both — a name, and a branch picked from
the ones this Core knows. The same thing from the other direction is
`ddev tryout worktree add <name> <branch> --herdr`.

#### Worktrees always land in the project

A TYPO3 Core worktree has to be at `<project>/typo3-core-<name>` — that is what the
`typo3-core` symlink points at, what `worktree list` finds, and what `serve` builds a
site from.

herdr's own **New worktree** puts its checkouts elsewhere. Its only setting,
`worktrees.directory`, places them at `<directory>/<repo>/<branch-slug>`, and it names
them from a generated word list — so a worktree created that way is invisible to every
`ddev tryout` command until it is adopted:

```bash
ddev tryout worktree adopt --dry-run   # list strays
ddev tryout worktree adopt             # move them into the project
```

`ddev tryout status` flags them too, so one cannot sit unnoticed.

The **directory name and the branch are independent**. herdr's own action names a
checkout after the branch it invents (`worktree/wilie-wonka`), and `adopt` derives
one the same way, but that is only a starting point:

```bash
ddev tryout worktree adopt <path> wonka   # adopt one stray under a name you pick
ddev tryout worktree rename wonka spike   # rename later; the branch is untouched
```

A rename moves everything keyed on the name — the checkout, the `typo3-core`
symlink if it is the active one, and a served site's tree, vhost and database. A
served site is unserved and re-served under the new name, so it needs a
`ddev restart` afterwards to pick up the new hostname.

> These are keybindings, not additions to herdr's own UI. A herdr plugin cannot add an
> entry to its menus — plugin actions are reachable only by a keybinding or a
> ctrl-click — so the menu is a popup of our own rather than tryout entries appearing
> in herdr's right-click menu.

> herdr has **one** global config, so these keys are live in every session, not just
> tryout's. Pressed outside a tryout project, each popup says so and does nothing.

Manage the session like any other:

```bash
herdr session list                                  # what is running
herdr --session tryout-my-typo3-site server stop    # stop it (panes and agents end)
herdr session delete tryout-my-typo3-site           # forget a stopped session
```

A bare `ddev tryout herdr` keeps the session in step with the project in **both**
directions: it opens a workspace for any worktree that has none, and closes any
workspace whose worktree has been removed.

```text
==> Opening 'v14'...
==> 'v14' — claude 'v14' + shell
  ✗ closed core-v13 — typo3-core-v13 is gone
```

That close is unconditional — a workspace goes even if its agent is still
working — so the session always matches what is on disk. A `worktree rename` is
a remove plus an add as far as herdr is concerned, so the old workspace closes
and the new one opens in the same run. Name a worktree
(`ddev tryout herdr v14`) to open just that one and leave every other workspace
untouched.

It also reconciles workspaces that have drifted out of step. One already sitting
in a Core worktree under a different label — anything opened before this naming
existed, or renamed by hand — is **adopted** rather than closed, so its panes,
history and running agent survive and no duplicate appears beside it:

```text
  ✓ adopted core-main (was 'typo3-core-main')
  ✗ closed scratch — outside this project
```

Since the session belongs to one project, a workspace pointing outside it is
closed. Anything else *inside* the project — the project root, `packages/` — is
left exactly as it is: it is not a Core worktree, and you opened it on purpose.

> herdr is optional and the add-on never installs it. The command needs `herdr` and
> `jq` on the host, and works from any terminal — it does not have to be run from
> inside a herdr pane. Without those it exits with a hint and changes nothing.

### Mutagen and the Core checkout (macOS)

With Mutagen the Core clone lives on both sides: git runs on it inside the
container, and your editor and herdr read it on the host. Its
`.git` — around 650 MB — is part of the sync, and **must stay so**: excluding
`typo3-core*/.git` in `.ddev/mutagen/mutagen.yml` would leave the container's git
with nothing to work on. What can safely be excluded is a served site's
`sites/*/vendor`, which only the container needs; edit that file, **remove the
`#ddev-generated` line** to take ownership of it, and add the path under
`ignore.paths`.

A change made in the container reaches the host after a sync cycle, usually within
seconds. The one place that cannot wait is a worktree herdr is about to open, so
`worktree add --herdr` and `herdr new` flush the sync first.

## Sharing one TYPO3 Core checkout across multiple tryouts

Earlier versions suggested pre-seeding `typo3-core/` as a worktree of one shared
clone somewhere on the host. That no longer works: git runs inside the web
container, and a worktree whose object store lives outside the project is
unreachable from there. To keep several Core versions side by side, use
`ddev tryout worktree` inside one project — it shares a single object store between
all of them, optionally serves each on its own hostname, and keeps every checkout
where both the host and the container can see it.

## Requirements

- [DDEV](https://ddev.readthedocs.io/en/stable/) v1.24.10+ (enforced by the add-on)
- Docker Desktop or Colima
- Git on the host, 2.48 or newer recommended: the host only *reads* the Core
  checkout (status before the first start, tab completion), but
  worktrees are recorded with relative paths, which older gits handle for reading
  and not for `git worktree` commands. The git that does the work is built into
  the web image by the add-on.
- A `bash` shell on the host — `ddev tryout` is a host command that hands the work
  to the container. On Windows this means Git Bash (bundled with Git for Windows);
  DDEV finds it automatically. An SSH client on the host is only needed to push to
  Gerrit from a host shell; `ddev auth ssh` covers pushing from the container.
- Optional but recommended: [gum](https://github.com/charmbracelet/gum) — draws the
  tables, pick-from-a-list prompts and spinners. Without it every command still works
  and prints the same information, just as plain text with a typed prompt instead of a
  chooser; installation says so once and carries on. Install with `brew install gum`,
  `sudo apt-get install gum`, `sudo dnf install gum` or `sudo pacman -S gum`.
- Optional, for `ddev tryout herdr` only: [herdr](https://herdr.dev) plus
  [`jq`](https://jqlang.github.io/jq/download/) on the host — `brew install herdr jq`,
  or `curl -fsSL https://herdr.dev/install.sh | sh` where no distribution packages it.
  The add-on installs neither; without them that one command exits with the install
  command for your platform and everything else works as usual.

Both are covered with a little more context under
[Optional but recommended](#optional-but-recommended).

Output is meant to be read by people: with gum installed,
`ddev tryout worktree list` draws a table and `ddev tryout status` a bordered
report; without it, the same content in plain columns. **For scripting, use
`ddev tryout worktree list --plain`** — space-padded columns
(`NAME HEAD BRANCH STATE PHP DB URL`), which is the format the Playwright suite
parses and the one that stays stable.

The host scripts are POSIX-minded bash and run on **macOS and Linux alike**: no
GNU-only utilities (`readlink -f`, `grep -P`, `stat -c`, `date -d`), and nothing that
needs bash 4, since macOS still ships 3.2. Tests enforce both.

## Contributing

tryout itself lives at [github.com/bmack/tryout](https://github.com/bmack/tryout).
If you have improvements to the add-on — better defaults, new `ddev tryout`
subcommands, fixes to the post-start hook, documentation tweaks — pull requests
and issues are welcome there.

To work on the add-on, install it into a scratch project straight from your
checkout — no release or tarball needed:

```bash
mkdir /tmp/tryout-test && cd /tmp/tryout-test
ddev config --project-type=typo3 --docroot=public --php-version=8.5
ddev add-on get /path/to/your/tryout/checkout
ddev start
```

The payload lives at the repo root (`install.yaml`, `commands/`, `tryout/`,
`config.tryout.yaml`) and is copied into the project's `.ddev/` on install.

### Tests

The suite is [bats](https://bats-core.readthedocs.io/). Install it and the helper
libraries once:

```bash
brew tap bats-core/bats-core
brew install bats-core bats-assert bats-file bats-support
```

It is split by cost, because every DDEV-backed test builds and destroys a whole
project:

```bash
bats tests/unit.bats      # seconds — pure helpers in tryout/functions.sh, no containers
bats tests/test.bats --filter-tags '!release'
                          # minutes — install, config, overlay, guarded files, removal
bats tests/lifecycle.bats # much longer — clones TYPO3 Core, patches, served worktrees
bats tests --filter-tags '!release,!lifecycle'   # the 100 fast tests
bats tests --filter-tags '!release'              # everything runnable locally
```

The lifecycle suite asserts that each served worktree really is a separate instance:
every URL check fetches the page body and looks for the TYPO3 login `<title>`, not
just a 200, because a misconfigured site answers 200 with a broken page. It runs the
primary and two served worktrees side by side, checks each has its own populated
database, and that `unserve` stops one hostname answering while the others keep
serving.

> Those URL assertions **skip** on a machine where `*.ddev.site` does not resolve.
> DDEV writes project hostnames to `/etc/hosts`, which needs sudo, and the suite runs
> with `DDEV_NONINTERACTIVE=true` — so a throwaway test project never gets an entry.
> CI, and any host with a wildcard resolver, runs them for real.

`tests/e2e/` holds opt-in Playwright tests that log into the backend of every
served worktree with a real browser — the one thing curl cannot prove, since a
login posts a form, sets a secure cookie and redirects into a module. They are not
part of any default run; see `tests/e2e/README.md`.

`tests/test.bats` carries an `install from release` test tagged `release`; it needs
a published GitHub release, so exclude it locally with `--filter-tags '!release'`.
CI runs the fast suites on every push and the lifecycle and release suites nightly.

For debugging: `bats tests/test.bats --show-output-of-passing-tests --verbose-run
--print-output-on-failure`.

This repo also tracks DDEV's add-on conventions, which are machine-checkable:

```bash
curl -fsSL https://ddev.com/s/addon-update-checker.sh | bash
```

Note that contributions to **TYPO3 Core** itself do not go through this repo.
Core development happens on [review.typo3.org](https://review.typo3.org) via Gerrit.
tryout is just a local environment for working on Core; once you have a patch ready,
push it to Gerrit as usual.

## License

MIT — see [LICENSE](LICENSE).
