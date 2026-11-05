SHELL := bash -o pipefail
.DEFAULT_GOAL := help
.DELETE_ON_ERROR:
.SUFFIXES:
MAKEFLAGS += --warn-undefined-variables

# Everything the build writes stays under the repo, so a sandboxed shell can run it.

# Xcode build output, including the .app bundle.
DERIVED_DATA ?= .build/DerivedData
# Where SwiftPM keeps checkouts for the Xcode build.
SOURCE_PACKAGES ?= .build/SourcePackages
# Where `swift build` and `swift test` keep the package build.
SWIFTPM_SCRATCH ?= .build/swiftpm
# Xcode build configuration.
CONFIGURATION ?= Debug
# Where `make fuzz` keeps its address-sanitized package build, apart from the ordinary one.
FUZZ_SCRATCH ?= .build/swiftpm-fuzz
# How many mutated inputs each fuzz test of `make fuzz` tries. `make test-package` runs the same
# fuzzers at a small count.
FUZZ_ITERATIONS ?= 5000
# Space-separated Swift paths, relative to the repo root, for fmt-select. Empty formats nothing.
FILES ?=

PACKAGE_DIR := Packages/UnitermKit
SWIFT_DIRS := App UITests $(PACKAGE_DIR)/Sources $(PACKAGE_DIR)/Tests $(PACKAGE_DIR)/Package.swift
XCODEBUILD := xcodebuild -project uniterm.xcodeproj -scheme uniterm \
	-configuration $(CONFIGURATION) \
	-derivedDataPath $(DERIVED_DATA) \
	-clonedSourcePackagesDirPath $(SOURCE_PACKAGES)

##@ Build

.PHONY: help
help: ## Show this help
	@awk 'BEGIN { FS = ":.*## " } \
		/^##@ / { printf "\n%s\n", substr($$0, 5) } \
		/^[a-zA-Z0-9_.\/-]+:([^=]|$$).*## / { printf "  %-24s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

.PHONY: ghostty
ghostty: ## Build the pinned GhosttyKit and link it into the package (needs Zig, only on a cold cache)
	scripts/build-ghostty.sh

.PHONY: build
build: check-ghosttykit-imports ghostty ## Build uniterm.app
	$(XCODEBUILD) build

# Runs the binary in the foreground, not through `open`, so the shell owns the process and sees its logs
# and any crash. The app uses the real settings and saves its layout to Application Support.
.PHONY: run
run: build ## Build, then run uniterm.app in the foreground
	$(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/uniterm.app/Contents/MacOS/uniterm

.PHONY: clean
clean: ## Remove Xcode and SwiftPM build output. Keeps the Ghostty cache
	rm -rf .build/DerivedData .build/SourcePackages .build/swiftpm

##@ Test

.PHONY: test-ci
test-ci: ## Verify CI change detection and result gating with temporary Git history
	bash scripts/test-ci.sh

.PHONY: test
test: test-ci test-package test-app ## Run CI gating, package tests, and app UI tests

.PHONY: test-package
test-package: ghostty ## Run the package tests with swift test
	cd $(PACKAGE_DIR) && swift test --scratch-path ../../$(SWIFTPM_SCRATCH)

.PHONY: fuzz
fuzz: ghostty ## Fuzz the table and GeoJSON readers under ASan. Slow, so make ci skips it
	cd $(PACKAGE_DIR) && UNITERM_FUZZ_ITERATIONS=$(FUZZ_ITERATIONS) \
		swift test --sanitize=address --scratch-path ../../$(FUZZ_SCRATCH) \
		--filter TableFuzzTests --filter GeoJSONFuzzTests

.PHONY: test-app
test-app: ghostty ## Run the UI tests with xcodebuild. They need a GUI session and Accessibility permission
	scripts/run-ui-tests.sh $(XCODEBUILD) -test-timeouts-enabled YES \
		-default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 120 test

.PHONY: ghostty-offline-check
ghostty-offline-check: ## Rebuild the pinned Ghostty with the network off, from the kept caches
	scripts/ghostty-offline-check.sh

.PHONY: swiftpm-offline-check
swiftpm-offline-check: ## Resolve and build the Swift packages with the network off, from the committed pins
	scripts/swiftpm-offline-check.sh

##@ Lint

.PHONY: fmt
fmt: ## Format Swift sources in place
	swift format --configuration .swift-format --in-place --recursive $(SWIFT_DIRS)

.PHONY: fmt-check
fmt-check: ## Verify Swift formatting without changing files
	swift format lint --strict --configuration .swift-format --recursive $(SWIFT_DIRS)

.PHONY: fmt-select
fmt-select: ## Format only the named files, e.g. make fmt-select FILES='App/AppDelegate.swift'
	$(if $(filter %.swift,$(FILES)),swift format --configuration .swift-format --in-place $(filter %.swift,$(FILES)))

.PHONY: lint
lint: fmt-check ## Lint Swift sources and check the scripts parse
	for script in scripts/*.sh; do bash -n "$$script" || exit 1; done

.PHONY: check
check: check-ghosttykit-imports ## Check the Swift language mode, the GhosttyKit boundary, and that the sandbox is off
	scripts/check-swift-mode.sh
	scripts/check-sandbox-off.sh

.PHONY: check-ghosttykit-imports
check-ghosttykit-imports: ## Fail when any module but TerminalSurface can reach GhosttyKit
	scripts/check-ghosttykit-imports.sh

.PHONY: licenses
licenses: ## Collect the license notices for Ghostty, its libraries, and the Swift packages into Licenses/
	scripts/collect-licenses.sh

.PHONY: ci
ci: fmt-check lint check test ghostty-offline-check swiftpm-offline-check ## Run what CI runs. Includes the 4-minute offline Ghostty rebuild

.PHONY: ci-changes
ci-changes:
	bash scripts/ci-changes.sh

.PHONY: ci-result
ci-result:
	bash scripts/ci-result.sh
