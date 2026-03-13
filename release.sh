#!/bin/bash
set -euo pipefail

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    echo "Usage: bash release.sh <version>"
    echo "Example: bash release.sh 1.0.0"
    exit 1
fi

APP_NAME="MacState"
REPO="snail007/macstate"
DIST_DIR="dist"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
ZIP_NAME="${APP_NAME}-${VERSION}.zip"
TAG="v${VERSION}"

echo "==> Releasing ${APP_NAME} ${TAG}..."

# Build
bash build.sh

# Prepare dist
rm -rf "${DIST_DIR}"
mkdir -p "${DIST_DIR}"

# Create .zip
echo "==> Creating ${ZIP_NAME}..."
cd build
zip -r -y "../${DIST_DIR}/${ZIP_NAME}" MacState.app
cd ..

# Create .dmg
echo "==> Creating ${DMG_NAME}..."
DMG_TMP="${DIST_DIR}/tmp.dmg"
DMG_STAGING="${DIST_DIR}/dmg_staging"
rm -rf "${DMG_STAGING}"
mkdir -p "${DMG_STAGING}"
cp -R build/MacState.app "${DMG_STAGING}/"
ln -s /Applications "${DMG_STAGING}/Applications"

hdiutil create -volname "${APP_NAME}" \
    -srcfolder "${DMG_STAGING}" \
    -ov -format UDRW \
    "${DMG_TMP}" 2>/dev/null

DEVICE=$(hdiutil attach -readwrite -noverify "${DMG_TMP}" 2>/dev/null | grep '/Volumes/' | head -1 | awk '{print $1}')
sleep 1

osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "${APP_NAME}"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {100, 100, 640, 400}
        set opts to the icon view options of container window
        set icon size of opts to 96
        set arrangement of opts to not arranged
        set position of item "MacState.app" of container window to {140, 150}
        set position of item "Applications" of container window to {400, 150}
        close
        open
        update without registering applications
    end tell
end tell
APPLESCRIPT

sync
sleep 2

# Close Finder window to release volume lock
osascript -e "tell application \"Finder\" to close every window" 2>/dev/null || true
sleep 1

hdiutil detach "${DEVICE}" 2>/dev/null || hdiutil detach "${DEVICE}" -force 2>/dev/null || true
sleep 1

hdiutil convert "${DMG_TMP}" -format UDZO -o "${DIST_DIR}/${DMG_NAME}" 2>/dev/null
rm -f "${DMG_TMP}"
rm -rf "${DMG_STAGING}"

echo "==> Packages ready:"
ls -lh "${DIST_DIR}/${DMG_NAME}" "${DIST_DIR}/${ZIP_NAME}"

# GitHub Release
TOKEN=$(security find-generic-password -a "macstate" -s "github-token" -w)
API="https://api.github.com/repos/${REPO}"

echo "==> Creating GitHub release ${TAG}..."

RELEASE_BODY=$(cat <<EOF
## ${APP_NAME} ${TAG}

轻量级 macOS 菜单栏系统监控工具。

### 下载 / Download

- **${DMG_NAME}** — 拖拽安装 (Drag to Applications)
- **${ZIP_NAME}** — 解压即用

### 功能 / Features

- CPU 使用率 / CPU Usage
- CPU 温度 / CPU Temperature
- 内存占用 / Memory Usage
- 风扇转速 / Fan Speed
- 网络速度 / Network Speed
- 充电功率 / Charging Power
- 进程排行 / Process Panel (Top 10)
- IP 归属地 / IP Geolocation (offline)
- Finder 右键菜单 / Finder Context Menu
  - 在此打开终端 / Open Terminal Here
  - 复制路径 / Copy Path
- 中文/English 双语支持

### 系统要求 / Requirements

- macOS 13.0+
- Intel (x86_64) 或 Apple Silicon (arm64)
EOF
)

RELEASE_RESPONSE=$(curl -s -X POST "${API}/releases" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -d "$(jq -n \
        --arg tag "${TAG}" \
        --arg name "${APP_NAME} ${TAG}" \
        --arg body "${RELEASE_BODY}" \
        '{tag_name: $tag, name: $name, body: $body, draft: false, prerelease: false}')")

RELEASE_ID=$(echo "${RELEASE_RESPONSE}" | jq -r '.id')
UPLOAD_URL=$(echo "${RELEASE_RESPONSE}" | jq -r '.upload_url' | sed 's/{?name,label}//')

if [ "${RELEASE_ID}" = "null" ] || [ -z "${RELEASE_ID}" ]; then
    echo "ERROR: Failed to create release"
    echo "${RELEASE_RESPONSE}" | jq .
    exit 1
fi

echo "==> Release created (ID: ${RELEASE_ID})"

# Upload assets
for FILE in "${DIST_DIR}/${DMG_NAME}" "${DIST_DIR}/${ZIP_NAME}"; do
    FILENAME=$(basename "${FILE}")
    if [[ "${FILENAME}" == *.dmg ]]; then
        CONTENT_TYPE="application/x-apple-diskimage"
    else
        CONTENT_TYPE="application/zip"
    fi
    echo "==> Uploading ${FILENAME}..."
    curl -s -X POST "${UPLOAD_URL}?name=${FILENAME}" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: ${CONTENT_TYPE}" \
        --data-binary "@${FILE}" | jq -r '"    -> \(.name) (\(.size / 1048576 | . * 100 | floor / 100) MB)"'
done

RELEASE_URL=$(echo "${RELEASE_RESPONSE}" | jq -r '.html_url')
echo ""
echo "==> Released: ${RELEASE_URL}"
