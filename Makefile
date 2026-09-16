EMACS ?= emacs
VERSION = 0.1.0
PACKAGE = strudel-$(VERSION)
SOURCES = strudel.el strudel-server.el ob-strudel.el

.PHONY: check test package test-package
check:
	$(EMACS) -Q --batch -L . --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile $(SOURCES)

test:
	$(EMACS) -Q --batch -L . -l test/strudel-tests.el -f ert-run-tests-batch-and-exit

package:
	mkdir -p dist
	@set -eu; staging=$$(mktemp -d); trap 'rm -rf "$$staging"' 0; \
	mkdir "$$staging/$(PACKAGE)"; \
	cp $(SOURCES) strudel-pkg.el LICENSE README.org THIRD-PARTY.org "$$staging/$(PACKAGE)/"; \
	cp -R web examples "$$staging/$(PACKAGE)/"; \
	tar -cf dist/$(PACKAGE).tar -C "$$staging" $(PACKAGE)

test-package: package
	$(EMACS) -Q --batch -l test/package-install.el dist/$(PACKAGE).tar
