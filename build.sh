#!/bin/bash
set -e

APP_NAME="VibeGauge"
APP_BUNDLE="${APP_NAME}.app"
BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "==> 正在编译 ${APP_NAME}..."
cd "${BUILD_DIR}"

rm -rf "${APP_BUNDLE}" "${APP_NAME}" "${APP_NAME}"-*

# 默认 Universal（Apple Silicon + Intel）；本地调试可 ARCHS=arm64 ./build.sh 只编一份
ARCHS="${ARCHS:-arm64 x86_64}"
for ARCH in ${ARCHS}; do
    echo "    - ${ARCH}"
    swiftc -O \
        -target "${ARCH}-apple-macosx14.0" \
        -framework Cocoa \
        -framework SwiftUI \
        -framework ServiceManagement \
        -framework UserNotifications \
        -lsqlite3 \
        Sources/UITheme.swift \
        Sources/DesignSystem.swift \
        Sources/PricingCatalog.swift \
        Sources/PriceSync.swift \
        Sources/ProcessScanner.swift \
        Sources/ProxyManager.swift \
        Sources/NetworkScanner.swift \
        Sources/NetworkTabView.swift \
        Sources/OpenCodeUsage.swift \
        Sources/RemoteCollector.swift \
        Sources/UsageHistory.swift \
        Sources/UsageForecast.swift \
        Sources/NerfDetector.swift \
        Sources/StatsTabView.swift \
        Sources/HealthViews.swift \
        Sources/PricingViews.swift \
        Sources/DashboardView.swift \
        Sources/AppDelegate.swift \
        Sources/main.swift \
        -o "${APP_NAME}-${ARCH}"
done
lipo -create "${APP_NAME}"-* -output "${APP_NAME}"
rm -f "${APP_NAME}"-*

echo "==> 正在构建 App Bundle..."
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

mv "${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist "${APP_BUNDLE}/Contents/Info.plist"
cp Resources/vibegauge-proxy.py "${APP_BUNDLE}/Contents/Resources/vibegauge-proxy.py"
cp Resources/vibegauge-collector.py "${APP_BUNDLE}/Contents/Resources/vibegauge-collector.py"
cp Resources/prices.builtin.json "${APP_BUNDLE}/Contents/Resources/prices.builtin.json"
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
fi

echo "==> 正在签名..."
codesign --force --deep --sign - "${APP_BUNDLE}"

echo "==> 编译构建完成: ${BUILD_DIR}/${APP_BUNDLE}"
