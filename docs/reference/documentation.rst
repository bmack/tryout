:navigation-title: The documentation

======================
Building these pages
======================

This manual is part of the repository. It lives in ``docs/`` as
reStructuredText and is rendered with the `TYPO3 Soul guides theme
<https://typo3.github.io/soul-design-system/guides-theme/>`__, which brings the
renderer, the syntax highlighter and the finished frontend with it. There is no
documentation dependency in the project's own ``composer.json``.

Rendering with DDEV
===================

.. code-block:: bash

   ddev docs

That is the whole thing. On first use the renderer is installed into
``.renderer/`` — a throwaway Composer project — using the PHP, Composer and
Node inside the web container. Nothing is required on your host but DDEV.

``ddev start`` runs the same step last, so the manual is already there the
first time you open the instance and the URL is printed beside the backend one.
The step never fails a start, and ``TRYOUT_DOCS=0`` in
``.ddev/config.local.yaml`` turns it off.

The site is rendered into ``.site/`` and the web server maps ``/_docs/`` onto
it, so it is reachable without a second port:

.. code-block:: text

   https://<project-name>.ddev.site/_docs/

Nothing is written into ``public/``. That docroot belongs to TYPO3, and a
generated directory inside it is something Composer and ``ddev tryout delete``
both have an opinion about. The mapping is one Apache directive in
``.ddev/apache/docs.conf``:

.. code-block:: apache
   :caption: .ddev/apache/docs.conf

   Alias "/_docs" "/var/www/html/.site"

   <Directory "/var/www/html/.site">
       Require all granted
       AllowOverride None
       DirectoryIndex index.html
   </Directory>

DDEV copies every ``.conf`` in ``.ddev/apache/`` into the container's
``sites-enabled/``, so this file sits beside the generated ``apache-site.conf``
without modifying it — and survives DDEV regenerating that file. It is outside
any ``<VirtualHost>`` on purpose: a mapping at server scope is inherited by
both the ``:80`` and the ``:443`` host.

.. note::

   The leading underscore keeps the path out of TYPO3's way. An alias mapped at
   ``/docs`` would silently shadow a page slug named ``docs``, which is an
   ordinary thing for a site to have — and a bug nobody would think to look for
   in an Apache file.

Re-run ``ddev docs`` after editing a page and reload. The other subcommands:

.. list-table::
   :header-rows: 1
   :widths: 25 75

   * - Command
     - Effect
   * - ``ddev docs``
     - Render ``docs/`` into ``.site/``. Same as ``ddev docs build``.
   * - ``ddev docs update``
     - Pull a newer release of the theme into ``.renderer/``.
   * - ``ddev docs clean``
     - Remove the rendered site and the renderer.

Both ``.renderer/`` and ``.site/`` are gitignored, and both are named with a
leading dot on purpose: they are generated, and nothing in either is edited by
hand.

Rendering without DDEV
======================

The theme needs PHP 8.2 or newer, Composer and Node — nothing else. If your
host has them, the documents render without starting a container at all:

.. code-block:: bash

   mkdir -p .renderer
   composer --working-dir=.renderer init --no-interaction \
       --name=typo3/tryout-documentation \
       --author="Benni Mack <benni@typo3.org>"
   composer --working-dir=.renderer require typo3/soul-guides-theme:dev-main

   .renderer/vendor/bin/guides docs --output=.site -c docs --fail-on-error
   node .renderer/vendor/typo3/soul-guides-theme/resources/dist/soul-finish.js .site
   php -S localhost:8000 -t .site

Then open ``http://localhost:8000``.

Both steps matter. ``guides`` writes the documents; ``soul-finish.js`` is what
turns them into a site — it copies the frontend drop-in, pre-renders every
custom element so the pages work with JavaScript disabled, and writes the
search index.

