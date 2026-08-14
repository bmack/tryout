:navigation-title: Installation

============
Installation
============

A tryout instance is a git clone plus ``ddev start``. Everything else — the
Core checkout, the Composer install, the database and the first backend user —
is done by the ``post-start`` hook the first time the project comes up.

Requirements
============

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Requirement
     - Why
   * - `DDEV <https://ddev.readthedocs.io/en/stable/>`__ v1.24 or newer
     - Provides the container stack, the ``ddev tryout`` command hooks and the
       ``exec-host`` support the post-start script relies on.
   * - Docker Desktop or Colima
     - The container runtime DDEV drives.
   * - Git
     - The Core repository is cloned and patched with plain ``git``; there is
       no vendored copy of TYPO3 anywhere in this repository.
   * - A ``bash`` shell on the host
     - ``ddev tryout``, ``ddev cs`` and the post-start hook run on the host,
       not inside the container. On Windows this is Git Bash, which ships with
       Git for Windows and which DDEV finds on its own.
   * - An SSH client
     - Only needed for :doc:`/core/contributing` — pushing to Gerrit goes over SSH
       on port 29418.

PHP, MariaDB, Composer and Node are **not** host requirements. They are
supplied by the DDEV web and database containers, pinned in
``.ddev/config.yaml``.

Quick start
===========

Pick a folder name for the project — it becomes the DDEV project name and the
hostname — and run:

.. code-block:: bash

   git clone --depth=1 https://github.com/bmack/tryout.git my-typo3-site
   cd my-typo3-site
   rm -rf .git && git init
   ddev start

``--depth=1`` followed by ``git init`` leaves you with a clean repository and
no upstream history, ready to be pushed somewhere as your own project. Keep
the history instead if you intend to contribute back to the scaffold itself.

.. note::

   The DDEV project name is derived from the folder because ``.ddev/config.yaml``
   deliberately has no ``name`` field. ``my-typo3-site`` becomes
   ``https://my-typo3-site.ddev.site/``. See :doc:`/getting-started/instances` for what that
   makes possible.

What the first start does
=========================

The ``post-start`` hook runs six numbered steps and prints each one. On the
first start all six do work; on later starts most of them report that there
is nothing to do.

#. **Clone TYPO3 Core.** If ``typo3-core/`` has no ``.git``, the repository is
   cloned from ``https://github.com/typo3/typo3.git`` on the branch resolved
   for this instance, and a ``gerrit`` remote is added beside ``origin``. This
   is the slow step — several minutes on a first run.
#. **Apply patches.** If ``TRYOUT_PATCHES`` is set, Core is reset to the
   current branch and each listed change is cherry-picked. See
   :doc:`/core/patches`.
#. **Composer install.** Dependencies are resolved from the two path
   repositories; every system extension is symlinked out of the Core clone.
#. **TYPO3 setup.** Only when ``config/system/settings.php`` is absent. The
   database driver and server type are derived from the DDEV configuration,
   and ``vendor/bin/typo3 setup`` runs non-interactively with the admin
   credentials from ``.ddev/config.yaml``.
#. **Extension setup and cache flush.** ``typo3 extension:setup`` followed by
   ``typo3 cache:flush``.
#. **Render the documentation.** This manual is rendered into ``.site/`` and
   served at ``/_docs/``. The step never fails a start — a broken link in the
   manual is not a reason for an instance not to come up — and it is skipped
   entirely with ``TRYOUT_DOCS=0``. On the first start it also installs the
   renderer, which is the only slow part of it. See
   :doc:`/reference/documentation`.

:doc:`/reference/architecture` follows the same six steps in more detail,
including what each one reads and writes.

Signing in
==========

When the hook has finished it prints the URL and the credentials:

.. list-table::
   :widths: 20 80

   * - Backend
     - ``https://<project-name>.ddev.site/typo3/``
   * - User
     - ``admin``
   * - Password
     - ``Password.1``

The credentials come from ``TYPO3_SETUP_ADMIN_USERNAME``,
``TYPO3_SETUP_ADMIN_PASSWORD`` and ``TYPO3_SETUP_ADMIN_EMAIL`` in
``.ddev/config.yaml``. They are consumed once, during step 4 — changing them
afterwards has no effect on an existing installation, because the user is
already in the database. Use ``ddev tryout delete`` to start over.

.. warning::

   These are development credentials on a container that is reachable from
   your machine only. Never expose a tryout instance publicly:
   ``config/system/additional.php`` sets ``displayErrors``, an open
   ``devIPmask`` and a permissive ``trustedHostsPattern`` on purpose.

Checking the result
===================

``ddev tryout status`` is the one command that answers "what state is this
instance in":

.. code-block:: text

   TYPO3 tryout — Status
   ─────────────────────────────────────
     Core:      ✓ main (a1b2c3d) — clean
                2 hours ago
     Patches:   none applied
     Config:    no patches configured
     Packages:  none in packages/
     Composer:  ✓ installed
     TYPO3:     ✓ configured
     Contrib:   not configured
                → ddev cs
     Site:      https://my-typo3-site.ddev.site
   ─────────────────────────────────────

Each line that reports a problem also prints the command that fixes it.
:doc:`/reference/commands` has the full output vocabulary.

What is tracked and what is not
===============================

The repository holds the scaffold, not the installation. ``.gitignore``
excludes everything that is generated:

.. list-table::
   :header-rows: 1
   :widths: 40 60

   * - Path
     - Why it is ignored
   * - ``typo3-core/``
     - The Core clone, managed by git and by ``ddev tryout``.
   * - ``vendor/``, ``public/``, ``var/``, ``composer.lock``
     - Composer output. The lock file in particular is regenerated whenever
       the Core branch changes.
   * - ``config/system/settings.php``, ``config/sites/``
     - Written by the TYPO3 setup and by the backend.
   * - ``.ddev/config.local.yaml``
     - Personal DDEV overrides — see :doc:`/reference/configuration`.
   * - ``packages/*``
     - Your extensions are yours; only ``packages/.gitkeep`` is tracked.
   * - ``.renderer/``, ``.site/``
     - The documentation renderer and the site it produces — see
       :doc:`/reference/documentation`.

Removing the instance
=====================

.. code-block:: bash

   ddev delete -O          # drop the DDEV project and its database
   cd .. && rm -rf my-typo3-site

``ddev tryout delete`` is a different thing: it wipes the database and the
TYPO3 configuration but keeps the project and the Core clone, so the next
start builds a fresh installation on the same code. See :doc:`/reference/commands`.
