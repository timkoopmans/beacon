# NVBeacon build tasks. Run `just` to list recipes.

set quiet

default:
    just --list

# Compile the Swift package (debug)
build *args:
    swift build {{args}}

# Run the test suite
test *args:
    swift test {{args}}

# Build a debug test app bundle in dist/ (kills/cleans older test bundles)
dev:
    scripts/dev_build.sh

# Build the test app bundle and launch it
run:
    OPEN_APP=1 scripts/build_test_app.sh

# Run tests, then build the test app bundle
dev-test:
    scripts/dev_test.sh

# Build a release .app + DMG in dist/ (ad-hoc signed unless CODESIGN_IDENTITY is set)
package version="0.5.0":
    APP_NAME=Beacon VERSION={{version}} scripts/package_app.sh

# Build a release .app only, no DMG
app version="0.5.0":
    APP_NAME=Beacon VERSION={{version}} SKIP_DMG=1 BUILD_CONFIGURATION=release scripts/package_app.sh

# Build a release .app and install it to ~/Applications, replacing any running copy
deploy version="0.5.0": (app version)
    pkill -f 'Beacon.*\.app/Contents/MacOS/' || true
    scripts/migrate_test_config.sh
    rm -rf ~/Applications/Beacon.app ~/Applications/NVBeacon.app
    cp -R dist/Beacon.app ~/Applications/Beacon.app
    open ~/Applications/Beacon.app
    echo "Deployed Beacon {{version}} to ~/Applications"

# Copy settings from the newest test-bundle domain into the main app's domain
migrate-config:
    scripts/migrate_test_config.sh

# Remove build artifacts and app bundles
clean:
    rm -rf .build dist
