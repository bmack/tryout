:navigation-title: Configuration

=============
Configuration
=============

Every file and every variable the scaffold reads, and where to override each
one without putting your personal settings into the repository's history.

The DDEV configuration files
============================

DDEV merges every ``.ddev/config.*.yaml`` on top of ``config.yaml``, in
alphabetical order. This project uses three of them, and the split is by
audience rather than by topic.

``config.yaml`` — tracked
-------------------------

The shared stack. Changing it changes it for everybody who clones the project.

.. code-block:: yaml
   :caption: .ddev/config.yaml

   type: typo3
   docroot: public
   php_version: "8.5"
   webserver_type: apache-fpm
   database:
     type: mariadb
     version: "10.11"
   composer_version: "2"
   nodejs_version: "22"
   xdebug_enabled: false
   disable_settings_management: false

   web_environment:
     - TYPO3_CONTEXT=Development
     - TYPO3_DB_HOST=db
     - TYPO3_DB_PORT=3306
     - TYPO3_DB_DBNAME=db
     - TYPO3_DB_USERNAME=db
     - TYPO3_DB_PASSWORD=db
     - TYPO3_SETUP_ADMIN_USERNAME=admin
     - TYPO3_SETUP_ADMIN_PASSWORD=Password.1
     - TYPO3_SETUP_ADMIN_EMAIL=admin@example.com

   hooks:
     post-start:
       - exec-host: bash .ddev/scripts/post-start.sh

.. important::

   There is **no** ``name`` field, and that is a feature rather than an
   omission. DDEV falls back to the folder name, which is what lets every
   clone and every git worktree be its own project without editing anything.
   See :doc:`/getting-started/instances`.

``config.patches.yaml`` — tracked
---------------------------------

One variable, kept in its own file so a patch list can be committed to a
feature branch without touching the shared stack.

.. code-block:: yaml
   :caption: .ddev/config.patches.yaml

   web_environment:
     - TRYOUT_PATCHES=

``config.local.yaml`` — gitignored
----------------------------------

Everything personal: a different PHP version, Xdebug, your Gerrit username, a
pinned Core branch. It is merged last, so it wins.

.. code-block:: yaml
   :caption: .ddev/config.local.yaml

   php_version: "8.4"
   xdebug_enabled: true

   web_environment:
     - TRYOUT_BRANCH=14.3
     - TRYOUT_GERRIT_USER=jdoe

.. note::

   ``web_environment`` is a list, and DDEV **replaces** the list rather than
   merging entry by entry when the same key appears in several files. Keep
   each variable in exactly one file: ``TRYOUT_PATCHES`` in
   ``config.patches.yaml``, your own in ``config.local.yaml``.

Environment variables
=====================

Variables the scaffold defines
------------------------------

.. list-table::
   :header-rows: 1
   :widths: 25 20 55

   * - Variable
     - Default
     - Effect
   * - ``TRYOUT_PATCHES``
     - empty
     - Comma-separated Gerrit change numbers. Non-empty means the
       ``post-start`` hook resets Core to the branch tip and cherry-picks
       them on every start. Also the list ``ddev tryout patch`` uses without
       an argument.
   * - ``TRYOUT_BRANCH``
     - unset
     - Forces the active Core branch. Wins over the branch actually checked
       out, so it is mainly for pinning a branch *before* the first clone.
   * - ``TRYOUT_GERRIT_USER``
     - unset
     - Your review.typo3.org username. Second in the resolution order used by
       ``ddev cs``, after the command argument.
   * - ``TRYOUT_DOCS``
     - ``1``
     - Set to ``0`` to stop the ``post-start`` hook rendering this manual. The
       step is never fatal either way; the variable is for skipping the
       renderer install on a first start you want kept short.

Variables TYPO3 consumes
------------------------

.. list-table::
   :header-rows: 1
   :widths: 35 65

   * - Variable
     - Effect
   * - ``TYPO3_CONTEXT``
     - ``Development``. Turns on the development configuration presets.
   * - ``TYPO3_DB_HOST``, ``TYPO3_DB_PORT``, ``TYPO3_DB_DBNAME``,
       ``TYPO3_DB_USERNAME``, ``TYPO3_DB_PASSWORD``
     - Read by ``vendor/bin/typo3 setup`` during the first start. At runtime
       the connection comes from ``config/system/additional.php`` instead.
   * - ``TYPO3_SETUP_ADMIN_USERNAME``, ``TYPO3_SETUP_ADMIN_PASSWORD``,
       ``TYPO3_SETUP_ADMIN_EMAIL``
     - The backend user created by the setup. Read exactly once, because the
       setup step is skipped as soon as ``config/system/settings.php``
       exists. Change them and run ``ddev tryout delete`` to take effect.
   * - ``TYPO3_DB_DRIVER``
     - Not configured anywhere — it is derived from ``DDEV_DATABASE`` and
       exported by the scripts for the duration of the setup call.

