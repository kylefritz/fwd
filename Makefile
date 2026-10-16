# Command Line Tools ship Swift Testing outside the default search path.
# With full Xcode selected these flags are unnecessary and skipped.
CLT_FW := /Library/Developer/CommandLineTools/Library/Developer/Frameworks
CLT_LIB := /Library/Developer/CommandLineTools/Library/Developer/usr/lib
ifeq ($(shell xcode-select -p 2>/dev/null),/Library/Developer/CommandLineTools)
TEST_FLAGS := -Xswiftc -F$(CLT_FW) -Xlinker -F$(CLT_FW) \
	-Xlinker -rpath -Xlinker $(CLT_FW) -Xlinker -rpath -Xlinker $(CLT_LIB)
endif

VERSION ?= dev
PREFIX ?= /Applications

.PHONY: build test app install clean stats

build:
	swift build -c release

test:
	swift test $(TEST_FLAGS) $(TEST_ARGS)

app: build
	VERSION=$(VERSION) scripts/bundle.sh

install: app
	rm -rf "$(PREFIX)/fwd.app"
	cp -R build/fwd.app "$(PREFIX)/fwd.app"
	mkdir -p "$(HOME)/.local/bin"
	ln -sf "$(PREFIX)/fwd.app/Contents/Resources/bin/fwd" "$(HOME)/.local/bin/fwd"

stats:
	scripts/stats.sh

clean:
	rm -rf .build build
