#!/bin/bash
# Builds dist/DACBar.app.
#
# Nothing privileged is embedded: the app talks to the dongle through the HID
# interface macOS already drives, so no daemon, no root, and no particular
# signing identity is required for it to work.
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="dist/DACBar.app"
MIN_MACOS="14.0"
DEFAULT_BUILD_NUMBER=$(git rev-list --count HEAD 2>/dev/null || echo 1)
BUILD_NUMBER="${DACBAR_BUILD_NUMBER:-$DEFAULT_BUILD_NUMBER}"

case "$CONFIG" in
    debug|release) ;;
    *) echo "构建配置只能是 debug 或 release：${CONFIG}" >&2; exit 1 ;;
esac

case "$CONFIG" in
    debug)   XCODE_CONFIG="Debug" ;;
    release) XCODE_CONFIG="Distribution" ;;
esac

# Resolve the stable identity from Xcode. Identity.xcconfig is intentionally the
# only place that may change it; an environment override could silently split
# preferences, signing, and Sparkle update continuity between build paths.
EXPECTED_APP_ID=$(./scripts/read-build-setting.sh \
    PRODUCT_BUNDLE_IDENTIFIER "$XCODE_CONFIG")
SPARKLE_FEED_URL="${DACBAR_SPARKLE_FEED_URL:-}"
SPARKLE_PUBLIC_KEY="${DACBAR_SPARKLE_PUBLIC_KEY:-}"

[[ "$EXPECTED_APP_ID" =~ ^[A-Za-z0-9][A-Za-z0-9.-]+$ ]] || {
    echo "无效的 Bundle ID：${EXPECTED_APP_ID}" >&2; exit 1;
}
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || {
    echo "构建号必须是正整数：${BUILD_NUMBER}" >&2; exit 1;
}
if [ -n "$SPARKLE_FEED_URL" ] || [ -n "$SPARKLE_PUBLIC_KEY" ]; then
    if [ -z "$SPARKLE_FEED_URL" ] || [[ "$SPARKLE_FEED_URL" != https://* ]]; then
        echo "Sparkle 更新必须提供 HTTPS DACBAR_SPARKLE_FEED_URL。" >&2
        exit 1
    fi
    [[ "$SPARKLE_PUBLIC_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]] || {
        echo "DACBAR_SPARKLE_PUBLIC_KEY 必须是 32 字节 Ed25519 公钥的 Base64。" >&2
        exit 1
    }
fi

# Signing identity. Local builds are deliberately ad-hoc; distribution must name
# its identity explicitly so a multi-team keychain can never select the wrong one.
#
#   Developer ID Application  — works on other machines once notarised
#   Apple Development         — local use only; Gatekeeper blocks it elsewhere
#   ad-hoc                    — fine locally; other Macs need notarisation
#
# Set DACBAR_SIGN_ID to the full certificate name for a signed build.
SIGN_ID="${DACBAR_SIGN_ID:--}"
SIGN_KEYCHAIN="${DACBAR_SIGN_KEYCHAIN:-}"
NOTARY_KEYCHAIN="${DACBAR_NOTARY_KEYCHAIN:-}"

if [ -n "$SIGN_KEYCHAIN" ]; then
    [ -f "$SIGN_KEYCHAIN" ] || {
        echo "签名钥匙串不存在：${SIGN_KEYCHAIN}" >&2; exit 1;
    }
fi

if [ -n "$NOTARY_KEYCHAIN" ] && [ ! -f "$NOTARY_KEYCHAIN" ]; then
    echo "公证钥匙串不存在：${NOTARY_KEYCHAIN}" >&2
    exit 1
fi

case "$SIGN_ID" in
    "Developer ID Application"*) SIGN_KIND="可分发（公证后）" ;;
    "Apple Development"*)        SIGN_KIND="仅本机" ;;
    *)                           SIGN_KIND="ad-hoc（仅本机）" ;;
esac

echo "==> 签名身份：${SIGN_ID}"
echo "    类型：${SIGN_KIND}"

# Checked before building rather than after signing: notarisation only accepts
# Developer ID, and finding that out at the end wastes a whole build.
if [ -n "${DACBAR_NOTARY_PROFILE:-}" ]; then
    case "$SIGN_ID" in
        "Developer ID Application"*) ;;
        *)
            echo "公证需要 Developer ID Application 证书，当前是：${SIGN_ID}" >&2
            exit 1
            ;;
    esac
    [ -n "$SPARKLE_FEED_URL" ] || {
        echo "公证分发必须配置 DACBAR_SPARKLE_FEED_URL。" >&2; exit 1;
    }
    [ -n "$SPARKLE_PUBLIC_KEY" ] || {
        echo "公证分发必须配置 DACBAR_SPARKLE_PUBLIC_KEY。" >&2; exit 1;
    }
