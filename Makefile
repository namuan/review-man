# review-man — build targets
#
#   make app     Build PR Review.app and copy it to build/PR Review.app
#                (directly launchable: double-click or `open build/PR Review.app`).
#   make run     Build (if needed) and launch the app.
#   make demo    Build and launch the app in offline demo mode.
#   make test    Run the SPM unit suite.
#   make bench   Run the large-diff release benchmark.
#   make launcher Build the `pr-review` desktop launcher executable.
#   make clean   Remove build products.
#
# Variables:
#   CONFIG=Release   Build a Release configuration instead of Debug.

CONFIG ?= Debug
PROJECT := PRReview.xcodeproj
SCHEME := PRReviewApp
DERIVED := build/DerivedData
APP_NAME := PR Review.app
APP := build/$(APP_NAME)

.PHONY: all app run demo test bench launcher clean

all: app

# Build the app and place a directly-launchable copy at build/PR Review.app.
app:
	xcodegen generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) \
		-derivedDataPath $(DERIVED) build
	rm -rf "$(APP)"
	ditto "$(DERIVED)/Build/Products/$(CONFIG)/$(APP_NAME)" "$(APP)"
	@echo ""
	@echo "Built: $(APP)"
	@echo "Launch directly:  open \"$(APP)\""
	@echo "Demo mode:        open \"$(APP)\" --args --demo"

run: app
	open "$(APP)"

demo: app
	open "$(APP)" --args --demo

test:
	swift test

bench:
	swift build -c release
	.build/release/PRReviewBench --fixture 50000 --runs 3

launcher:
	swift build -c release
	@echo "Desktop launcher built: .build/release/pr-review (try --help)"

clean:
	rm -rf build
	swift package clean
