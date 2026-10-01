#!/usr/bin/env bash
# Builds WiFi Rank and its scan helper into ./build, and optionally installs them.
#
#   ./build.sh                  build both apps into ./build
#   ./build.sh install          build, then install WiFi Rank and the wifirank command
#   ./build.sh install-helper   the above, and also replace the installed scan helper
#
# Replacing the helper is a separate step because macOS then asks for location
# access again: the apps are self-signed, so every rebuild looks like a new app.
set -euo pipefail
cd "$(dirname "$0")"

BUILD=build
APP_DEST="$HOME/Applications/WiFi Rank.app"
HELPER_DEST="$HOME/.local/libexec/WiFiScanHelper.app"
CLI_DEST="$HOME/.local/bin/wifirank"

# build_app <bundle name> <executable> <bundle id> <swift source> <frameworks...>
build_app() {
    local name="$1" exe="$2" id="$3" src="$4"
    shift 4
    local app="$BUILD/$name.app" fw=()
    for f in "$@"; do fw+=(-framework "$f"); done
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS"
    cp "$(dirname "$src")/Info.plist" "$app/Contents/Info.plist"
    swiftc -O "${fw[@]}" -o "$app/Contents/MacOS/$exe" "$src"
    codesign --force --sign - --identifier "$id" "$app" 2>/dev/null
    codesign --verify "$app"
    echo "built $app"
}

build_app "WiFiScanHelper" wifiscanhelper local.ammarsani.wifiscanhelper \
    WiFiScanHelper/WiFiScanHelper.swift CoreWLAN
build_app "WiFi Rank" wifirank local.ammarsani.wifirank \
    WiFiRank/WiFiRank.swift AppKit ServiceManagement

case "${1:-}" in
    install|install-helper)
        if pgrep -fq "WiFi Rank.app/Contents/MacOS/wifirank"; then
            echo "WiFi Rank is running. Quit it first (right-click its icon → Quit WiFi Rank)." >&2
            exit 1
        fi
        rm -rf "$APP_DEST"
        cp -R "$BUILD/WiFi Rank.app" "$APP_DEST"
        install -m 755 cli/wifirank "$CLI_DEST"
        echo "installed $APP_DEST and $CLI_DEST"
        if [ "$1" = install-helper ]; then
            rm -rf "$HELPER_DEST"
            mkdir -p "$(dirname "$HELPER_DEST")"
            cp -R "$BUILD/WiFiScanHelper.app" "$HELPER_DEST"
            echo "installed $HELPER_DEST — macOS will ask for location access on the next scan"
        fi
        ;;
    "") ;;
    *) echo "usage: ./build.sh [install | install-helper]" >&2; exit 2 ;;
esac
