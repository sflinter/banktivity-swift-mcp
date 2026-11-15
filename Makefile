DEVELOPER_DIR := /Applications/Xcode.app/Contents/Developer
XCODE_SDK := $(DEVELOPER_DIR)/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
XCODE_FRAMEWORKS := $(DEVELOPER_DIR)/Platforms/MacOSX.platform/Developer/Library/Frameworks
INSTALL_DIR := ~/.local/bin
# Local signing identity (self-signed cert in the login keychain). With a stable identity and
# identifier, macOS keeps Full Disk Access across rebuilds; ad-hoc signatures lose it every time.
CODESIGN_IDENTITY ?= Banktivity MCP Code Signing
CODESIGN_ID := $(shell security find-identity -p codesigning 2>/dev/null | grep -q "$(CODESIGN_IDENTITY)" && echo "$(CODESIGN_IDENTITY)" || echo -)
VERSION := $(shell grep 'public let version' Sources/BanktivityLib/Version.swift | sed 's/.*"\(.*\)"/\1/')

# Use Xcode toolchain for all builds to avoid cache invalidation
export DEVELOPER_DIR

.PHONY: build test release install clean help

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

build: ## Debug build
	swift build

release: ## Universal release build (arm64 + x86_64)
	swift build -c release --arch arm64 --arch x86_64

test: ## Run all tests
	SDKROOT=$(XCODE_SDK) \
	DYLD_FRAMEWORK_PATH=$(XCODE_FRAMEWORKS) \
	swift test \
	  -Xswiftc -F -Xswiftc $(XCODE_FRAMEWORKS) \
	  -Xlinker -rpath -Xlinker $(XCODE_FRAMEWORKS)

test-filter: ## Run filtered tests (usage: make test-filter FILTER=TurtleWriter)
	SDKROOT=$(XCODE_SDK) \
	DYLD_FRAMEWORK_PATH=$(XCODE_FRAMEWORKS) \
	swift test --filter '$(FILTER)' \
	  -Xswiftc -F -Xswiftc $(XCODE_FRAMEWORKS) \
	  -Xlinker -rpath -Xlinker $(XCODE_FRAMEWORKS)

install: release ## Build release and install to ~/.local/bin
	$(eval BIN := $(shell swift build -c release --arch arm64 --arch x86_64 --show-bin-path))
	cp $(BIN)/banktivity-cli $(INSTALL_DIR)/
	cp $(BIN)/banktivity-mcp $(INSTALL_DIR)/
	codesign -f -s "$(CODESIGN_ID)" --identifier com.flinter.banktivity-cli $(INSTALL_DIR)/banktivity-cli
	codesign -f -s "$(CODESIGN_ID)" --identifier com.flinter.banktivity-mcp $(INSTALL_DIR)/banktivity-mcp
	@echo "Installed v$(VERSION) to $(INSTALL_DIR) (signed with: $(CODESIGN_ID))"

package: release ## Build release and create tarball
	cd $(shell swift build -c release --arch arm64 --arch x86_64 --show-bin-path) && \
	codesign -fs - banktivity-cli && \
	codesign -fs - banktivity-mcp && \
	tar czf /tmp/banktivity-swift-mcp-v$(VERSION)-macos-universal.tar.gz banktivity-cli banktivity-mcp
	@echo "Package: /tmp/banktivity-swift-mcp-v$(VERSION)-macos-universal.tar.gz"
	@shasum -a 256 /tmp/banktivity-swift-mcp-v$(VERSION)-macos-universal.tar.gz

clean: ## Remove build artifacts
	rm -rf .build
