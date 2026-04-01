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

# (Re)generate composer.json from the system extensions present in typo3-core/.
# Run this after switching branches (e.g. ddev tryout checkout 13.4) or any
# time the set of system extensions has changed.
#
# How it works:
#   1. Scans typo3-core/typo3/sysext/*/composer.json for package names
#   2. Writes a new composer.json with those packages required at @dev
#   3. Preserves non-sysext requires (custom packages) and all other fields
#
# If typo3-core/ does not exist yet, run "make init" first.
composer:
	@if [ ! -d typo3-core/typo3/sysext ]; then \
		echo "Error: typo3-core/ not found. Run 'make init' first."; \
		exit 1; \
	fi
	@echo "Scanning typo3-core/typo3/sysext/ for available packages..."
	@python3 -c " \
import json, glob, os; \
project = 'composer.json'; \
sysext_pattern = 'typo3-core/typo3/sysext/*/composer.json'; \
data = json.load(open(project)); \
sysext_names = set(); \
[sysext_names.add(json.load(open(p)).get('name', '')) for p in sorted(glob.glob(sysext_pattern))]; \
sysext_names.discard(''); \
old = data.get('require', {}); \
keep = {k: v for k, v in old.items() if not k.startswith('typo3/cms-')}; \
keep.update({name: '@dev' for name in sysext_names}); \
data['require'] = dict(sorted(keep.items())); \
f = open(project, 'w'); \
json.dump(data, f, indent=2); \
f.write('\n'); \
f.close(); \
print(f'composer.json updated — {len(sysext_names)} system extensions'); \
"
	@echo "Run 'ddev composer install' to apply changes."