fi

DERIVED_DATA=".build/xcode"
BUILT_APP="$DERIVED_DATA/Build/Products/$XCODE_CONFIG/DACBar.app"

echo "==> xcodebuild ${XCODE_CONFIG} (Universal 2: arm64 + x86_64)"
# Xcode's incremental build does not remove resource bundles whose package
# product was renamed. Recreate the app wrapper so a release can never retain
# obsolete modules from an earlier build graph.
rm -rf "$BUILT_APP"
xcodebuild -project DACBar.xcodeproj -scheme DACBar \
    -quiet \
    -disableAutomaticPackageResolution \
    -configuration "$XCODE_CONFIG" \
    -derivedDataPath "$DERIVED_DATA" \
    -destination "generic/platform=macOS" \
    ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
    ENABLE_DEBUG_DYLIB=NO \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    MACOSX_DEPLOYMENT_TARGET="$MIN_MACOS" \
    DACBAR_SPARKLE_FEED_URL="$SPARKLE_FEED_URL" \
    DACBAR_SPARKLE_PUBLIC_KEY="$SPARKLE_PUBLIC_KEY" \
    build

[ -d "$BUILT_APP" ] || {
    echo "Xcode 未生成 App：$BUILT_APP" >&2
    exit 1
}

echo "==> staging ${APP}"
rm -rf "$APP"
mkdir -p "$(dirname "$APP")"
ditto "$BUILT_APP" "$APP"

# Xcode's resolved MARKETING_VERSION is authoritative. Read the processed app
# instead of parsing or duplicating the xcconfig value in shell code.
VERSION=$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")
EMBEDDED_BUILD_NUMBER=$(plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist")
APP_ID=$(plutil -extract CFBundleIdentifier raw "$APP/Contents/Info.plist")
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    echo "Xcode 生成了无效的版本号：${VERSION}" >&2; exit 1;
}
[ "$EMBEDDED_BUILD_NUMBER" = "$BUILD_NUMBER" ] || {
    echo "Xcode 生成的构建号与请求值不一致：${EMBEDDED_BUILD_NUMBER} != ${BUILD_NUMBER}" >&2
    exit 1
}
[ "$APP_ID" = "$EXPECTED_APP_ID" ] || {
    echo "Xcode 生成的 Bundle ID 与身份配置不一致：${APP_ID} != ${EXPECTED_APP_ID}" >&2
    exit 1
}

SPARKLE_DEST="$APP/Contents/Frameworks/Sparkle.framework"
SPARKLE_VERSION="$SPARKLE_DEST/Versions/B"

echo "==> pruning unused Sparkle sandbox services"
# DACBar currently ships as a non-sandboxed Developer ID app. Sparkle's
# Installer and Downloader XPC services are only enabled for the sandboxed
# integration, so retaining them would add dormant executable code and extra
# signing/notarization nodes. Remove both the versioned directory and the
# framework-level symlink before establishing the final code signatures.
rm -rf "$SPARKLE_VERSION/XPCServices"
rm -f "$SPARKLE_DEST/XPCServices"

echo "==> codesign (identity: ${SIGN_ID})"
# A Developer ID signature needs a secure timestamp to count as a distribution
# signature, and it is a precondition for notarisation. Ad-hoc can't be
# timestamped at all.
if [ "$SIGN_ID" = "-" ]; then
    ARGS=(--force --options runtime --timestamp=none)
else
    ARGS=(--force --options runtime --timestamp)
fi
if [ -n "$SIGN_KEYCHAIN" ]; then
    ARGS+=(--keychain "$SIGN_KEYCHAIN")
fi
APP_SIGN_ARGS=("${ARGS[@]}")
if [ "$SIGN_ID" = "-" ]; then
    APP_SIGN_ARGS+=(--entitlements DACBar/Configuration/DACBar.Local.entitlements)
fi

# Sparkle's retained helpers are nested code. Sign from the innermost helpers
# outward; --deep is validation-only and must not be used to establish them.
codesign "${ARGS[@]}" --sign "$SIGN_ID" "$SPARKLE_VERSION/Autoupdate"
codesign "${ARGS[@]}" --sign "$SIGN_ID" "$SPARKLE_VERSION/Updater.app"
codesign "${ARGS[@]}" --sign "$SIGN_ID" "$SPARKLE_DEST"

codesign "${APP_SIGN_ARGS[@]}" --sign "$SIGN_ID" \
    --identifier "$APP_ID" \
    "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"
echo "    签名校验通过"

DACBAR_EXPECTED_APP_ID="$EXPECTED_APP_ID" ./scripts/validate-app.sh "$APP"

