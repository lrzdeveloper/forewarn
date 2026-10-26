.PHONY: generate build test uitest lint format run graph

generate: ## Regenerate Forewarn.xcodeproj from project.yml
	xcodegen generate

build: generate
	xcodebuild -project Forewarn.xcodeproj -scheme Forewarn -configuration Debug -derivedDataPath build build $(XCODEBUILD_FLAGS)

test: ## Pure logic tests, no app host
	swift test --package-path ForewarnKit

uitest: generate ## End-to-end: launches the real app and drives the UI (XCUITest)
	xcodebuild -project Forewarn.xcodeproj -scheme Forewarn -derivedDataPath build test -only-testing:ForewarnUITests $(XCODEBUILD_FLAGS)

lint:
	swiftformat --lint .
	swiftlint --strict

format:
	swiftformat .
	swiftlint --fix

run: build
	open build/Build/Products/Debug/Forewarn.app

graph: ## Rebuild the graphify knowledge graph (AST only, no LLM)
	graphify update .
