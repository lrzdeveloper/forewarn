.PHONY: check hooks generate build test l10n uitest lint format run sample welcome debug model release publish

check: lint test build l10n uitest ## Everything CI runs; the pre-push hook calls this

# build, l10n and uitest share build/ and its Xcode build database: never run them side by side, even with make -j.
.NOTPARALLEL:

hooks: ## Install the pre-push hook (git hooks are not versioned)
	printf '#!/bin/sh\nexec make check\n' > .git/hooks/pre-push
	chmod +x .git/hooks/pre-push

generate: ## Regenerate Forewarn.xcodeproj from project.yml
	xcodegen generate

build: generate
	xcodebuild -project Forewarn.xcodeproj -scheme Forewarn -configuration Debug -derivedDataPath build build $(XCODEBUILD_FLAGS)

test: ## Pure logic tests, no app host
	swift test --package-path ForewarnKit

l10n: generate ## Every string the app shows is translated into every language it offers
	rm -rf build/l10n-check
	xcodebuild -exportLocalizations -project Forewarn.xcodeproj -localizationPath build/l10n-check -exportLanguage it -quiet
	python3 tools/l10n-check.py "build/l10n-check/it.xcloc/Localized Contents/it.xliff"

uitest: generate ## End-to-end: launches the real app and drives the UI (XCUITest); quits a running Forewarn first
	-pkill -x Forewarn
	xcodebuild -project Forewarn.xcodeproj -scheme Forewarn -derivedDataPath build test -only-testing:ForewarnUITests $(XCODEBUILD_FLAGS)

lint:
	swiftformat --lint .
	swiftlint --strict

format:
	swiftformat .
	swiftlint --fix

run: build
	open build/Build/Products/Debug/Forewarn.app

sample: build ## Launch with sample data: make sample STATE=risky|fine|charging|plugged|learning|shortfall
	open build/Build/Products/Debug/Forewarn.app --args -FWSample $(or $(STATE),risky)

welcome: build ## Launch as on first run, with the welcome window
	open build/Build/Products/Debug/Forewarn.app --args -onboarded NO

debug: build ## Launch with the hidden debug window: raw series and event log
	open build/Build/Products/Debug/Forewarn.app --args -FWDebug YES

release: ## Developer ID build in a notarized DMG, and its Homebrew cask, in build/release (tools/release.sh)
	tools/release.sh

publish: ## release, then the GitHub release and the cask in Casks/ (this repository is its own tap)
	tools/release.sh publish

MODEL := Timestral-5M-core-32768-fp32
MODELS_DIR := $(HOME)/Library/Application Support/Forewarn/Models

model: ## Convert the production Timestral model; install it with a compiled copy (weights not committed)
	cd tools/convert && uv run production.py model
	rm -rf tools/convert/out/$(MODEL).mlmodelc
	xcrun coremlcompiler compile tools/convert/out/$(MODEL).mlpackage tools/convert/out
	@# Staged beside the installed copy, checked, then swapped in item by item: a failed copy or download leaves the
	@# installed model as it was, never a partial one where the app loads it. One install at a time.
	mkdir -p "$(MODELS_DIR)"
	set -e; dir="$(MODELS_DIR)"; stage="$$dir/.staging.$$$$"; \
	mkdir "$$dir/.install.lock" || { echo "error: another make model is running (remove $$dir/.install.lock if none is)"; exit 1; }; \
	trap 'rm -rf "$$stage"; rmdir "$$dir/.install.lock"' EXIT; \
	mkdir "$$stage"; \
	cp -R tools/convert/out/$(MODEL).mlpackage tools/convert/out/$(MODEL).mlmodelc "$$stage/"; \
	curl -fsSL https://huggingface.co/mistralai/Timestral-5M/resolve/main/LICENSE -o "$$stage/Timestral-5M-LICENSE.txt"; \
	test -f "$$stage/$(MODEL).mlmodelc/coremldata.bin" && test -s "$$stage/Timestral-5M-LICENSE.txt"; \
	for item in $(MODEL).mlpackage $(MODEL).mlmodelc Timestral-5M-LICENSE.txt; do \
		rm -rf "$$stage/previous"; \
		if [ -e "$$dir/$$item" ]; then mv "$$dir/$$item" "$$stage/previous"; fi; \
		mv "$$stage/$$item" "$$dir/$$item" || { [ ! -e "$$stage/previous" ] || mv "$$stage/previous" "$$dir/$$item"; exit 1; }; \
	done
