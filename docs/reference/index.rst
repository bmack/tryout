:navigation-title: Reference

=========
Reference
=========

What every command does, what every file and variable controls, and how the
scaffold is put together. The task pages are in :doc:`/getting-started/index`
and :doc:`/core/index`; this section is for looking things up.

.. toctree::
   :titlesonly:
   :hidden:

   commands
   configuration
   architecture
   documentation

.. grid::

   .. card:: :doc:`/reference/commands`
      :tag: Every subcommand

      ``ddev tryout``, ``ddev cs`` and ``ddev docs`` with their arguments and
      what each one changes on disk.

   .. card:: :doc:`/reference/configuration`
      :tag: Every knob

      Every configuration file and every environment variable this scaffold
      reads, with defaults and where to override them.

   .. card:: :doc:`/reference/architecture`
      :tag: How it works

      The repository layout, the two Composer path repositories, the six
      post-start steps and the Gerrit integration, end to end.

   .. card:: :doc:`/reference/documentation`
      :tag: This manual

      Render these pages locally with ``ddev docs``, and the conventions a new
      page is expected to follow.

.. seealso::

   :doc:`/troubleshooting` collects the failures that actually happen and the
   command that gets you out of each one.
