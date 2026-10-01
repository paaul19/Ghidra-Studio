#!/bin/bash
# Builds Ghidra.app: official Ghidra release + bundled Temurin JDK 21 +
# natively compiled arm64 decompiler/sleigh/demangler/lzfse + native launcher.
set -euo pipefail

GHIDRA_VERSION="12.1.4"
GHIDRA_ZIP="ghidra_12.1.4_PUBLIC_20260921.zip"
GHIDRA_URL="https://github.com/NationalSecurityAgency/ghidra/releases/download/Ghidra_${GHIDRA_VERSION}_build/${GHIDRA_ZIP}"
GHIDRA_SHA256="ddac49f903da9d5bac833e5cc79395098b9c33cfd3279be5f31bd00387d2d4db"

JDK_TGZ="OpenJDK21U-jdk_aarch64_mac_hotspot_21.0.12.1_1.tar.gz"
JDK_URL="https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.12.1%2B1/${JDK_TGZ}"
JDK_SHA256="3623232f33a9c3baadf304480b2535f9a3cba8a58d42ecbb438ba267315d9998"

ROOT="$(cd "$(dirname "$0")" && pwd -P)"
CACHE="${CACHE:-$ROOT/.cache}"
WORK="$ROOT/.build"
APP="$ROOT/Ghidra.app"

fetch() { # url file sha256
	local url="$1" file="$CACHE/$2" sum="$3"
	if [ ! -f "$file" ] || ! echo "$sum  $file" | shasum -a 256 -c --status; then
		echo "==> Downloading $2"
		curl -fSL -o "$file" "$url"
		echo "$sum  $file" | shasum -a 256 -c
	fi
}

mkdir -p "$CACHE"
fetch "$GHIDRA_URL" "$GHIDRA_ZIP" "$GHIDRA_SHA256"
fetch "$JDK_URL" "$JDK_TGZ" "$JDK_SHA256"

echo "==> Extracting"
rm -rf "$WORK"; mkdir -p "$WORK"
unzip -q "$CACHE/$GHIDRA_ZIP" -d "$WORK"
tar xzf "$CACHE/$JDK_TGZ" -C "$WORK"
GH="$WORK/ghidra_${GHIDRA_VERSION}_PUBLIC"
JDK_HOME="$(echo "$WORK"/jdk-*/Contents/Home)"

echo "==> Building native arm64 binaries (decompile, sleigh, demangler, lzfse)"
(cd "$GH/support/gradle" && JAVA_HOME="$JDK_HOME" ./gradlew -q --no-daemon buildNatives)
while IFS= read -r d; do
	dest="${d%/build/os/mac_arm_64}/os/mac_arm_64"
	mkdir -p "$dest"
	mv "$d"/* "$dest"/
	rm -rf "${d%/os/mac_arm_64}"
done < <(find "$GH" -type d -path '*/build/os/mac_arm_64')
rm -rf "$GH/support/gradle/build" "$GH/support/gradle/.gradle"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mv "$GH" "$APP/Contents/Resources/ghidra"
mv "$JDK_HOME" "$APP/Contents/Resources/jdk"
install -m 755 "$ROOT/src/launcher.sh" "$APP/Contents/Resources/launcher.sh"
clang -O2 -arch arm64 -mmacosx-version-min=12.0 -o "$APP/Contents/MacOS/Ghidra" "$ROOT/src/launcher.c"

echo "==> Icon"
ICON_WORK="$WORK/icon"; mkdir -p "$ICON_WORK/Ghidra.iconset"
unzip -p "$APP/Contents/Resources/ghidra/Ghidra/Framework/Gui/lib/Gui.jar" images/GhidraIcon256.png > "$ICON_WORK/dragon.png"
swift "$ROOT/src/make_icon.swift" "$ICON_WORK/dragon.png" "$ICON_WORK/icon_1024.png"
for s in 16 32 128 256 512; do
	sips -z $s $s "$ICON_WORK/icon_1024.png" --out "$ICON_WORK/Ghidra.iconset/icon_${s}x${s}.png" >/dev/null
	sips -z $((s*2)) $((s*2)) "$ICON_WORK/icon_1024.png" --out "$ICON_WORK/Ghidra.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICON_WORK/Ghidra.iconset" -o "$APP/Contents/Resources/Ghidra.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>Ghidra</string>
	<key>CFBundleDisplayName</key><string>Ghidra</string>
	<key>CFBundleIdentifier</key><string>local.ghidra.Ghidra</string>
	<key>CFBundleExecutable</key><string>Ghidra</string>
	<key>CFBundleIconFile</key><string>Ghidra</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>${GHIDRA_VERSION}</string>
	<key>CFBundleVersion</key><string>${GHIDRA_VERSION}</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
	<key>LSMinimumSystemVersion</key><string>12.0</string>
	<key>LSArchitecturePriority</key><array><string>arm64</string></array>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSSupportsAutomaticGraphicsSwitching</key><true/>
	<key>NSHumanReadableCopyright</key><string>Ghidra is released by the NSA under the Apache License 2.0</string>
</dict>
</plist>
PLIST

echo "==> Signing (ad-hoc)"
chmod -R u+w "$APP"
xattr -cr "$APP"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

rm -rf "$WORK"
echo "==> Done: $APP ($(du -sh "$APP" | cut -f1))"
