# review-man — build targets
#
#   make app          Build PR Review.app at build/PR Review.app
#                     (directly launchable: double-click or `open build/PR Review.app`).
#   make run          Build (if needed) and launch the app.
#   make demo         Build and launch the app in offline load-test demo mode
#                     (250 files / 40k changed lines by default; pass
#                     --demo-scale small|medium|large|xlarge or
#                     --demo-files N --demo-lines M to the app to resize).
#   make test         Run the SPM unit suite.
#   make bench        Run the large-diff release benchmark (file + line scale).
#   make smoke        Headless pipeline timing across the demo load scales.
#   make launcher     Build the `pr-review` desktop launcher executable.
#   make local-install Build the app and move it into ~/Applications,
#                      replacing any previously installed copy.
#   make clean        Remove build products.
#
# Variables:
#   CONFIG=release   Build a release configuration instead of debug.

CONFIG ?= debug
APP_NAME := PR Review.app
APP := build/$(APP_NAME)
LOCAL_APPS := $(HOME)/Applications

.PHONY: all app run demo swiftui appkit-surface test bench baseline smoke launcher local-install clean

all: app

# Build the app and place a directly-launchable copy at build/PR Review.app.
app:
	bash scripts/build-app $(CONFIG)
	@echo "Demo mode: open \"$(APP)\" --args --demo"

run: app
	open "$(APP)"

demo: app
	open "$(APP)" --args --demo

# Explicit SwiftUI fallback for comparison and recovery testing.
swiftui: app
	open -n "$(APP)" --args --demo --swiftui-diff

# AppKit renderer comparison target using one 50k-line file.
appkit-surface: app
	open -n "$(APP)" --args --demo --demo-files 1 --demo-lines 50000 --appkit-diff

test:
	swift test

# Load-test benchmark: parse/row-build/highlight timing at monorepo scale.
# Override the shape with --fixture/--files, or run the binary directly.
bench:
	swift build -c release --product PRReviewBench
	.build/release/PRReviewBench --fixture 50000 --files 250 --runs 3

# Phase 1 baseline across the three planned line-count tiers. Reports are
# written under build/perf so they can be compared after renderer changes.
baseline:
	swift build -c release --product PRReviewBench
	mkdir -p build/perf
	@for spec in "10000 50" "50000 250" "100000 500"; do \
		set -- $$spec; \
		lines=$$1; files=$$2; \
		.build/release/PRReviewBench --fixture $$lines --files $$files --runs 3 \
			--format json --json-out build/perf/baseline-$$lines-$$files.json \
			> build/perf/baseline-$$lines-$$files.txt; \
		done

# Headless demo-scale timing without opening a window (debug build).
smoke:
	swift build --product PRReviewSpike
	.build/debug/PRReviewSpike --smoke

launcher:
	swift build -c release
	@echo "Desktop launcher built: .build/release/pr-review (try --help)"

# Remove any previously installed copy, build, then move the app into
# ~/Applications.
local-install: app
	rm -rf "$(LOCAL_APPS)/$(APP_NAME)"
	mkdir -p "$(LOCAL_APPS)"
	mv "$(APP)" "$(LOCAL_APPS)/$(APP_NAME)"
	@echo ""
	@echo "Installed: $(LOCAL_APPS)/$(APP_NAME)"
	@echo "Launch:    open \"$(LOCAL_APPS)/$(APP_NAME)\""

clean:
	rm -rf build
	swift package clean
