PYTHON ?= python3
.DEFAULT_GOAL := help
.NOTPARALLEL:

.PHONY: help app run test signing-info signing-check notary-credentials release-check signed-app release verify-release cask publish update-cask

help:
	@printf '%s\n' \
	  'make app                 Local ad-hoc build (not for distribution)' \
	  'make run                 Build and open the local app' \
	  'make test                Swift and release-workflow tests' \
	  'make signing-info        Show the pinned certificate and available identities' \
	  'make signing-check       Verify the pinned Developer ID Application identity' \
	  'make notary-credentials  One-time interactive Keychain credential setup' \
	  'make release-check       Check signing and notarization credentials (no upload)' \
	  'make signed-app          Developer ID build, without notarization' \
	  'make release             Build, sign, notarize, staple, verify, ZIP and cask' \
	  'make verify-release      Re-check the final archive, ticket and signature' \
	  'make cask                Regenerate the cask from a verified release' \
	  'make publish             Upload the verified release to rioriost/homebrew-cask' \
	  'make update-cask         Copy the verified cask into the local rioriost/cask tap'

app:
	$(PYTHON) scripts/release.py app

run: app
	open "dist/Container Sweeper.app"

test:
	swift test
	$(PYTHON) -m unittest discover -s Tests/ReleaseTests -v

signing-info signing-check notary-credentials release-check signed-app release verify-release cask publish update-cask:
	$(PYTHON) scripts/release.py $@
