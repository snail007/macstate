#!/bin/bash
set -euo pipefail

APP_NAME="MacState"
BUNDLE_DIR="build/${APP_NAME}.app"
CONTENTS_DIR="${BUNDLE_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
# Auto-detect architecture
ARCH=$(uname -m)
if [ "${ARCH}" = "x86_64" ]; then
    TARGET="x86_64-apple-macos13.0"
else
    TARGET="arm64-apple-macos13.0"
fi
SDK=$(xcrun --show-sdk-path --sdk macosx)

SOURCES=(
    MacState/App/MacStateApp.swift
    MacState/Core/SMCService.swift
    MacState/Core/CPUService.swift
    MacState/Core/MemoryService.swift
    MacState/Core/NetworkService.swift
    MacState/Core/MonitorManager.swift
    MacState/Core/CpuTempToggle.swift
    MacState/Core/MemoryToggle.swift
    MacState/Core/FanToggle.swift
    MacState/Core/NetworkToggle.swift
    MacState/Core/BatteryService.swift
    MacState/Core/BatteryToggle.swift
    MacState/Core/LaunchAtLoginService.swift
    MacState/Core/PrivilegeService.swift
    MacState/Core/StatusBarController.swift
    MacState/Core/Localization.swift
    MacState/Core/ProcessNetworkService.swift
    MacState/Core/ProcessCPUService.swift
    MacState/Core/ProcessMemoryService.swift
    MacState/Core/ConnectionService.swift
    MacState/Core/NetworkProcessPanel.swift
    MacState/Core/CPUProcessPanel.swift
    MacState/Core/MemoryProcessPanel.swift
    MacState/Core/ClickableLabel.swift
    MacState/Core/IP2RegionService.swift
    MacState/Core/FinderMenuToggle.swift
    MacState/Views/AppKitSwitch.swift
    MacState/Views/PopoverView.swift
    MacState/Views/SettingsView.swift
)

CONFIG="${1:-release}"

echo "==> Building ${APP_NAME} (${CONFIG})..."

# Clean
rm -rf build
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

# Compile ip2region C sources
C_FLAGS="-std=c99 -Wall -O2 -target ${TARGET} -isysroot ${SDK}"
IP2REGION_DIR="MacState/Vendor/ip2region"
xcrun clang ${C_FLAGS} -c "${IP2REGION_DIR}/xdb_searcher.c" -o build/xdb_searcher.o -I"${IP2REGION_DIR}"
xcrun clang ${C_FLAGS} -c "${IP2REGION_DIR}/xdb_util.c" -o build/xdb_util.o -I"${IP2REGION_DIR}"

# Compile Swift + link C objects
SWIFT_FLAGS="-target ${TARGET} -sdk ${SDK} -framework IOKit -framework SwiftUI -framework AppKit -framework ServiceManagement -framework Security -import-objc-header ${IP2REGION_DIR}/bridge.h -I${IP2REGION_DIR}"
if [ "${CONFIG}" = "debug" ]; then
    SWIFT_FLAGS="${SWIFT_FLAGS} -g -Onone"
else
    SWIFT_FLAGS="${SWIFT_FLAGS} -O"
fi

xcrun swiftc ${SWIFT_FLAGS} -o "${MACOS_DIR}/${APP_NAME}" "${SOURCES[@]}" build/xdb_searcher.o build/xdb_util.o

# Copy resources
cp MacState/Resources/Info.plist "${CONTENTS_DIR}/Info.plist"
cp MacState/Resources/AppIcon.icns "${RESOURCES_DIR}/AppIcon.icns"
cp MacState/Resources/ip2region_v4.xdb "${RESOURCES_DIR}/ip2region_v4.xdb"

# Build FinderSync extension (.appex)
APPEX_DIR="${CONTENTS_DIR}/PlugIns/FinderMenu.appex"
APPEX_CONTENTS="${APPEX_DIR}/Contents"
APPEX_MACOS="${APPEX_CONTENTS}/MacOS"
mkdir -p "${APPEX_MACOS}"

xcrun swiftc -target ${TARGET} -sdk ${SDK} \
    -framework Cocoa -framework FinderSync \
    -application-extension \
    -o "${APPEX_MACOS}/FinderMenuSync" \
    MacState/Extensions/main.swift \
    MacState/Extensions/FinderMenuSync.swift

cp MacState/Extensions/FinderMenuSync-Info.plist "${APPEX_CONTENTS}/Info.plist"

# Sign inside-out: appex first (with sandbox entitlements), then main app
codesign --force --sign - --entitlements MacState/Extensions/FinderMenuSync.entitlements "${APPEX_DIR}"
codesign --force --sign - "${BUNDLE_DIR}"

echo "==> Build complete: ${BUNDLE_DIR}"
echo "==> Run with: open ${BUNDLE_DIR}"
echo "==> Binary size: $(du -h "${MACOS_DIR}/${APP_NAME}" | cut -f1)"
