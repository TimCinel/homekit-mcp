# HomeKit MCP Server Makefile

.PHONY: build test lint install-deps clean

# Build the project
build:
	xcodebuild -project HomeKitSync.xcodeproj -scheme HomeKitSync -configuration Debug -destination 'platform=macOS,variant=Mac Catalyst' -allowProvisioningUpdates

# Run tests (when test target is set up)
test:
	xcodebuild test -project HomeKitSync.xcodeproj -scheme HomeKitSync -destination 'platform=macOS,variant=Mac Catalyst'

# Run CI-friendly tests (no dependencies, works anywhere)
test-ci:
	@echo "Running CI tests with Swift Package Manager..."
	swift test

# Install SwiftLint (requires Homebrew)
install-deps:
	@command -v brew >/dev/null 2>&1 || { echo "Homebrew is required. Install from https://brew.sh/"; exit 1; }
	brew install swiftlint

# Run SwiftLint
lint:
	@command -v swiftlint >/dev/null 2>&1 || { echo "SwiftLint not found. Run 'make install-deps' first."; exit 1; }
	swiftlint

# Fix SwiftLint issues automatically
lint-fix:
	@command -v swiftlint >/dev/null 2>&1 || { echo "SwiftLint not found. Run 'make install-deps' first."; exit 1; }
	swiftlint --fix

# Clean build artifacts
clean:
	xcodebuild clean -project HomeKitSync.xcodeproj -scheme HomeKitSync

# Run the built app
run:
	@echo "Looking for built app..."
	@APP_PATH=$$(find ~/Library/Developer/Xcode/DerivedData -name "HomeKitMCP.app" -path "*/Debug-maccatalyst/*" 2>/dev/null | head -1); \
	if [ -n "$$APP_PATH" ]; then \
		echo "Starting HomeKit MCP Server..."; \
		open -a "$$APP_PATH"; \
	else \
		echo "App not found. Run 'make build' first."; \
		exit 1; \
	fi

# Show help
help:
	@echo "Available commands:"
	@echo "  build        - Build the HomeKit MCP Server"
	@echo "  test         - Run unit tests (requires HomeKit/Mac Catalyst)"
	@echo "  test-ci      - Run CI-friendly tests (no dependencies)"
	@echo "  lint         - Run SwiftLint checks"
	@echo "  lint-fix     - Fix SwiftLint issues automatically"
	@echo "  install-deps - Install SwiftLint via Homebrew"
	@echo "  run          - Run the built app"
	@echo "  clean        - Clean build artifacts"
	@echo "  help         - Show this help message"