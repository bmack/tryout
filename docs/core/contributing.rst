:navigation-title: Contributing to Core

==========================
Contributing to TYPO3 Core
==========================

Out of the box a tryout instance is read-only against Gerrit: you can fetch and
test any change, but you cannot submit one. Turning it into a contribution
workspace is a single opt-in command — nothing about it runs on ``ddev start``.

.. code-block:: bash

   ddev cs                 # prompts for your review.typo3.org username
   ddev cs setup jdoe      # or pass it explicitly

Before you start
================

You need an account on `review.typo3.org <https://review.typo3.org>`__ and a
**public SSH key uploaded** at
`review.typo3.org/settings/#SSHKeys <https://review.typo3.org/settings/#SSHKeys>`__.
The matching private key has to be loaded in the SSH agent on your host,
because ``ddev cs`` runs there:

.. code-block:: bash

   ssh-add ~/.ssh/id_ed25519

What the setup installs
=======================

Four things, all of them inside the Core clone, and each reversible:

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Piece
     - What it does
   * - ``commit-msg`` hook
     - Gerrit's own hook, copied out of ``typo3-core/Build/git-hooks/``. It
       appends a ``Change-Id`` footer to every commit — the identity Gerrit
       uses to recognise a new patchset of an existing change instead of a new
       change.
   * - ``pre-commit`` hook
     - TYPO3 Core's hook from ``typo3-core/Build/git-hooks/unix+mac/``. It runs
       the coding-guideline checks before a commit is created, so CGL problems
       surface locally instead of in the review.
   * - Commit-message template
     - ``git config commit.template`` is pointed at
       ``.ddev/templates/gitmessage.txt``. Running ``git commit`` without
       ``-m`` opens a TYPO3-style skeleton with the allowed subject prefixes
       and the ``Resolves:`` / ``Releases:`` footers already in place.
   * - Gerrit push URL
     - The push URL of ``origin`` is set to
       ``ssh://<user>@review.typo3.org:29418/Packages/TYPO3.CMS``. Fetching
       still goes to GitHub over HTTPS; only pushing goes to Gerrit.

The username
============

It is resolved in this order, and the first answer wins:

#. The command argument — ``ddev cs setup jdoe``.
#. The ``TRYOUT_GERRIT_USER`` environment variable.
#. ``git config tryout.gerritUser`` in the Core clone, cached by a previous
   setup.
#. An interactive prompt.

Whatever is resolved is written back to ``tryout.gerritUser``, so you are asked
once per Core clone. To carry it across instances, put it in the gitignored
local DDEV config:

.. code-block:: yaml
   :caption: .ddev/config.local.yaml

   web_environment:
     - TRYOUT_GERRIT_USER=jdoe

Checking the state
==================

.. code-block:: bash

   ddev cs doctor

.. code-block:: text

   Contribution Setup — Doctor
   ─────────────────────────────────────
     Gerrit user:     ✓ jdoe
     commit-msg hook: ✓ installed
     pre-commit hook: ✓ installed
     Commit template: ✓ configured
     Push URL:        ✓ ssh://jdoe@review.typo3.org:29418/Packages/TYPO3.CMS
     Gerrit SSH:      ✓ reachable (authenticated)
   ─────────────────────────────────────

The last line is a live probe, not a stored flag, and it separates four
distinct failures:

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Report
     - What to do
   * - ``network unreachable``
     - Port 29418 on ``review.typo3.org`` is not reachable from your machine.
       Usually a firewall or a VPN.
   * - ``no key in ddev-ssh-agent``
     - Your SSH agent holds no identities at all. Run
       ``ssh-add ~/.ssh/id_ed25519``.
   * - ``auth denied by Gerrit``
     - Keys were offered and refused. The public key is not on your Gerrit
       account, or the username is wrong.
   * - ``not set`` / ``missing``
     - The setup has not run, or a piece was skipped because the Core clone is
       older than the hook it was asked for.

``ddev tryout status`` carries a shorter version of the same answer on its
**Contrib** line: ``ready``, ``partial`` with the pieces it found, or
``not configured``.

Pushing a change for review
===========================

Commits are made in the Core clone, not in the project root:

.. code-block:: bash

   cd typo3-core
   git commit                                  # opens the template
   git push origin HEAD:refs/for/main

``refs/for/<branch>`` is Gerrit's magic ref: it creates a review instead of
writing to the branch. The branch is nearly always ``main`` — see
:doc:`/core/versions` for why.

A second push of an amended commit updates the existing change, as long as the
``Change-Id`` footer the hook wrote is still in the message. Amend, do not
create a new commit:

.. code-block:: bash

   git commit --amend
   git push origin HEAD:refs/for/main

The commit message
==================

The template names the prefixes Core accepts:

.. list-table::
   :header-rows: 1
   :widths: 20 80

   * - Prefix
     - For
   * - ``[FEATURE]``
     - New functionality.
   * - ``[TASK]``
     - Cleanup, refactoring, anything without behaviour change.
   * - ``[BUGFIX]``
     - Bug fixes.
   * - ``[DOCS]``
     - Documentation only.
   * - ``[SECURITY]``
     - Security-relevant fixes.
   * - ``[!!!]``
     - Prefixed to any of the above to mark a breaking change.

Keep the subject in the imperative mood, aim for 52 characters and stay under
72. The body explains *what* and *why*; the diff already says how. The footers
are ``Resolves: #12345`` (the Forge issue) and ``Releases: main, 13.4`` (the
target branches). The full rules are in the `TYPO3 contribution workflow
<https://docs.typo3.org/m/typo3/guide-contributionworkflow/main/en-us/Appendix/CommitMessage.html#commitmessage>`__.

Reverting the setup
===================

.. code-block:: bash

   ddev cs uninstall

Removes both hooks, unsets the commit template, resets the ``origin`` push URL
to its fetch URL and drops the cached username. The Core clone and your commits
stay where they are.

.. note::

   Contributions to **TYPO3 Core** go through Gerrit, not through the tryout
   repository. Improvements to the scaffold itself — new subcommands, better
   defaults, documentation — belong at
   `github.com/bmack/tryout <https://github.com/bmack/tryout>`__.
