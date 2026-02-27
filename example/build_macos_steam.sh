#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Build the Steamworks example as a macOS .app bundle with Steam overlay-friendly signing.

Usage:
  ./build_macos_steam.sh [options]

Options:
  --release                 Build optimized executable (default: debug).
  --target <value>          Build target: host|darwin_arm64|darwin_amd64|universal (default: host).
  --out <dir>               Output directory for the .app (default: ./build/macos).
  --app-name <name>         App bundle/executable name (default: OdinSteamworksExample).
  --bundle-id <id>          CFBundleIdentifier (default: com.example.odinsteamworks).
  --identity <sign-id>      codesign identity (default: "-" for ad-hoc signing).
  --min-macos <version>     LSMinimumSystemVersion (default: 10.15).
  --steam-appid <id>        Override AppID written to steam_appid.txt in the bundle.
  --no-sign                 Skip codesign.
  --runtime                 Sign with hardened runtime flags (for Developer ID distribution).
  --launch                  Launch after build using the generated overlay launcher.
  --start-steam             Start Steam if needed before --launch.
  --                        Pass remaining flags directly to `odin build`.
  -h, --help                Show this help.
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STEAM_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

APP_NAME="OdinSteamworksExample"
BUNDLE_ID="com.example.odinsteamworks"
OUT_DIR="${SCRIPT_DIR}/build/macos"
SIGN_IDENTITY="-"
TARGET="host"
MIN_MACOS_VERSION="10.15"
STEAM_APPID_OVERRIDE=""
ENABLE_RUNTIME_SIGNING=0
ENABLE_SIGNING=1
AUTO_LAUNCH=0
AUTO_START_STEAM=0
ODIN_FLAGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
    --target)
        TARGET="$2"
        shift 2
        ;;
    --out)
        OUT_DIR="$2"
        shift 2
        ;;
    --app-name)
        APP_NAME="$2"
        shift 2
        ;;
    --bundle-id)
        BUNDLE_ID="$2"
        shift 2
        ;;
    --identity)
        SIGN_IDENTITY="$2"
        shift 2
        ;;
    --min-macos)
        MIN_MACOS_VERSION="$2"
        shift 2
        ;;
    --steam-appid)
        STEAM_APPID_OVERRIDE="$2"
        shift 2
        ;;
    --no-sign)
        ENABLE_SIGNING=0
        shift
        ;;
    --runtime)
        ENABLE_RUNTIME_SIGNING=1
        shift
        ;;
    --launch)
        AUTO_LAUNCH=1
        shift
        ;;
    --start-steam)
        AUTO_START_STEAM=1
        shift
        ;;
    --)
        shift
        ODIN_FLAGS=("$@")
        break
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    *)
        echo "Unknown option: $1" >&2
        usage
        exit 1
        ;;
    esac
done

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "error: this script is for macOS only" >&2
    exit 1
fi

if ! command -v odin >/dev/null 2>&1; then
    echo "error: 'odin' not found in PATH" >&2
    exit 1
fi

ENTITLEMENTS="${SCRIPT_DIR}/SteamEntitlements.plist"
STEAM_DYLIB="${STEAM_ROOT}/redist/osx/libsteam_api.dylib"
STEAM_APPID="${SCRIPT_DIR}/steam_appid.txt"

case "${TARGET}" in
host | darwin_arm64 | darwin_amd64 | universal) ;;
*)
    echo "error: invalid --target value '${TARGET}'" >&2
    usage
    exit 1
    ;;
esac

APP_BUNDLE="${OUT_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
TEMP_DIR="${OUT_DIR}/.tmp_${APP_NAME}"
LAUNCHER="${OUT_DIR}/run_${APP_NAME}_with_overlay.sh"

echo "Building ${APP_NAME} (target=${TARGET})..."
rm -rf "${APP_BUNDLE}"
rm -rf "${TEMP_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

