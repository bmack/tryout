:navigation-title: Architecture

============
Architecture
============

tryout is a DDEV project with no TYPO3 in it. What it holds is the scaffolding
that turns a Core git clone into a running installation: a post-start hook, two
host commands, a shared function library and a Composer manifest that is
generated rather than maintained.

Repository layout
=================

.. code-block:: text

   tryout/
   ├── .ddev/
   │   ├── commands/host/
   │   │   ├── tryout                # ddev tryout — Core, patches, versions
   │   │   ├── cs                    # ddev cs — contribution setup
   │   │   └── docs                  # ddev docs — renders this manual
   │   ├── scripts/
   │   │   ├── functions.sh          # shared helpers, sourced by everything
   │   │   ├── post-start.sh         # runs on every ddev start
   │   │   ├── resolve-patch-ref.sh  # Gerrit REST lookup (runs in-container)
   │   │   └── sync-composer.php     # regenerates composer.json from sysexts
   │   ├── apache/
   │   │   └── docs.conf             # maps /docs/ to .site/
   │   ├── templates/
   │   │   └── gitmessage.txt        # commit-message template for ddev cs
   │   ├── config.yaml               # PHP, database, env, the post-start hook
   │   └── config.patches.yaml       # TRYOUT_PATCHES
   ├── .github/workflows/publish.yml # renders and publishes the documentation
   ├── config/system/additional.php  # TYPO3 configuration for DDEV
   ├── docs/                         # this manual
   ├── packages/                     # custom extensions (path repository)
   ├── composer.json                 # generated: path repos + every sysext
   ├── typo3-core/                   # the Core clone — gitignored
   ├── .renderer/                    # documentation renderer — gitignored
   └── .site/                        # rendered documentation — gitignored

Everything below ``typo3-core/`` is a normal git checkout of
`github.com/typo3/typo3 <https://github.com/typo3/typo3>`__ with a second
remote named ``gerrit``. No part of the scaffold rewrites files inside it; it
only ever runs git against it.

Host and container
==================

The split matters when something fails, so it is worth being explicit.

.. list-table::
   :header-rows: 1
   :widths: 35 65

   * - Runs on the host
     - Runs in the container
   * - ``ddev tryout``, ``ddev cs``, ``post-start.sh`` — declared with
       ``exec-host`` in ``config.yaml``
     - Everything they shell out to: ``ddev composer``, ``ddev typo3``,
       ``ddev exec``, ``ddev mysql``
   * - All git operations against ``typo3-core/``, including the SSH push to
       Gerrit
     - ``resolve-patch-ref.sh``, because ``curl`` and ``jq`` are guaranteed
       there and not on every host
   * - Reading your SSH agent for the Gerrit probe
     - ``sync-composer.php``, run through ``ddev php``

The consequence: a ``bash`` shell on the host is a hard requirement, and your
host git configuration and SSH agent are what Gerrit sees.

Composer path repositories
==========================

Two of them, and they are the reason the setup is worth having at all:

.. code-block:: json
   :caption: composer.json

   {
       "repositories": [
           { "type": "path", "url": "packages/*" },
           {
               "type": "path",
               "url": "typo3-core/typo3/sysext/*",
               "options": { "symlink": true }
           }
       ],
       "minimum-stability": "dev",
       "prefer-stable": true
   }

Every system extension found in the Core clone is required at ``@dev``.
Composer resolves it from disk and installs it as a symlink, so
``vendor/typo3/cms-core`` **is** ``typo3-core/typo3/sysext/core``. An edit in
the clone is live on the next request — no reinstall, no copy step, and no way
for the running instance to drift from the code you are reading.

