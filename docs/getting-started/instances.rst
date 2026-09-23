:navigation-title: Multiple instances

===================
Multiple instances
===================

Testing two Gerrit changes side by side, or comparing v13 with ``main``, means
running more than one instance. That works without any configuration, because
``.ddev/config.yaml`` has **no** ``name`` field: DDEV derives the project name
from the folder.

.. code-block:: bash

   # Main checkout
   git clone <this-repo> tryout
   cd tryout && ddev start          # → project "tryout", https://tryout.ddev.site

   # A worktree of the scaffold
   git worktree add ../tryout-wip
   cd ../tryout-wip && ddev start   # → project "tryout-wip", https://tryout-wip.ddev.site

   # A separate clone
   git clone <this-repo> tryout-v12
   cd tryout-v12 && ddev start      # → project "tryout-v12", https://tryout-v12.ddev.site

Each one gets its own database, its own TYPO3 installation, its own Core clone
and its own set of patches. Nothing is shared unless you make it shared.

To use a name other than the folder name:

.. code-block:: bash

   ddev config --project-name=my-custom-name
   ddev start

Sharing one Core checkout
=========================

The cost of that isolation is a full Core clone per instance — roughly a
gigabyte each, and a separate fetch every time. Because the ``post-start`` hook
only clones when ``typo3-core/`` does not exist, you can pre-seed it as a
**git worktree** of one shared clone instead. All instances then share a single
object store: one place to fetch, far less disk, instant switching.

One-time: the shared clone
--------------------------

.. code-block:: bash

   git clone https://github.com/typo3/typo3.git ~/typo3-core-shared
   cd ~/typo3-core-shared
   # optional, so patches can be fetched from Gerrit
   git remote add gerrit https://review.typo3.org/Packages/TYPO3.CMS

Per instance: attach instead of clone
-------------------------------------

Run this in the tryout folder **before** the first ``ddev start``:

.. code-block:: bash

   cd /path/to/tryout
   git -C ~/typo3-core-shared worktree add --detach "$PWD/typo3-core" main
   ddev start

The hook sees that ``typo3-core/`` already exists and skips step 1 entirely.

``--detach`` is not optional in practice. Git refuses to check out one branch in
two worktrees, so without it the second instance cannot be based on the same
branch as the first. Detached HEADs pointing at the same commit are fine, and
each instance can then cherry-pick a different change on top:

.. code-block:: bash

   cd /path/to/tryout      && ddev tryout patch 56947
   cd /path/to/tryout-wip  && ddev tryout patch 57001

.. note::

   The scaffold's commands handle a worktree correctly: when
   ``typo3-core/.git`` is a *file* rather than a directory, the real git
   directory is resolved with ``git rev-parse --git-common-dir``. That is what
   makes ``ddev cs`` install its hooks in the right place.

Cleaning up
-----------

.. code-block:: bash

   git -C ~/typo3-core-shared worktree remove /path/to/tryout/typo3-core
   git -C ~/typo3-core-shared worktree prune

Trade-offs
----------

- All worktrees share one object store. A ``git gc`` or a fetch in one instance
  affects every other one — avoid heavy git maintenance in two instances at
  the same time.
- Git hooks live in the common git directory, so ``ddev cs`` in one instance
  configures the hooks for all of them. The commit template and the push URL
  are shared as well.
- Composer path repositories still point at each instance's own
  ``typo3-core/typo3/sysext/*``, so symlinks and autoloading behave exactly as
  they do with separate clones.
- This is complementary to ``git worktree add ../tryout-wip`` on the scaffold
  itself: that shares the tryout project, this shares the Core codebase
  underneath it.

Resource use
============

Every instance is a full container stack. If several are running at once and
things get slow, stop the ones you are not using:

.. code-block:: bash

   ddev list                 # every project and its state
   ddev stop tryout-v12      # free its containers
   ddev poweroff             # stop everything at once
