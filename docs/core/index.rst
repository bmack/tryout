:navigation-title: Core

==========
Core
==========

Everything that concerns the TYPO3 Core checkout in ``typo3-core/``: pulling in
changes that are still under review, following a different major version, and
sending a change of your own to Gerrit.

.. toctree::
   :titlesonly:
   :hidden:

   patches
   versions
   contributing

.. grid::

   .. card:: :doc:`/core/patches`
      :tag: Test

      Apply a Gerrit change by number, apply a whole list on every start, and
      read what the summary table is telling you.

   .. card:: :doc:`/core/versions`
      :tag: Switch

      Move the Core branch between ``main`` and the maintained versions, and
      why ``composer.json`` is rewritten when you do.

   .. card:: :doc:`/core/contributing`
      :tag: Submit

      Turn the instance into a contribution workspace: hooks, commit template,
      Gerrit push URL, and the doctor that checks all four.

.. note::

   Reading from Gerrit needs no account — fetching and cherry-picking a change
   is anonymous. Only pushing does, which is why
   :doc:`/core/contributing` is opt-in and nothing about it runs on
   ``ddev start``.