``packages/*`` works the same way for your own extensions. See
:doc:`/getting-started/extensions`.

The post-start hook
===================

``.ddev/config.yaml`` declares one hook:

.. code-block:: yaml

   hooks:
     post-start:
       - exec-host: bash .ddev/scripts/post-start.sh

It runs on every ``ddev start`` and every ``ddev restart``, and it is written to
be idempotent: on a second start, steps 1, 2 and 4 report that there is nothing
to do, and step 6 re-renders in a couple of seconds.

Step 1 — clone Core
-------------------

If ``typo3-core/.git`` exists as either a directory or a file, this step is
skipped — the file case is a git worktree, which is what makes
:doc:`/getting-started/instances` work. Otherwise the repository is cloned on the
resolved branch and the ``gerrit`` remote is added.

Step 2 — apply patches
----------------------

Only when ``TRYOUT_PATCHES`` is non-empty. Core is **reset to the branch tip
first**, then each change is cherry-picked in order. The reset is what makes
the variable a description of state rather than an instruction that accumulates
over restarts.

A failed patch here is a warning, not an abort: the instance still comes up, so
you can inspect it and run ``ddev tryout reset``.

Step 3 — Composer install
-------------------------

``ddev composer install``. A failure here stops the hook and prints the reset
command, because there is no point setting up TYPO3 without a vendor directory.

Step 4 — TYPO3 setup
--------------------

Only when ``config/system/settings.php`` does not exist. Two values are derived
before ``vendor/bin/typo3 setup --no-interaction --force`` runs:

- ``TYPO3_DB_DRIVER`` from ``DDEV_DATABASE`` — ``postgres`` for a PostgreSQL
  project, ``mysqli`` otherwise.
- ``--server-type`` from ``DDEV_WEBSERVER_TYPE`` — ``apache`` for the Apache
  variants, ``other`` for everything else.

The admin user comes from the ``TYPO3_SETUP_ADMIN_*`` variables in
``config.yaml``. Because the step is guarded by the settings file, those
variables are read exactly once in the life of an installation.

Step 5 — extensions and caches
------------------------------

``typo3 extension:setup`` then ``typo3 cache:flush``. Warnings from either are
reported but do not fail the start.

Step 6 — render the documentation
---------------------------------

``ddev docs`` renders ``docs/`` into ``.site/``, which the Apache alias in
``.ddev/apache/docs.conf`` serves at ``/_docs/``. The URL is printed beside the
backend URL when the render succeeded.

Skipped when ``TRYOUT_DOCS`` is ``0``, and when there is no ``docs/guides.xml``
to render. A failure is a warning and nothing more: a dead link in the manual
must not be why an instance does not come up. On a first start this step also
installs the renderer into ``.renderer/``, which is the only slow part of it.

Branch resolution
=================

``functions.sh`` resolves the active branch once, when it is sourced, and every
command downstream uses that answer:

#. ``TRYOUT_BRANCH`` if set,
#. else the branch currently checked out in ``typo3-core/``,
#. else ``main``.

The second rule is why ``ddev tryout checkout 14.3`` sticks without any further
configuration, and why the variable is only genuinely needed before the first
clone. See :doc:`/core/versions`.

Generating ``composer.json``
============================

``sync-composer.php`` runs inside the container, where the project root is
``/var/www/html`` unless ``PROJECT_ROOT`` says otherwise. It:

#. globs ``typo3-core/typo3/sysext/*/composer.json`` and reads each ``name``;
#. keeps every existing requirement whose name does **not** start with
   ``typo3/cms-`` or ``typo3/theme-``, so packages you required from
   ``packages/`` survive;
#. adds every discovered system extension at ``@dev``;
#. adds ``typo3/theme-camino`` on ``main`` and on branches numbered 14 or
   higher;
#. sorts the requirements and writes the file back;
#. deletes ``composer.lock``.

The last point is load-bearing. A lock file that still references an extension
the new branch removed makes the next ``composer install`` fail, and the error
it produces names the package rather than the branch switch that caused it.

Gerrit integration
==================

Two separate channels, and only one of them needs an account.

**Reading** is anonymous. The REST API at ``https://review.typo3.org`` is asked
for ``/changes/<number>?o=CURRENT_REVISION``; the XSSI guard ``)]}'`` is
stripped from the first line, and ``jq`` extracts the subject, the current
revision's ref, its patchset number and the change status. The ref — something
like ``refs/changes/47/56947/12`` — is fetched from the ``gerrit`` remote over
HTTPS and cherry-picked.

Before the cherry-pick, the ``Change-Id`` footer of the fetched commit is
compared against every commit in ``origin/<branch>..HEAD``. A match means the
change is already applied and the cherry-pick is skipped. A conflict triggers
``git cherry-pick --abort``, so the tree is never left mid-merge.

**Writing** needs an account and is opt-in. ``ddev cs`` sets the *push* URL of
``origin`` to ``ssh://<user>@review.typo3.org:29418/Packages/TYPO3.CMS`` and
leaves the fetch URL on GitHub. It also copies two hooks out of the Core clone
itself — ``Build/git-hooks/commit-msg`` and
``Build/git-hooks/unix+mac/pre-commit`` — rather than shipping its own, so the
checks you run locally are the ones Core defines. See
:doc:`/core/contributing`.

TYPO3 configuration
===================

``config/system/additional.php`` is tracked in git and applies only inside DDEV
— everything in it is guarded by ``IS_DDEV_PROJECT``. It sets the database
connection, points the image processor at ImageMagick in ``/usr/bin/``, routes
mail to the DDEV Mailpit on ``localhost:1025``, and opens up
``trustedHostsPattern``, ``devIPmask`` and ``displayErrors`` for development.

The database driver is derived from ``DDEV_DATABASE`` here too — ``pdo_pgsql``
with port 5432 for PostgreSQL, ``mysqli`` with port 3306 otherwise — so the
file follows the DDEV project rather than hard-coding a stack.

``config/system/settings.php`` is written by the TYPO3 setup and is gitignored,
as is ``config/sites/``.

Generated versus tracked
========================

.. list-table::
   :header-rows: 1
   :widths: 45 55

   * - Tracked
     - Generated and ignored
   * - ``.ddev/`` — commands, scripts, templates, ``apache/docs.conf``,
       ``config.yaml``, ``config.patches.yaml``
     - ``.ddev/config.local.yaml``, ``.ddev/apache/apache-site.conf``
       (generated by DDEV)
   * - ``config/system/additional.php``
     - ``config/system/settings.php``, ``config/sites/``
   * - ``composer.json``
     - ``composer.lock``, ``vendor/``, ``public/``, ``var/``
   * - ``packages/.gitkeep``
     - ``packages/*``, ``typo3-core/``
   * - ``docs/``, ``.github/workflows/publish.yml``
     - ``.renderer/``, ``.site/``

``composer.json`` is the odd one: it is tracked *and* machine-written. That is
deliberate — a fresh clone must be installable before the Core checkout exists,
so the committed file describes a working default set, and
``ddev tryout composer`` reconciles it with reality afterwards.
