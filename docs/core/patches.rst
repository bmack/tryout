:navigation-title: Gerrit patches

======================
Working with patches
======================

TYPO3 Core changes are reviewed on `review.typo3.org
<https://review.typo3.org>`__, and every change there has a number. tryout
turns that number into a working instance: the latest patchset is resolved
through the Gerrit REST API, fetched from the ``gerrit`` remote and
cherry-picked onto your Core branch.

Applying one change
===================

.. code-block:: bash

   ddev tryout patch 56947

The change number is the one in the review URL —
``https://review.typo3.org/c/Packages/TYPO3.CMS/+/56947``. You never name a
patchset: the API is asked for the current revision, so re-running the command
after the author pushes a new patchset picks up the new one.

Output for a change that applies cleanly:

.. code-block:: text

   ==> Resolving change 56947...
     Subject:  [BUGFIX] Do not swallow the exception in FormEngine
     Patchset: 12
     Status:   NEW
   ==> Fetching from Gerrit...
   ==> Cherry-picking change 56947...
   ==> Applied change 56947: [BUGFIX] Do not swallow the exception in FormEngine

A successful cherry-pick is followed by a rebuild — ``composer install``,
``typo3 extension:setup`` and a cache flush — so a patch that touches an
extension's configuration is live immediately.

Applying a list on every start
==============================

Put the change numbers into ``.ddev/config.patches.yaml``:

.. code-block:: yaml
   :caption: .ddev/config.patches.yaml

   web_environment:
     - TRYOUT_PATCHES=56947,12345

Then:

.. code-block:: bash

   ddev restart

On every start the ``post-start`` hook **resets Core to the branch tip first**
and then cherry-picks the listed changes in order. That is what makes the list
reproducible: the instance is always the branch plus exactly these changes, and
never the accumulated result of whatever was applied last week.

.. note::

   ``ddev tryout patch`` without an argument applies the same list, but it does
   *not* reset first — it adds the changes to whatever is currently checked
   out. Use ``ddev tryout reset`` followed by ``ddev tryout patch`` when you
   want the start-up behaviour on demand.

Reading the summary
===================

Applying a list prints a table when it is done:

.. code-block:: text

   Patch Summary
   Change     Subject                               Result
   ────────── ───────────────────────────────────── ──────────
   56947      [BUGFIX] Do not swallow the excep...  applied
   12345      [TASK] Streamline the cache fron...   merged

.. list-table::
   :header-rows: 1
   :widths: 25 75

   * - Result
     - Meaning
   * - ``applied``
     - The patchset was cherry-picked onto your branch.
   * - ``already_applied``
     - A commit with the same ``Change-Id`` is already on top of the branch
       tip. Nothing was done.
   * - ``merged``
     - Gerrit reports the change as merged, so it is part of the branch
       already. Skipped.
   * - ``abandoned``
     - The change was abandoned by its author. Skipped, with a warning.
   * - ``conflict``
     - The cherry-pick hit a merge conflict. It was aborted automatically, so
       the working tree is clean, and the remaining patches in the list are
       skipped.
   * - ``error``
     - The change could not be resolved or fetched — a wrong number, a
       network problem, or a Gerrit response that could not be parsed.

A list stops at the first failure rather than pressing on, so a conflict in the
first change does not bury itself under three more results.

When a patch conflicts
======================

A conflicting cherry-pick is aborted for you: ``git cherry-pick --abort`` runs
before the error is printed, and ``typo3-core/`` is left exactly as it was.
Usually the change is simply based on an older branch tip. Two ways out:

.. code-block:: bash

   ddev tryout download        # update the branch, then try again
   ddev tryout patch 56947

.. code-block:: bash

   ddev tryout reset           # or start over from the branch tip

If the conflict is real, it belongs upstream — the author needs to rebase the
change in Gerrit.

Seeing what is applied
======================

.. code-block:: bash

   ddev tryout status

The **Patches** line counts the commits between ``origin/<branch>`` and
``HEAD`` and lists their subjects, so it shows what is really on the checkout
rather than what was configured. The **Config** line shows
``TRYOUT_PATCHES``. The two disagreeing is normal after applying something by
hand.

To go back to a clean branch tip:

.. code-block:: bash

   ddev tryout reset

How resolution works
====================

Worth knowing when a change refuses to resolve:

#. ``https://review.typo3.org/changes/<number>?o=CURRENT_REVISION`` is
   requested **from inside the web container**, because ``curl`` and ``jq`` are
   guaranteed to be there and not on every host.
#. Gerrit prefixes its JSON with the XSSI guard ``)]}'``; the first line is
   dropped before parsing.
#. Four values are read out: the subject, the ref of the current revision
   (``refs/changes/47/56947/12``), its patchset number and the change status.
#. The ref is fetched from the ``gerrit`` remote — anonymously over HTTPS, so
   no account is needed to test a patch.
#. Before cherry-picking, the ``Change-Id`` footer of the fetched commit is
   compared against every commit in ``origin/<branch>..HEAD`` to detect a
   change that is already applied.

Only pushing to Gerrit needs an account. See :doc:`/core/contributing`.
