.PHONY: generate build test run clean localization site

generate:
	mise run generate

# Build the Debug app — a separate app ("SwiftyCrow Dev", bundle id
# dev.PangMo5.SwiftyCrow.debug), Apple Development-signed, so
# its Screen Recording (TCC) grant never collides with an installed release and
# survives rebuilds.
build:
	mise run build

test:
	mise run test

# Build the Debug app and launch it — the dev inner loop. `killall` clears any
# running SwiftyCrow (release + dev share the process name), so you don't end up
# with two confusingly identical menu-bar items.
run: build
	-killall SwiftyCrow 2>/dev/null
	open DerivedData/Build/Products/Debug/SwiftyCrow.app

clean:
	mise exec -- swift package clean
	rm -rf DerivedData

# English sources and all locale outputs must agree before packaging.
localization:
	mise exec -- swift run --package-path Tools swiftycrow-tools check

site: localization
	mise exec -- swift run --package-path Tools swiftycrow-tools site --output DerivedData/Site
