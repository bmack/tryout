:navigation-title: TYPO3 versions

========================
Switching TYPO3 versions
========================

A tryout instance follows one branch of the Core repository at a time. By
default that is ``main`` — the latest development state.

.. important::

   TYPO3 uses a ``main``-based commit workflow. Changes are committed to
   ``main`` first and picked to the maintained branches by the mergers, so even
   a fix that targets an older version should be developed and pushed against
   ``main``. Check out an older branch to *reproduce* a bug, not to write the
   patch for it.

Switching
=========

.. code-block:: bash

   ddev tryout checkout 14.3
   ddev tryout checkout main

Run it without an argument to see what is available:

.. code-block:: bash

   ddev tryout checkout

That prints a few examples and then the full list of remote branches, read live
from ``origin``. A name that does not exist upstream is refused before anything
is changed.

One command covers three things:

#. The Core clone is fetched, checked out on the target branch and hard-reset
   to ``origin/<branch>``, followed by ``git clean -fd`` and a cleared
   ``var/cache/``.
#. ``composer.json`` is regenerated for that branch, and ``composer.lock`` is
   deleted.
#. The instance is rebuilt: ``composer install``, ``typo3 extension:setup``,
   cache flush.

.. warning::

   The hard reset means uncommitted work and applied patches in
   ``typo3-core/`` are discarded. Push or stash anything you care about first.

The database is **not** touched. Switching to an older branch leaves a schema
from a newer one in place, which TYPO3 will complain about in unhelpful ways.
Run ``ddev tryout delete`` after switching between majors to get a matching
installation.

Why ``composer.json`` is rewritten
==================================

Different TYPO3 versions ship different sets of system extensions — v13 has
extensions v12 never had, and v14 dropped some that v13 required. The
``require`` section therefore cannot be a fixed list; it has to describe what
is on disk.

``.ddev/scripts/sync-composer.php`` does exactly that:

#. It reads every ``typo3-core/typo3/sysext/*/composer.json`` and collects the
   package names.
#. It drops the existing requirements whose names start with ``typo3/cms-`` or
   ``typo3/theme-`` — the managed ones — and keeps everything else, so a
   package you required from ``packages/`` survives.
#. It adds every discovered system extension at ``@dev``.
#. On ``main`` and on branches numbered 14 or higher it adds
   ``typo3/theme-camino``.
#. It sorts the result and writes it back.

Finally it deletes ``composer.lock``. That is not tidiness: without it, the
next ``composer install`` would try to satisfy a lock file that still names an
extension the new branch no longer has.

You can run the step on its own at any time:

.. code-block:: bash

   ddev tryout composer

Do that after pulling a Core change that adds or removes a system extension —
``composer install`` alone will not notice.

Pinning the branch
==================

The active branch is resolved in this order:

#. ``TRYOUT_BRANCH``, if it is set
#. the branch currently checked out in ``typo3-core/``
#. ``main``

For a fresh instance only the first two apply, and the environment variable is
the only one that exists before the clone. Set it in
``.ddev/config.local.yaml`` — which is gitignored — to make an instance clone
an older branch from the start:

.. code-block:: yaml
   :caption: .ddev/config.local.yaml

   web_environment:
     - TRYOUT_BRANCH=14.3

After that, ``ddev start`` on an empty project clones 14.3 directly instead of
cloning ``main`` and switching afterwards.

.. note::

   Once ``typo3-core/`` exists, ``ddev tryout checkout`` is the thing that
   changes branches. ``TRYOUT_BRANCH`` still wins in the commands' own
   resolution, so leaving a stale value in ``config.local.yaml`` after
   switching by hand makes ``reset`` and ``download`` disagree with what is
   checked out. Keep the two in sync, or leave the variable unset.
