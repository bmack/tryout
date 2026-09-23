:navigation-title: Custom extensions

=================
Custom extensions
=================

``packages/`` is a Composer path repository. An extension folder placed there
can be required like any package, and Composer resolves it from disk instead of
from Packagist — so an extension can be developed against a Core checkout that
has not been released yet.

Adding one
==========

.. code-block:: bash

   ddev composer require myvendor/my-extension:@dev
   ddev typo3 extension:setup

The package name is the ``name`` field in the extension's own
``composer.json``, not the folder name. The folder can be called anything;
``packages/*`` is a glob and every directory below it is scanned.

.. important::

   Run ``ddev typo3 extension:setup`` after every ``composer require``. It
   activates the extension and applies its database schema changes — Composer
   itself does neither.

Starting from nothing
=====================

A minimal extension is a folder with a ``composer.json`` that names the
package, declares the extension key and points at its classes:

.. code-block:: bash

   mkdir -p packages/my-extension

.. code-block:: json
   :caption: packages/my-extension/composer.json

   {
       "name": "myvendor/my-extension",
       "type": "typo3-cms-extension",
       "description": "An extension developed against the Core clone",
       "require": {
           "typo3/cms-core": "@dev"
       },
       "autoload": {
           "psr-4": {
               "MyVendor\\MyExtension\\": "Classes/"
           }
       },
       "extra": {
           "typo3/cms": {
               "extension-key": "my_extension"
           }
       }
   }

Then require it as above. ``"typo3/cms-core": "@dev"`` resolves against the
symlinked system extension out of ``typo3-core/``, which is what keeps the
extension honest about the Core it is built for.

Why the symlink matters
=======================

Both path repositories are configured with symlinks, so
``vendor/myvendor/my-extension`` and ``vendor/typo3/cms-core`` are links, not
copies:

.. code-block:: json
   :caption: composer.json

   {
       "repositories": [
           { "type": "path", "url": "packages/*" },
           {
               "type": "path",
               "url": "typo3-core/typo3/sysext/*",
               "options": { "symlink": true }
           }
       ]
   }

An edit in ``packages/my-extension/Classes/`` or in
``typo3-core/typo3/sysext/core/Classes/`` is live on the next request. There is
no build step and no ``composer update`` to run after changing code — only
after changing dependencies.

Removing one
============

.. code-block:: bash

   ddev composer remove myvendor/my-extension
   ddev typo3 extension:setup

Deleting the folder without removing the requirement leaves Composer unable to
resolve it, and the next ``composer install`` — including the one inside
``ddev start`` — will fail.

Version control
===============

``.gitignore`` excludes ``packages/*`` except for ``.gitkeep``: your extensions
are not part of the scaffold's history. Track them the way that fits the work —
as their own repositories cloned into ``packages/``, as git submodules, or by
un-ignoring a specific folder:

.. code-block:: text
   :caption: .gitignore

   /packages/*
   !/packages/.gitkeep
   !/packages/my-extension

.. seealso::

   ``ddev tryout status`` lists every directory in ``packages/`` on its
   **Packages** line, which is the quickest way to see what the instance is
   carrying.
