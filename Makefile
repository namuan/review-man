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

.PHONY: all app run demo test bench smoke launcher local-install clean

all: app

# Build the app and place a directly-launchable copy at build/PR Review.app.
app:
	bash scripts/build-app $(CONFIG)
	@echo "Demo mode: open \"$(APP)\" --args --demo"

run: app
	open "$(APP)"

demo: app
	open "$(APP)" --args --demo

test:
	swift test

# Load-test benchmark: parse/row-build/highlight timing at monorepo scale.
# Override the shape with --fixture/--files, or run the binary directly.
bench:
	swift build -c release --product PRReviewBench
	.build/release/PRReviewBench --fixture 50000 --files 250 --runs 3

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
