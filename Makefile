# review-man — build targets
#
#   make app     Build PR Review.app and copy it to build/PR Review.app
#                (directly launchable: double-click or `open build/PR Review.app`).
#   make run     Build (if needed) and launch the app.
#   make demo    Build and launch the app in offline demo mode.
#   make test    Run the SPM unit suite.
#   make bench   Run the large-diff release benchmark.
#   make tui     Build the terminal UI executable (swift build -c release).
#   make install Install the terminal UI executable to /usr/local/bin.
#   make clean   Remove build products.
#
# Variables:
#   CONFIG=Release   Build a Release configuration instead of Debug.
#   UNIVERSAL=1      Build a universal (arm64 + x86_64) app.

CONFIG ?= Debug
PROJECT := PRReview.xcodeproj
SCHEME := PRReviewApp
DERIVED := build/DerivedData
APP_NAME := PR Review.app
APP := build/$(APP_NAME)

ifeq ($(UNIVERSAL),1)
ARCH_FLAGS := ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO
endif

.PHONY: all app run demo test bench tui install clean

all: app

# Build the app and place a directly-launchable copy at build/PR Review.app.
app:
	xcodegen generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) \
		-derivedDataPath $(DERIVED) $(ARCH_FLAGS) build
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

tui:
	swift build -c release
	@echo "Terminal UI built: .build/release/pr-review (try --help)"

install: tui
	cp .build/release/pr-review /usr/local/bin/

clean:
	rm -rf build
	swift package clean
