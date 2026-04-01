.PHONY: init start stop restart composer

# Initialize DDEV with a project name derived from the current folder.
# This makes git worktrees and multiple clones work out of the box —
# each folder gets its own DDEV instance with a unique name.
init:
	@if [ ! -f .ddev/config.yaml ]; then \
		echo "name: $$(basename $$(pwd))" > .ddev/config.yaml; \
		echo "Created .ddev/config.yaml with project name: $$(basename $$(pwd))"; \
	else \
		echo ".ddev/config.yaml already exists (project: $$(grep '^name:' .ddev/config.yaml | awk '{print $$2}'))"; \
	fi
	ddev start

start:
	@if [ ! -f .ddev/config.yaml ]; then \
		$(MAKE) init; \
	else \
		ddev start; \
	fi

stop:
	ddev stop

restart:
	ddev restart

# Regenerate composer.json from the system extensions in typo3-core/.
# Runs inside the DDEV web container via PHP.
composer:
	ddev tryout composer