Variables DDEV provides
-----------------------

The scripts read four of them and set none:

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Variable
     - Used for
   * - ``DDEV_APPROOT``
     - The project root. Everything else is derived from it — ``typo3-core/``,
       ``packages/``, the script directory.
   * - ``DDEV_DATABASE``
     - Deriving the database driver and port, both during setup and in
       ``additional.php``.
   * - ``DDEV_WEBSERVER_TYPE``
     - Deriving ``--server-type`` for the TYPO3 setup.
   * - ``DDEV_PRIMARY_URL``
     - The URL printed by ``status`` and by the post-start hook.

Constants in ``functions.sh``
=============================

Not configuration in the sense of something you set, but the values every
command shares. Edit them only if you are pointing the scaffold at a different
repository or review server.

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Name
     - Value
   * - ``CORE_REPO``
     - ``https://github.com/typo3/typo3.git``
   * - ``GERRIT_REMOTE``
     - ``https://review.typo3.org/Packages/TYPO3.CMS`` — the anonymous fetch
       URL added as the ``gerrit`` remote.
   * - ``GERRIT_API``
     - ``https://review.typo3.org``
   * - ``GERRIT_SSH_HOST`` / ``GERRIT_SSH_PORT``
     - ``review.typo3.org`` / ``29418``
   * - ``GERRIT_PROJECT``
     - ``Packages/TYPO3.CMS``
   * - ``COMMIT_TEMPLATE_SRC``
     - ``.ddev/templates/gitmessage.txt``

Git configuration
=================

``ddev cs`` writes three values, all of them in the Core clone rather than
globally:

.. list-table::
   :header-rows: 1
   :widths: 35 65

   * - Key
     - Value
   * - ``tryout.gerritUser``
     - The cached username, so you are prompted once per clone.
   * - ``commit.template``
     - ``../.ddev/templates/gitmessage.txt`` — relative to the ``typo3-core``
       working tree, so it resolves both on the host and in the container.
   * - ``remote.origin.pushurl``
     - ``ssh://<user>@review.typo3.org:29418/Packages/TYPO3.CMS``. The fetch
       URL is left on GitHub.

``ddev cs uninstall`` removes all three. In a shared worktree setup these live
in the common git directory and therefore apply to every instance — see
:doc:`/getting-started/instances`.

TYPO3 configuration
===================

``config/system/additional.php``
--------------------------------

Tracked, and guarded by ``IS_DDEV_PROJECT`` so it does nothing outside DDEV. It
sets:

.. list-table::
   :header-rows: 1
   :widths: 25 75

   * - Section
     - Value
   * - ``DB``
     - Host ``db``, user/password/database all ``db``. The driver is
       ``pdo_pgsql`` on port 5432 when ``DDEV_DATABASE`` starts with
       ``postgres``, otherwise ``mysqli`` on 3306.
   * - ``GFX``
     - ImageMagick in ``/usr/bin/``.
   * - ``MAIL``
     - SMTP to ``localhost:1025`` without encryption — the DDEV mail catcher.
   * - ``SYS``
     - ``trustedHostsPattern`` open, ``devIPmask`` ``*``, ``displayErrors``
       on.

.. warning::

   Those three ``SYS`` values are why a tryout instance must never be
   reachable from the internet. They are correct for a container on your own
   machine and dangerous anywhere else.

``config/system/settings.php``
------------------------------

Written by the TYPO3 setup, gitignored, and the flag the ``post-start`` hook
tests to decide whether an installation already exists. Deleting it and
starting is *not* a supported way to reinstall — use ``ddev tryout delete``,
which also drops the database.

``composer.json``
=================

Tracked, but machine-written by ``ddev tryout composer``. What you may safely
edit by hand:

- **Requirements outside** ``typo3/cms-*`` and ``typo3/theme-*``. The
  regeneration keeps them.
- **Everything that is not** ``require`` — repositories, config, scripts,
  autoload. Only the ``require`` section is rewritten.

Anything you add under ``typo3/cms-`` is removed the next time the file is
regenerated, because that namespace is owned by the Core clone.