# Optional notarisation. Without it Gatekeeper blocks the app on any machine
# other than the one that signed it.
#
# Credentials come from a keychain profile, so nothing sensitive is passed on the
# command line or kept in the repo:
#   xcrun notarytool store-credentials <name> \
#       --apple-id <id> --team-id <team> --password <app-specific password>
if [ -n "${DACBAR_NOTARY_PROFILE:-}" ]; then
    NOTARY_ARGS=(--keychain-profile "$DACBAR_NOTARY_PROFILE")
    if [ -n "$NOTARY_KEYCHAIN" ]; then
        NOTARY_ARGS+=(--keychain "$NOTARY_KEYCHAIN")
    fi

    submit_for_notarization() {
        local artifact="$1"
        local description="$2"
        local submit_output
        local submission_id

        echo "==> 提交公证：${description}（首次通常几分钟）"
        if submit_output=$(xcrun notarytool submit "$artifact" \
                "${NOTARY_ARGS[@]}" --wait 2>&1); then
            printf '%s\n' "$submit_output" | grep -E "id:|status:" | head -3
            return 0
        fi

        printf '%s\n' "$submit_output" >&2
        submission_id=$(printf '%s' "$submit_output" \
            | sed -n 's/.*id: \([0-9a-f-]\{36\}\).*/\1/p' | head -1)
        if [ -n "$submission_id" ]; then
            xcrun notarytool log "$submission_id" "${NOTARY_ARGS[@]}" >&2 || true
        fi
        return 1
    }

    NOTARY_ZIP="${APP%.app}-notarize.zip"
    rm -f "$NOTARY_ZIP"
    # ditto, not zip: the bundle's symlinks and metadata have to survive.
    ditto -c -k --keepParent "$APP" "$NOTARY_ZIP"

    if ! submit_for_notarization "$NOTARY_ZIP" "DACBar.app"; then
        rm -f "$NOTARY_ZIP"
        exit 1
    fi
    rm -f "$NOTARY_ZIP"

    # Staple the app before creating the immutable disk image so users and
    # Sparkle retain an offline-verifiable app after copying it out.
    echo "==> 装订 App 票据"
    xcrun stapler staple "$APP"
    DACBAR_EXPECTED_APP_ID="$EXPECTED_APP_ID" DACBAR_REQUIRE_DISTRIBUTION=1 \
        ./scripts/validate-app.sh "$APP"

    DIST_DMG="${APP%.app}-${VERSION}.dmg"
    ./scripts/create-dmg.sh "$APP" "$DIST_DMG" "DACBar ${VERSION}"

    DMG_SIGN_ARGS=(--force --timestamp)
    if [ -n "$SIGN_KEYCHAIN" ]; then
        DMG_SIGN_ARGS+=(--keychain "$SIGN_KEYCHAIN")
    fi
    codesign "${DMG_SIGN_ARGS[@]}" --sign "$SIGN_ID" "$DIST_DMG"
    codesign --verify --strict --verbose=2 "$DIST_DMG"

    if ! submit_for_notarization "$DIST_DMG" "签名 DMG"; then
        exit 1
    fi
    echo "==> 装订 DMG 票据"
    xcrun stapler staple "$DIST_DMG"
    DACBAR_EXPECTED_APP_ID="$EXPECTED_APP_ID" DACBAR_REQUIRE_DISTRIBUTION=1 \
        ./scripts/validate-dmg.sh "$DIST_DMG"
    DIST_DMG_DIRECTORY=$(dirname "$DIST_DMG")
    DIST_DMG_BASENAME=$(basename "$DIST_DMG")
    (
        cd "$DIST_DMG_DIRECTORY"
        shasum -a 256 "$DIST_DMG_BASENAME" > "$DIST_DMG_BASENAME.sha256"
    )
    echo "    分发镜像：$(pwd)/${DIST_DMG}"
    NOTARIZED=1
fi

echo "==> done: $(pwd)/${APP}"
case "$SIGN_ID" in
    -)
        echo
        echo "    ad-hoc 签名 —— 本机可用，拷到别的 Mac 会被 Gatekeeper 拦。"
        echo "    分发需要 Developer ID Application 证书并公证。"
        ;;
    "Apple Development"*)
        echo
        echo "    开发签名 —— 本机可用，拷到别的 Mac 会被 Gatekeeper 拦。"
        echo "    分发需要 Developer ID Application 证书并公证。"
        ;;
    "Developer ID Application"*)
        if [ -n "${NOTARIZED:-}" ] || xcrun stapler validate "$APP" >/dev/null 2>&1; then
            echo "    已公证并装订票据，可分发。"
        else
            echo
            echo "    尚未公证 —— 本机可用，别的 Mac 首次打开会被 Gatekeeper 拦。"
            echo "    公证：DACBAR_NOTARY_PROFILE=<钥匙串配置名> ./build.sh"
        fi
        ;;
esac
