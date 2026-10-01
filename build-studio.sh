#!/bin/bash
# Builds "Ghidra Studio.app": native SwiftUI interface + headless Ghidra engine.
# Reuses the Ghidra payload (Ghidra + JDK + arm64 natives) from Ghidra.app,
# building it first with build.sh if needed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd -P)"
CLASSIC="$ROOT/Ghidra.app"
APP="$ROOT/Ghidra Studio.app"
WORK="$ROOT/.build/studio"

if [ ! -d "$CLASSIC/Contents/Resources/ghidra" ]; then
	"$ROOT/build.sh"
fi
RES_SRC="$CLASSIC/Contents/Resources"
GHIDRA_VERSION="$(defaults read "$CLASSIC/Contents/Info.plist" CFBundleShortVersionString)"

rm -rf "$WORK"; mkdir -p "$WORK/classes"

echo "==> Compiling engine (Java)"
CP="$(find "$RES_SRC/ghidra/Ghidra" -name '*.jar' | tr '\n' ':')"
"$RES_SRC/jdk/bin/javac" --release 21 -nowarn -cp "$CP" -d "$WORK/classes" "$ROOT"/backend/src/studio/*.java
"$RES_SRC/jdk/bin/jar" cf "$WORK/studio-server.jar" -C "$WORK/classes" .

echo "==> Compiling interface (SwiftUI)"
(cd "$ROOT/app" && swift build -c release)

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp -Rc "$RES_SRC/ghidra" "$RES_SRC/jdk" "$APP/Contents/Resources/"
cp "$WORK/studio-server.jar" "$APP/Contents/Resources/ghidra/Ghidra/patch/"
install -m 755 "$ROOT/src/engine.sh" "$APP/Contents/Resources/engine.sh"
install -m 755 "$ROOT/src/launcher.sh" "$APP/Contents/Resources/launcher.sh"
cp "$RES_SRC/Ghidra.icns" "$APP/Contents/Resources/Ghidra.icns"
install -m 755 "$ROOT/app/.build/release/GhidraStudio" "$APP/Contents/MacOS/GhidraStudio"

echo "==> Localizations (es, en)"
python3 - "$ROOT/app/Localization/en.json" "$APP/Contents/Resources" <<'PY'
import json, os, sys
table = json.load(open(sys.argv[1], encoding="utf-8"))
res = sys.argv[2]
def esc(s):
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
for lang in ("en", "es"):
    d = os.path.join(res, lang + ".lproj")
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "Localizable.strings"), "w", encoding="utf-8") as f:
        for k, v in sorted(table.items()):
            f.write('"%s" = "%s";\n' % (esc(k), esc(v if lang == "en" else k)))
PY

echo "==> Icon"
mkdir -p "$WORK/AppIcon.iconset"
unzip -p "$RES_SRC/ghidra/Ghidra/Framework/Gui/lib/Gui.jar" images/GhidraIcon256.png > "$WORK/dragon.png"
swift "$ROOT/src/make_icon.swift" "$WORK/dragon.png" "$WORK/icon_1024.png" dark
for s in 16 32 128 256 512; do
	sips -z $s $s "$WORK/icon_1024.png" --out "$WORK/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
	sips -z $((s*2)) $((s*2)) "$WORK/icon_1024.png" --out "$WORK/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$WORK/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>Ghidra Studio</string>
	<key>CFBundleDisplayName</key><string>Ghidra Studio</string>
	<key>CFBundleIdentifier</key><string>local.ghidra.GhidraStudio</string>
	<key>CFBundleExecutable</key><string>GhidraStudio</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleDevelopmentRegion</key><string>es</string>
	<key>CFBundleLocalizations</key><array><string>es</string><string>en</string></array>
	<key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
	<key>LSMinimumSystemVersion</key><string>26.0</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSHumanReadableCopyright</key><string>Interfaz nativa sobre Ghidra ${GHIDRA_VERSION} (NSA, Apache 2.0)</string>
	<key>CFBundleDocumentTypes</key>
	<array>
		<dict>
			<key>CFBundleTypeName</key><string>Binario</string>
			<key>CFBundleTypeRole</key><string>Viewer</string>
			<key>LSHandlerRank</key><string>Alternate</string>
			<key>LSItemContentTypes</key>
			<array>
				<string>public.unix-executable</string>
				<string>com.apple.mach-o-binary</string>
				<string>com.apple.mach-o-dylib</string>
				<string>com.microsoft.windows-executable</string>
				<string>com.microsoft.windows-dynamic-link-library</string>
				<string>public.data</string>
			</array>
		</dict>
	</array>
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
