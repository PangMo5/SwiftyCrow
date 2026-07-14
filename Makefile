.PHONY: generate build run clean

generate:
	tuist install && tuist generate --no-open

# Build the Debug app — a separate app ("SwiftyCrow Dev", bundle id
# dev.PangMo5.SwiftyCrow.debug), Apple Development-signed via Project.swift, so
# its Screen Recording (TCC) grant never collides with an installed release and
# survives rebuilds.
build: generate
	tuist xcodebuild build -scheme SwiftyCrow -workspace SwiftyCrow.xcworkspace -configuration Debug -destination 'platform=macOS' -derivedDataPath DerivedData

# Build the Debug app and launch it — the dev inner loop. `killall` clears any
# running SwiftyCrow (release + dev share the process name), so you don't end up
# with two confusingly identical menu-bar items.
run: build
	-killall SwiftyCrow 2>/dev/null
	open DerivedData/Build/Products/Debug/SwiftyCrow.app

clean:
	tuist clean
	rm -rf Derived DerivedData
