:navigation-title: Getting started

===============
Getting started
===============

Getting an instance running, putting your own code in it, and running several
of them side by side. Start with :doc:`/getting-started/installation`; the other
two are independent of one another.

.. toctree::
   :titlesonly:
   :hidden:

   installation
   extensions
   instances

.. grid::

   .. card:: :doc:`/getting-started/installation`
      :tag: Start here

      Requirements, the clone-and-start sequence, and what the first start does
      before the backend is reachable.

   .. card:: :doc:`/getting-started/extensions`
      :tag: Your code

      Develop a custom extension side by side with Core through the
      ``packages/`` path repository.

   .. card:: :doc:`/getting-started/instances`
      :tag: More than one

      Run several instances at once, and share a single Core checkout between
      them with ``git worktree``.

.. seealso::

   :doc:`/core/index` is the other half: testing Gerrit changes, switching
   TYPO3 versions and submitting a patch of your own.
