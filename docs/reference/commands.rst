:navigation-title: Commands

========
Commands
========

Two commands are added to DDEV by this scaffold. Both are defined in
``.ddev/commands/host/`` and run **on the host**, shelling out to
``ddev composer``, ``ddev exec`` and ``ddev typo3`` for anything that has to
happen inside the container. That is why a ``bash`` shell on the host is a
requirement.

.. list-table::
   :header-rows: 1
   :widths: 25 75

   * - Command
     - What it owns
   * - ``ddev tryout``
     - The Core checkout: cloning, updating, switching versions, applying
       patches, resetting and wiping the installation.
   * - ``ddev cs``
     - The contribution setup: git hooks, commit-message template and the
       Gerrit push URL.
   * - ``ddev docs``
     - Rendering this manual.

All three print their own help when called with ``help`` or with an unknown
subcommand.

ddev tryout
===========

status
------

.. code-block:: bash

   ddev tryout status

Prints an overview and exits. Nothing is changed. The report covers:

**Core**
   Current branch, short commit, relative commit date, and whether the working
   tree is clean or dirty. If ``typo3-core/`` has no git directory at all, the
   report stops here and points at ``ddev tryout download``.

**Patches**
   The number of commits in ``origin/<branch>..HEAD`` — that is, everything
   cherry-picked on top of the branch tip — followed by up to ten of their
   subject lines.

**Config**
   The value of ``TRYOUT_PATCHES``, so you can see what the next start would
   re-apply.

**Packages**
   Every directory in ``packages/``.

**Composer** and **TYPO3**
   Whether ``vendor/`` exists and whether ``config/system/settings.php`` has
   been written.

**Contrib**
   ``ready`` when all four pieces of the contribution setup are in place,
   ``partial`` with a list of what is wired up, or ``not configured``. See
   :doc:`/core/contributing`.

download
--------

.. code-block:: bash

   ddev tryout download
   ddev tryout download --reset      # or -r

Without arguments this is an **update**: it fetches ``origin`` and rebases the
current branch. It refuses to run — with the ``--reset`` hint — when the
checkout is not on the branch this instance resolved, or when the working tree
has uncommitted changes. A failed pull is reported rather than left half done.

With ``--reset`` it is a **hard reset**: fetch, checkout the branch, ``reset
--hard origin/<branch>``, ``git clean -fd`` and clear ``var/cache/``. Local
commits, applied patches and uncommitted work in ``typo3-core/`` are lost.

If ``typo3-core/`` does not exist yet, either form clones it and adds the
``gerrit`` remote, and stops there. Both other forms finish with a rebuild:
``composer install``, ``typo3 extension:setup``, cache flush.

checkout
--------

.. code-block:: bash

   ddev tryout checkout 14.3
   ddev tryout checkout main
   ddev tryout checkout               # lists the available branches

Switches the Core clone to another branch and rebuilds everything around it.
The branch is verified against the remote first; an unknown name prints the
list of remote branches and exits non-zero. Because a hard reset is part of the
switch, anything uncommitted in ``typo3-core/`` is discarded.

After the switch, ``composer.json`` is regenerated and the instance is rebuilt.
:doc:`/core/versions` explains why that regeneration is necessary.

composer
--------

.. code-block:: bash

   ddev tryout composer

Regenerates the ``require`` section of ``composer.json`` from the system
extensions that are actually present in ``typo3-core/typo3/sysext/``, then
deletes ``composer.lock``. It does not run ``composer install`` itself.

This is the same step ``checkout`` performs; run it by hand after pulling a
Core change that adds or removes a system extension.

patch
-----

.. code-block:: bash

   ddev tryout patch 56947      # a single Gerrit change
   ddev tryout patch            # everything in TRYOUT_PATCHES

Resolves each change number through the Gerrit REST API, fetches its latest
patchset and cherry-picks it onto the current Core branch. Merged and
abandoned changes are reported and skipped; a change that is already applied is
recognised by its ``Change-Id`` and skipped as well.

Called without a change number and with no patches configured, it prints how
to configure them instead of doing nothing silently. :doc:`/core/patches` covers the
whole workflow, including the summary table and what each result means.

reset
-----

.. code-block:: bash

   ddev tryout reset

Two steps: reset the Core clone to ``origin/<branch>`` exactly as
``download --reset`` does, then rebuild. Use this to get back to a known state
after a failed patch series.

The database and ``config/system/settings.php`` are untouched — content and
backend users survive a reset.

delete
------

.. code-block:: bash

   ddev tryout delete

The destructive one, and the only command that asks for confirmation. In five
steps it drops and recreates the database, empties ``public/fileadmin/``,
removes ``config/system/settings.php``, runs the TYPO3 setup again and
finishes with ``extension:setup`` and ``cache:flush``.

The result is a fresh installation on the same Core checkout, with the admin
credentials from ``.ddev/config.yaml`` restored.

.. warning::

   Everything in the database and every uploaded file is gone. There is no
   backup step — take a ``ddev snapshot`` first if the content matters.

ddev cs
=======

``cs`` is short for *contribution setup*. Nothing in it runs automatically;
``ddev start`` deliberately leaves the instance read-only against Gerrit.

setup
-----

.. code-block:: bash

   ddev cs              # setup is the default subcommand
   ddev cs setup jdoe

Resolves your Gerrit username, then installs four things: the ``commit-msg``
hook, the ``pre-commit`` hook, the commit-message template and the Gerrit SSH
push URL. It finishes with an SSH probe whose result is informational — a
failed probe does not undo the setup.

The username is resolved in this order:

#. the command argument
#. the ``TRYOUT_GERRIT_USER`` environment variable
#. ``git config tryout.gerritUser`` in the Core clone, cached from a previous
   run
#. an interactive prompt

doctor
------

.. code-block:: bash

   ddev cs doctor

Reports each of the four pieces separately and then probes Gerrit over SSH
live. The probe distinguishes four failure modes — no username, the port not
reachable, no key in your SSH agent, and keys rejected by Gerrit — and prints
the matching next step for each.

uninstall
---------

.. code-block:: bash

   ddev cs uninstall

Removes the two hooks, unsets ``commit.template``, resets the ``origin`` push
URL back to its fetch URL and drops the cached username. The Core clone is left
in place and untouched otherwise.

ddev docs
=========

.. code-block:: bash

   ddev docs             # build is the default subcommand
   ddev docs update      # pull a newer theme release
   ddev docs clean       # remove .site/ and .renderer/

Renders ``docs/`` into ``.site/``, which the web server maps to
``<project>.ddev.site/_docs/`` — nothing is written into ``public/``. The
renderer is installed into ``.renderer/`` on first use, from the container's
PHP and Node, so nothing is needed on the host.

:doc:`/reference/documentation` covers the render pipeline, the alternative that does not
use DDEV at all, and what a new page is expected to look like.

Where the DDEV commands stop
============================

Everything that is plain DDEV still works and is not wrapped:

.. code-block:: bash

   ddev composer require vendor/package     # Composer inside the container
   ddev typo3 cache:flush                   # the TYPO3 CLI
   ddev mysql                               # a database shell
   ddev ssh                                 # a shell in the web container
   ddev logs -f                             # container logs
   ddev restart                             # re-runs the post-start hook
