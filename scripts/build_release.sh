#!/usr/bin/env bash
# AgentRunner — Release 빌드 + DMG 패키징
# 결과물: dist/AgentRunner.app, dist/AgentRunner-<version>.dmg
#
# 코드사인:
#   기본: ad-hoc(--sign -) — 본인 머신/zip 배포 OK
#   Apple Developer ID 있으면: 환경변수 CODESIGN_IDENTITY 로 지정
#
# Usage:
#   ./scripts/build_release.sh           # 기본 빌드
#   ./scripts/build_release.sh --dmg     # DMG까지 생성
#   CODESIGN_IDENTITY="Developer ID Application: ..." ./scripts/build_release.sh

set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT_DIR="src"
PROJECT="${PROJECT_DIR}/AgentRunner.xcodeproj"
SCHEME="AgentRunner"
APP_NAME="AgentRunner"
BUILD_DIR="${PROJECT_DIR}/build"
DIST_DIR="dist"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${BUILD_DIR}/Build/Products/Release/${APP_NAME}.app/Contents/Info.plist" 2>/dev/null || echo "0.1.0")"

echo "▸ Cleaning previous build..."
rm -rf "${BUILD_DIR}" "${DIST_DIR}"
mkdir -p "${DIST_DIR}"

echo "▸ Building Release configuration..."
xcodebuild \
    -project "${PROJECT}" \
    -scheme "${SCHEME}" \
    -configuration Release \
    -derivedDataPath "${BUILD_DIR}/" \
    build 2>&1 | grep -E "error:|warning:|BUILD" | tail -10 || true

BUILT_APP="${BUILD_DIR}/Build/Products/Release/${APP_NAME}.app"
if [[ ! -d "${BUILT_APP}" ]]; then
    echo "✗ Build failed — ${BUILT_APP} not found"
    exit 1
fi

echo "▸ Copying to dist/..."
cp -R "${BUILT_APP}" "${DIST_DIR}/"

# Re-read version after build
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${DIST_DIR}/${APP_NAME}.app/Contents/Info.plist")"

echo "▸ Code signing..."
SIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
codesign --force --deep --options runtime \
    --entitlements "${PROJECT_DIR}/${APP_NAME}/${APP_NAME}.entitlements" \
    --sign "${SIGN_IDENTITY}" \
    "${DIST_DIR}/${APP_NAME}.app"
echo "  Signed with: ${SIGN_IDENTITY}"

# Verify signature
codesign --verify --verbose "${DIST_DIR}/${APP_NAME}.app" 2>&1 | sed 's/^/  /'

# DMG 옵션 — create-dmg로 배경 + 아이콘 위치 고정 (AppleScript 안정성 위임)
if [[ "${1:-}" == "--dmg" ]]; then
    echo "▸ Creating DMG with custom layout..."
    DMG_NAME="${APP_NAME}-${VERSION}.dmg"
    BG_SRC="docs/dmg_bg.png"

    rm -f "${DIST_DIR}/${DMG_NAME}"

    if ! command -v create-dmg >/dev/null 2>&1; then
        echo "  ⚠️  create-dmg not installed. Install with: brew install create-dmg"
        echo "  Falling back to plain DMG (no custom layout)..."
        DMG_TMP="${DIST_DIR}/dmg_tmp"
        rm -rf "${DMG_TMP}"
        mkdir -p "${DMG_TMP}"
        cp -R "${DIST_DIR}/${APP_NAME}.app" "${DMG_TMP}/"
        ln -sf /Applications "${DMG_TMP}/Applications"
        hdiutil create -volname "${APP_NAME}" -srcfolder "${DMG_TMP}" \
            -ov -format UDZO "${DIST_DIR}/${DMG_NAME}" >/dev/null
        rm -rf "${DMG_TMP}"
    else
        # create-dmg 옵션:
        #   --volname           : 마운트 시 표시될 볼륨명
        #   --background        : 배경 PNG (window 영역에 깔림)
        #   --window-size       : Finder 창 크기
        #   --icon-size         : 아이콘 픽셀 크기
        #   --icon              : 앱 아이콘 위치
        #   --app-drop-link     : Applications 심볼릭 링크 위치
        #   --no-internet-enable: extended attributes 깔끔하게
        BG_FLAG=()
        [[ -f "${BG_SRC}" ]] && BG_FLAG=(--background "${BG_SRC}")

        create-dmg \
            --volname "${APP_NAME}" \
            "${BG_FLAG[@]}" \
            --window-pos 200 120 \
            --window-size 600 400 \
            --icon-size 96 \
            --icon "${APP_NAME}.app" 150 220 \
            --app-drop-link 450 220 \
            --no-internet-enable \
            "${DIST_DIR}/${DMG_NAME}" \
            "${DIST_DIR}/${APP_NAME}.app" 2>&1 | tail -5
    fi
    echo "  DMG: ${DIST_DIR}/${DMG_NAME}"
fi

echo ""
echo "✓ Done"
echo "  App:  ${DIST_DIR}/${APP_NAME}.app  ($(du -sh "${DIST_DIR}/${APP_NAME}.app" | cut -f1))"
[[ -f "${DIST_DIR}/${APP_NAME}-${VERSION}.dmg" ]] && \
    echo "  DMG:  ${DIST_DIR}/${APP_NAME}-${VERSION}.dmg  ($(du -sh "${DIST_DIR}/${APP_NAME}-${VERSION}.dmg" | cut -f1))"
echo ""
echo "▸ First-launch (다른 사용자 머신에서):"
echo "  1. .app 파일에 Right-click → Open"
echo "  2. Gatekeeper 경고 나오면 'Open' 클릭"
echo "  (코드사인된 .app은 Apple 인증 없으면 첫 실행 시 차단됨)"
