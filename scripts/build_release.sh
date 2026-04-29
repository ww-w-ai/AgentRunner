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

# DMG 옵션 — 배경 이미지 + 아이콘 위치 고정으로 "여기로 드래그" UX 명확히
if [[ "${1:-}" == "--dmg" ]]; then
    echo "▸ Creating DMG with custom layout..."
    DMG_NAME="${APP_NAME}-${VERSION}.dmg"
    DMG_TMP="${DIST_DIR}/dmg_tmp"
    DMG_RW="${DIST_DIR}/${APP_NAME}-rw.dmg"
    BG_SRC="docs/dmg_bg.png"

    rm -rf "${DMG_TMP}" "${DMG_RW}"
    mkdir -p "${DMG_TMP}"
    cp -R "${DIST_DIR}/${APP_NAME}.app" "${DMG_TMP}/"
    ln -sf /Applications "${DMG_TMP}/Applications"

    # 배경 이미지를 .background 폴더에 (Finder 컨벤션)
    if [[ -f "${BG_SRC}" ]]; then
        mkdir -p "${DMG_TMP}/.background"
        cp "${BG_SRC}" "${DMG_TMP}/.background/bg.png"
    fi

    # 1) 쓰기 가능한 DMG 생성 + 마운트
    hdiutil create -volname "${APP_NAME}" \
        -srcfolder "${DMG_TMP}" \
        -fs HFS+ -format UDRW -ov \
        "${DMG_RW}" >/dev/null

    MOUNT_DIR="$(hdiutil attach -readwrite -noverify "${DMG_RW}" | \
        awk -F'\t' '/\/Volumes\//{print $NF; exit}')"
    sleep 1

    # 2) AppleScript로 윈도우 크기/배경/아이콘 위치 적용
    if [[ -f "${BG_SRC}" ]]; then
        # 콜론이 들어간 alias 표현 — 마운트 볼륨명 기준
        VOLNAME="${APP_NAME}"
        osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "${VOLNAME}"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {300, 200, 900, 600}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 96
        try
            set background picture of viewOptions to POSIX file "${MOUNT_DIR}/.background/bg.png"
        end try
        set position of item "${APP_NAME}.app" of container window to {150, 220}
        set position of item "Applications" of container window to {450, 220}
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT
        sync
    fi

    # 3) 언마운트 + 압축본으로 변환
    hdiutil detach "${MOUNT_DIR}" -quiet || true
    hdiutil convert "${DMG_RW}" -format UDZO -imagekey zlib-level=9 \
        -ov -o "${DIST_DIR}/${DMG_NAME}" >/dev/null

    rm -rf "${DMG_TMP}" "${DMG_RW}"
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
