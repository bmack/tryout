:navigation-title: Troubleshooting

===============
Troubleshooting
===============

Most failures print the command that fixes them on the next line. This page
covers the ones where the cause is not obvious from the message.

Start by asking the instance what state it thinks it is in:

.. code-block:: bash

   ddev tryout status
   ddev cs doctor        # only for the contribution setup

Starting up
===========

The clone fails or never finishes
---------------------------------

.. code-block:: text

   ✗ Failed to clone TYPO3 Core
     → Try manually: ddev tryout download

The Core repository is large and the first clone takes minutes. A genuine
failure is almost always the network or a half-written directory from an
aborted first attempt. Remove it and let the command do the clone on its own,
where you can see git's output:

.. code-block:: bash

   rm -rf typo3-core
   ddev tryout download

``composer install`` fails after a branch switch
------------------------------------------------

The error names a package — typically a ``typo3/cms-*`` extension that does not
exist on the branch you switched to. The cause is a stale ``composer.lock``.
Regenerating the manifest deletes it:

.. code-block:: bash

   ddev tryout composer
   ddev composer install

``ddev tryout checkout`` does this for you; the failure shows up when the
branch was switched with plain git inside ``typo3-core/``.

The TYPO3 setup fails
---------------------

The hook prints the exact command it tried so you can run it again and see the
full output:

.. code-block:: bash

   ddev exec env TYPO3_DB_DRIVER=mysqli vendor/bin/typo3 setup \
     --no-interaction --force --server-type=apache

If the database is the problem — a schema from another major version, a
half-finished setup — start over:

.. code-block:: bash

   ddev tryout delete

"TYPO3 Core not found at typo3-core/"
-------------------------------------

Every command that touches Core checks for it first. Either the clone never
happened, or you are in the wrong folder. ``ddev tryout download`` fixes the
first; ``ddev describe`` tells you which project you are actually talking to.

Patches
=======

A patch conflicts
-----------------

The cherry-pick is aborted for you and ``typo3-core/`` is left clean. Usually
the change is based on an older branch tip:

.. code-block:: bash

   ddev tryout download        # update the branch
   ddev tryout patch 56947     # try again

If it still conflicts, the change genuinely needs a rebase in Gerrit. Get back
to a clean state with ``ddev tryout reset``.

A change cannot be resolved
---------------------------

.. code-block:: text

   ✗ Failed to fetch change 56947 from Gerrit (HTTP error)
     → Verify: https://review.typo3.org/c/Packages/TYPO3.CMS/+/56947

The lookup runs **inside the web container**, so this is the container's view
of the network, not your host's. Open the printed URL first: a wrong change
number and an unreachable Gerrit produce the same message. If the URL works in
your browser, check whether the container has outbound HTTPS at all:

.. code-block:: bash

   ddev exec curl -sSI https://review.typo3.org | head -1

A parse error rather than an HTTP error means Gerrit answered with something
unexpected — nearly always an outage or a proxy interception page.

Patches come back after a reset
-------------------------------

``TRYOUT_PATCHES`` is still set. The ``post-start`` hook re-applies the list on
every start, which is the point of it. Clear the variable in
``.ddev/config.patches.yaml`` and ``ddev restart``.

Status and configuration disagree
---------------------------------

The **Patches** line counts what is actually on the checkout; the **Config**
line shows what would be applied on the next start. They differ whenever you
applied something by hand. ``ddev tryout reset`` followed by a restart makes
them agree.

Contribution setup
==================

``ddev cs doctor`` reports each piece separately, and the SSH probe is live.

.. list-table::
   :header-rows: 1
   :widths: 35 65

   * - Report
     - Cause and fix
   * - ``network unreachable``
     - Port 29418 is blocked. Corporate firewalls and some VPNs do this. Test
       with ``ssh -p 29418 <user>@review.typo3.org``.
   * - ``no key in ddev-ssh-agent``
     - Your host agent holds no identities at all. ``ssh-add
       ~/.ssh/id_ed25519``, then ``ssh-add -l`` to confirm.
   * - ``auth denied by Gerrit``
     - Keys were offered and rejected: the public key is not on your account,
       or the username is wrong. Upload it at
       `review.typo3.org/settings/#SSHKeys
       <https://review.typo3.org/settings/#SSHKeys>`__ and re-run
       ``ddev cs setup <user>``.
   * - ``commit-msg hook: ✗ missing``
     - The hook is copied out of ``typo3-core/Build/git-hooks/``. If it is not
       there, the Core checkout is older than the hook or the clone is
       incomplete. Update Core and run ``ddev cs`` again.

A push is rejected with "missing Change-Id"
-------------------------------------------

The commit was created before the ``commit-msg`` hook was installed. Install it
and rewrite the message — the hook runs on amend as well:

.. code-block:: bash

   ddev cs
   cd typo3-core && git commit --amend --no-edit

A push creates a second change
------------------------------

You committed again instead of amending, so the new commit got a new
``Change-Id``. Squash the two and push once more; Gerrit tracks the change by
that footer and by nothing else.

Everyday DDEV
=============

.. list-table::
   :header-rows: 1
   :widths: 40 60

   * - Symptom
     - Command
   * - The post-start hook should run again
     - ``ddev restart``
   * - Something in the web container is failing
     - ``ddev logs -f``
   * - Too many instances, everything is slow
     - ``ddev list`` then ``ddev stop <project>``, or ``ddev poweroff``
   * - A port is already in use
     - ``ddev poweroff`` and start only the project you need
   * - Caches are stale after editing Core
     - ``ddev typo3 cache:flush``; if that is not enough,
       ``rm -rf var/cache/*``
   * - The database is beyond saving
     - ``ddev tryout delete``

Starting completely over
========================

In increasing order of how much is lost:

.. code-block:: bash

   ddev tryout reset        # Core back to the branch tip, database kept
   ddev tryout delete       # fresh database and installation, Core kept
   ddev delete -O           # drop the DDEV project entirely

After ``ddev delete -O``, removing ``typo3-core/`` and ``vendor/`` and running
``ddev start`` reproduces the very first start, clone included.