build_one() {
    local target="$1"
    local out_bin="$2"

    local flags=(
        "${ODIN_FLAGS[@]}"
        "-minimum-os-version:${MIN_MACOS_VERSION}"
        "-out:${out_bin}"
    )
    if [[ "${target}" != "host" ]]; then
        flags+=("-target:${target}")
    fi
    if [[ ${#ODIN_FLAGS[@]} -gt 0 ]]; then
        flags+=("${ODIN_FLAGS[@]}")
    fi

    odin build "${SCRIPT_DIR}" "${flags[@]}"
}

if [[ "${TARGET}" == "universal" ]]; then
    mkdir -p "${TEMP_DIR}"
    ARM64_BIN="${TEMP_DIR}/${APP_NAME}_arm64"
    AMD64_BIN="${TEMP_DIR}/${APP_NAME}_amd64"
    build_one "darwin_arm64" "${ARM64_BIN}"
    build_one "darwin_amd64" "${AMD64_BIN}"
    lipo -create -output "${MACOS_DIR}/${APP_NAME}" "${ARM64_BIN}" "${AMD64_BIN}"
else
    build_one "${TARGET}" "${MACOS_DIR}/${APP_NAME}"
fi

cp "${STEAM_DYLIB}" "${MACOS_DIR}/libsteam_api.dylib"
if [[ -n "${STEAM_APPID_OVERRIDE}" ]]; then
    printf "%s\n" "${STEAM_APPID_OVERRIDE}" >"${MACOS_DIR}/steam_appid.txt"
else
    cp "${STEAM_APPID}" "${MACOS_DIR}/steam_appid.txt"
fi

cat >"${CONTENTS_DIR}/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>${MIN_MACOS_VERSION}</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.games</string>
    <key>CFBundleSupportedPlatforms</key>
    <array>
        <string>MacOSX</string>
    </array>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

if [[ "${ENABLE_SIGNING}" -eq 1 ]]; then
    sign_args=(
        --force
        --deep
        --sign "${SIGN_IDENTITY}"
        --entitlements "${ENTITLEMENTS}"
    )
    if [[ "${ENABLE_RUNTIME_SIGNING}" -eq 1 ]]; then
        sign_args+=(--options runtime)
        if [[ "${SIGN_IDENTITY}" != "-" ]]; then
            sign_args+=(--timestamp)
        fi
    fi

    echo "Signing app bundle..."
    xattr -cr "${APP_BUNDLE}" || true
    codesign "${sign_args[@]}" "${APP_BUNDLE}"
    codesign --verify --deep "${APP_BUNDLE}"
else
    echo "Skipping codesign (--no-sign)."
fi

cat >"${LAUNCHER}" <<EOF
#!/usr/bin/env bash
set -euo pipefail

STEAM_CLIENT_MACOS="\${HOME}/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS"
APP_EXE="${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
APP_DIR="\$(dirname "\${APP_EXE}")"

if [[ ! -x "\${APP_EXE}" ]]; then
    echo "error: app executable not found: \${APP_EXE}" >&2
    exit 1
fi
if [[ ! -f "\${STEAM_CLIENT_MACOS}/gameoverlayrenderer.dylib" ]]; then
    echo "error: Steam overlay dylib not found at \${STEAM_CLIENT_MACOS}/gameoverlayrenderer.dylib" >&2
    echo "start Steam once, then retry." >&2
    exit 1
fi

export DYLD_INSERT_LIBRARIES="\${STEAM_CLIENT_MACOS}/gameoverlayrenderer.dylib"
export DYLD_FORCE_FLAT_NAMESPACE=1
export SteamGameId="\$(cat "${MACOS_DIR}/steam_appid.txt" | tr -d '\n')"
export SteamAppId="\${SteamGameId}"

cd "\${APP_DIR}"
exec "\${APP_EXE}" "\$@"
EOF
chmod +x "${LAUNCHER}"

if [[ "${AUTO_LAUNCH}" -eq 1 ]]; then
    if [[ "${AUTO_START_STEAM}" -eq 1 ]]; then
        if ! pgrep -f "Steam.AppBundle/Steam/Contents/MacOS/steam_osx" >/dev/null 2>&1; then
            echo
            echo "Starting Steam..."
            open -a Steam
            for _ in {1..60}; do
                if pgrep -f "Steam.AppBundle/Steam/Contents/MacOS/steam_osx" >/dev/null 2>&1; then
                    break
                fi
                sleep 1
            done
        fi
    fi

    echo
    echo "Launching app with overlay injection..."
    exec "${LAUNCHER}"
fi
