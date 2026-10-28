.PHONY: check hooks generate build test l10n uitest lint format run sample welcome debug model release publish

check: lint test build l10n uitest ## Everything CI runs; the pre-push hook calls this

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
	mkdir -p "$(MODELS_DIR)"
	rm -rf "$(MODELS_DIR)/$(MODEL).mlpackage" "$(MODELS_DIR)/$(MODEL).mlmodelc"
	cp -R tools/convert/out/$(MODEL).mlpackage tools/convert/out/$(MODEL).mlmodelc "$(MODELS_DIR)/"
	curl -fsSL https://huggingface.co/mistralai/Timestral-5M/resolve/main/LICENSE -o "$(MODELS_DIR)/Timestral-5M-LICENSE.txt"
