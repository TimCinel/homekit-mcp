.PHONY: build build-signed test test-ci cli help

# Build-only by default: no app launch, provisioning, or HomeKit permission request.
build:
	xcodebuild -project HomeKitSync.xcodeproj -scheme HomeKitSync -configuration Debug -destination 'platform=macOS,variant=Mac Catalyst' CODE_SIGNING_ALLOWED=NO build

# Owner selects their development team in Xcode before this explicit signing step.
build-signed:
	xcodebuild -project HomeKitSync.xcodeproj -scheme HomeKitSync -configuration Debug -destination 'platform=macOS,variant=Mac Catalyst' build

test test-ci:
	swift test
	python3 -m unittest discover -s tests -v

cli:
	python3 scripts/homekitctl.py --help

help:
	@echo 'build: unsigned compile only; build-signed: normal owner-configured signing'
	@echo 'test: production core/transport and relay tests without HomeKit'
	@echo 'See README.md for signed sandbox validation gates before activation.'
