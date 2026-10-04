#!/usr/bin/env bash
# Builds WiFi Rank into ./build, and optionally installs it.
#
#   ./build.sh                 build into ./build
#   ./build.sh install         build, then install WiFi Rank and the wifirank command
#   ./build.sh setup-signing   one-time: make the personal signing certificate
#
# With the personal certificate, every build keeps the same identity, so macOS
# remembers WiFi Rank's location permission across rebuilds. Without it the app
# is signed ad hoc and macOS asks for location again after each rebuild.
set -euo pipefail
cd "$(dirname "$0")"

BUILD=build
APP="$BUILD/WiFi Rank.app"
APP_DEST="$HOME/Applications/WiFi Rank.app"
CLI_DEST="$HOME/.local/bin/wifirank"
BUNDLE_ID=local.ammarsani.wifirank

# The certificate lives in its own keychain with a random password, so signing
# never stops to ask for the login password.
SIGN_DIR="$HOME/.config/wifirank"
SIGN_KEYCHAIN="$SIGN_DIR/signing.keychain-db"
SIGN_NAME="WiFi Rank Local Signing"

setup_signing() {
    if [ -f "$SIGN_KEYCHAIN" ]; then
        echo "signing certificate already set up"
        return
    fi
    mkdir -p "$SIGN_DIR"
    chmod 700 "$SIGN_DIR"
    local pass p12pass tmp
    pass=$(/usr/bin/openssl rand -hex 24)
    p12pass=$(/usr/bin/openssl rand -hex 12)
    printf '%s' "$pass" > "$SIGN_DIR/keychain-password"
    chmod 600 "$SIGN_DIR/keychain-password"
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN
    cat > "$tmp/req.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $SIGN_NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
    # macOS's own openssl: Keychain reliably imports what it produces.
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$tmp/req.cnf" \
        -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
    /usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -out "$tmp/id.p12" \
        -passout "pass:$p12pass" -name "$SIGN_NAME"
    security create-keychain -p "$pass" "$SIGN_KEYCHAIN"
    security set-keychain-settings "$SIGN_KEYCHAIN"
    security unlock-keychain -p "$pass" "$SIGN_KEYCHAIN"
    security import "$tmp/id.p12" -k "$SIGN_KEYCHAIN" -P "$p12pass" -T /usr/bin/codesign >/dev/null
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$pass" "$SIGN_KEYCHAIN" >/dev/null
    # codesign only finds identities in keychains on the search list; keep the existing ones.
    local list=()
    while IFS= read -r k; do
        k="${k#"${k%%[![:space:]]*}"}"
        list+=("${k//\"/}")
    done < <(security list-keychains -d user)
    security list-keychains -d user -s "${list[@]}" "$SIGN_KEYCHAIN"
    echo "signing certificate created in $SIGN_KEYCHAIN"
}

# Prints the certificate's fingerprint, or nothing if it isn't set up. The
# certificate is self-made and so "untrusted"; codesign accepts it by fingerprint.
signing_identity() {
    [ -f "$SIGN_KEYCHAIN" ] || return 0
    security unlock-keychain -p "$(cat "$SIGN_DIR/keychain-password")" "$SIGN_KEYCHAIN"
    security find-identity -p codesigning "$SIGN_KEYCHAIN" | awk -v n="\"$SIGN_NAME\"" '$0 ~ n { print $2; exit }'
}

build() {
    rm -rf "$APP"
    mkdir -p "$APP/Contents/MacOS"
    cp WiFiRank/Info.plist "$APP/Contents/Info.plist"
    swiftc -O -framework AppKit -framework CoreLocation -framework CoreWLAN -framework ServiceManagement \
        -framework UserNotifications -o "$APP/Contents/MacOS/wifirank" WiFiRank/*.swift
    # The icon is drawn in code; turn it into the bundle's AppIcon.icns.
    mkdir -p "$APP/Contents/Resources"
    "$APP/Contents/MacOS/wifirank" --render-iconset "$BUILD/AppIcon.iconset"
    iconutil -c icns -o "$APP/Contents/Resources/AppIcon.icns" "$BUILD/AppIcon.iconset"
    rm -rf "$BUILD/AppIcon.iconset"
    local id
    id=$(signing_identity)
    if [ -n "$id" ]; then
        codesign --force --sign "$id" --identifier "$BUNDLE_ID" "$APP" 2>/dev/null
    else
        codesign --force --sign - --identifier "$BUNDLE_ID" "$APP" 2>/dev/null
        echo "note: signed ad hoc; run ./build.sh setup-signing so location access survives rebuilds" >&2
    fi
    codesign --verify "$APP"
    echo "built $APP"
}

case "${1:-}" in
    "")
        build
        ;;
    install)
        build
        rm -rf "$APP_DEST"
        mkdir -p "$(dirname "$APP_DEST")" "$(dirname "$CLI_DEST")"
        cp -R "$APP" "$APP_DEST"
        install -m 755 cli/wifirank "$CLI_DEST"
        # Tell macOS to pick up the (possibly new) icon instead of a cached one.
        /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_DEST" || true
        echo "installed $APP_DEST and $CLI_DEST"
        if pgrep -fq "WiFi Rank.app/Contents/MacOS/wifirank"; then
            echo "WiFi Rank is running the old version: quit it and open it again." >&2
        fi
        ;;
    setup-signing)
        setup_signing
        ;;
    *)
        echo "usage: ./build.sh [install | setup-signing]" >&2
        exit 2
        ;;
esac