.. warning::

   ``--fail-on-error`` is not enough on its own. It stops a render that cannot
   finish, but a ``:doc:`` reference that resolves to nothing is only a
   **warning** and the command still exits 0 — a dead link that publishes
   itself quietly.

   ``ddev docs`` and the CI workflow therefore read the render output and fail
   on any ``app.WARNING`` line. If you render by hand, check the output
   yourself:

   .. code-block:: bash

      .renderer/vendor/bin/guides docs --output=.site -c docs --fail-on-error 2>&1 \
        | tee render.log
      ! grep -q 'app\.WARNING' render.log

What is in ``docs/``
====================

.. code-block:: text

   docs/
   ├── guides.xml            the project, the bar, the navigation, the footer
   ├── index.rst             the landing page (:layout: marketing)
   ├── _images/              the signet, the favicons, the hero
   ├── getting-started/      installing it and putting your code in it
   ├── core/                 the TYPO3 Core checkout
   ├── reference/            commands, configuration, architecture, this page
   └── troubleshooting.rst   a section of one page, linked from the bar

``guides.xml`` is the only settings file. It registers the theme — the
``<extension>`` element is required even when it carries no configuration —
and defines what the header bar and the footer show. Everything else about the
site's shape comes from the documents themselves.

Two page shapes
===============

**The landing page** writes ``:layout: marketing`` at the top and is a run of
full-bleed bands with no sidebar. **Every other page** writes no such field and
gets the manual shape: a column beside a navigation rail, with the page's own
sections listed alongside it.

Both carry the same bar and footer, and both are built from the same toctree.
The hidden tree in ``docs/index.rst`` is not a formality — the rail, the
breadcrumbs and the footer columns are all derived from it, so a page that is
not in a toctree is a page nothing links to.

.. code-block:: text
   :caption: The top of a manual page

   :navigation-title: Commands

   ========
   Commands
   ========

``:navigation-title:`` is the short name used in navigation; it defaults to the
page title. Use it when the title is a sentence and the rail needs a word.

Writing conventions
===================

- One page per task in ``getting-started/`` and ``core/``, one page per lookup
  surface in ``reference/``. If a page starts explaining *and* listing, it is
  two pages.
- A section is a directory with an ``index.rst`` that carries the toctree and a
  grid of cards. A section of one page is a page at the top level instead —
  ``troubleshooting.rst`` is linked straight from the bar rather than wrapped
  in a directory that would hold nothing else.
- **A card gets an icon only where the glyph distinguishes something.** On the
  landing page the three audiences do; a card that already carries a ``:tag:``
  or a ``:label:`` naming the same thing does not, and a grid where every entry
  wears one has spent the glyph on decoration.
- Cross-reference with ``:doc:`` rather than a URL, and write the path from the
  root: ``:doc:`/reference/configuration```. A relative reference resolves too,
  but it stops resolving the day the page moves to another section — and the
  render only warns about that.
- Give every code block a language. A fenced block with no language kills the
  render outright in Markdown, and in reStructuredText it falls back to
  ``text``, which colours nothing.
- Prefer ``.. list-table::`` to a grid table for anything with prose in it —
  it survives editing.
- The admonitions this theme tints are ``warning``, ``caution``,
  ``attention``, ``danger`` and ``error``. ``note``, ``important`` and
  ``seealso`` stay quiet. Use the loud ones only where something is genuinely
  lost.

The theme's `directives
<https://typo3.github.io/soul-design-system/guides-theme/directives.html>`__ —
cards, bands, grids, stats, accordions — are for the landing page. A manual
page is prose, code and tables, and stays that way.

Publishing
==========

``.github/workflows/publish.yml`` renders on every push and pull request, and
deploys to GitHub Pages from ``main`` only. It builds the renderer in a
temporary directory on the runner, so the repository stays free of a
documentation manifest, and it writes a ``.nojekyll`` marker so the
underscore-prefixed paths the theme emits — ``_search.json``, ``_images/`` —
survive.

A pull request therefore renders but does not publish, and a render that fails
fails the build.
