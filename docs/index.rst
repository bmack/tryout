:navigation-title: Home
:layout: marketing

=====================================
A TYPO3 Core workspace in one command
=====================================

.. hero:: /_images/tryout-workbench.png

   Clone the repository, run ``ddev start``, and a few minutes later a TYPO3
   instance is running against a real clone of the Core git repository — not a
   released package. Every system extension is symlinked out of that clone, so
   an edit in ``typo3-core/`` is live on the next request.

   .. toctree::
      :titlesonly:
      :hidden:

      getting-started/index
      core/index
      reference/index
      troubleshooting

   .. button-bar::

      .. button:: :doc:`/getting-started/installation`
         :icon: actions-rocket
         :size: lg

      .. button:: The source
         :href: https://github.com/bmack/tryout
         :variant: secondary
         :size: lg
         :rel: external

.. band:: What the scaffold is for
   :id: audience

tryout is aimed at three kinds of work, and the same instance serves all of
them. Nothing here is a TYPO3 distribution: it is the development environment
around the Core repository.

.. grid:: flush

   .. card:: Contribute to Core
      :href: /core/contributing
      :label: Core contributors
      :icon: actions-code-merge
      :action: Set up contribution

      One opt-in command installs the Gerrit hooks, the commit-message
      template and the SSH push URL, and a doctor command tells you which of
      them are actually wired up.

   .. card:: Test a patch before it lands
      :href: /core/patches
      :label: Reviewers
      :icon: actions-code-pull-request
      :action: Apply a patch

      Give a change number from review.typo3.org and the latest patchset is
      resolved, fetched and cherry-picked onto your Core branch.

   .. card:: Build an extension against Core
      :href: /getting-started/extensions
      :label: Extension developers
      :icon: actions-extension
      :action: Add an extension

      Drop a package into ``packages/`` and Composer resolves it from the
      local path — no Packagist release, no second checkout.

.. band:: How it works
   :quiet:
   :id: how

.. split::
   :align: center

   .. half:: Two path repositories and a hook

      ``composer.json`` declares ``packages/*`` and
      ``typo3-core/typo3/sysext/*`` as path repositories. Every system
      extension is required at ``@dev`` and installed as a symlink, so the
      running instance and the git clone are the same files.

      The ``post-start`` hook is what makes ``ddev start`` enough: it clones
      Core if it is missing, re-applies the configured Gerrit patches,
      installs dependencies and — on the first run only — sets TYPO3 up
      against the DDEV database.

      Switching major versions is one command, because the set of system
      extensions is read off disk and written back into ``composer.json``
      rather than maintained by hand.

   .. half::

      .. code-block:: text
         :caption: What ends up on disk

         tryout/
         ├── .ddev/
         │   ├── commands/host/     ddev tryout, ddev cs
         │   └── scripts/           post-start, shared functions
         ├── config/system/         DDEV-specific TYPO3 configuration
         ├── packages/              your extensions
         ├── composer.json          generated from the Core clone
         └── typo3-core/            the Core clone (gitignored)

.. band:: What a running instance looks like
   :id: instance

.. grid::

   .. stat:: 1
      :label: command to start
      :icon: actions-terminal

      ``ddev start`` clones, installs, sets up and flushes caches. The second
      start skips everything that is already done.

   .. stat:: 2
      :label: entry points for every task
      :icon: actions-list

      ``ddev tryout`` manages Core, patches and versions. ``ddev cs`` turns
      the instance into a contribution workspace.

   .. stat:: 0
      :label: shared state between instances
      :icon: actions-duplicates

      The DDEV project name comes from the folder, so every clone and every
      worktree gets its own database, URL and set of patches.

.. band:: Start where the work is
   :quiet:
   :id: start

.. grid:: flush

   .. card:: Get an instance running
      :href: /getting-started/index
      :label: Getting started
      :action: Install it

      Requirements and the first start, your own extensions in ``packages/``,
      and several instances side by side.

   .. card:: Work on the Core checkout
      :href: /core/index
      :label: Core
      :action: Open the Core pages

      Test a Gerrit change, follow another TYPO3 version, and set the instance
      up to submit a patch of your own.

   .. card:: Look something up
      :href: /reference/index
      :label: Reference
      :action: Open the reference

      Every subcommand, every configuration file and variable, and how the
      scaffold is put together.

   .. card:: Get out of trouble
      :href: /troubleshooting
      :label: Troubleshooting
      :action: Read the symptoms

      The failures that actually happen — a failed clone, a conflicting patch,
      a rejected push — and the command that fixes each one.
