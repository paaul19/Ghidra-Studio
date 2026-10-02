#!/bin/bash
# Builds "Ghidra Studio.app": native SwiftUI interface + headless Ghidra engine.
# Reuses the Ghidra payload (Ghidra + JDK + arm64 natives) from Ghidra.app,
# building it first with build.sh if needed.
set -euo pipefail

# CPython that hosts the engine (PyGhidra): Python scripts and interpreter.
PYTHON_TGZ="cpython-3.13.15+20260929-aarch64-apple-darwin-install_only_stripped.tar.gz"
PYTHON_URL="https://github.com/astral-sh/python-build-standalone/releases/download/20260929/${PYTHON_TGZ//+/%2B}"
PYTHON_SHA256="d66c67f16148c7454b1509c32747175f7669c8b8e105b97b92a0000d66af6e6e"

ROOT="$(cd "$(dirname "$0")" && pwd -P)"
CACHE="${CACHE:-$ROOT/.cache}"
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
python3 "$ROOT/backend/patch_ghidra.py" "$RES_SRC/ghidra" "$WORK/patched"
PATCHED=()
while IFS= read -r f; do PATCHED+=("$f"); done < <(find "$WORK/patched" -name '*.java' 2>/dev/null)
"$RES_SRC/jdk/bin/javac" --release 21 -nowarn -cp "$CP" -d "$WORK/classes" "$ROOT"/backend/src/studio/*.java ${PATCHED[@]+"${PATCHED[@]}"}
"$RES_SRC/jdk/bin/jar" cf "$WORK/studio-server.jar" -C "$WORK/classes" .

echo "==> Compiling interface (SwiftUI)"
(cd "$ROOT/app" && swift build -c release)

echo "==> Python (PyGhidra)"
mkdir -p "$CACHE"
if [ ! -f "$CACHE/$PYTHON_TGZ" ] || ! echo "$PYTHON_SHA256  $CACHE/$PYTHON_TGZ" | shasum -a 256 -c --status; then
	echo "    downloading $PYTHON_TGZ"
	curl -fSL -o "$CACHE/$PYTHON_TGZ" "$PYTHON_URL"
	echo "$PYTHON_SHA256  $CACHE/$PYTHON_TGZ" | shasum -a 256 -c
fi
tar xzf "$CACHE/$PYTHON_TGZ" -C "$WORK"
# PyGhidra and JPype come from the wheels shipped inside Ghidra itself (no network needed).
"$WORK/python/bin/python3" -m pip install --quiet --no-index --disable-pip-version-check \
	--find-links "$RES_SRC/ghidra/Ghidra/Features/PyGhidra/pypkg/dist" pyghidra
# Precompile so nothing gets written into the signed bundle at run time.
"$WORK/python/bin/python3" -m compileall -q "$WORK/python/lib" >/dev/null 2>&1 || true

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp -Rc "$RES_SRC/ghidra" "$RES_SRC/jdk" "$APP/Contents/Resources/"
cp "$WORK/studio-server.jar" "$APP/Contents/Resources/ghidra/Ghidra/patch/"
cp -Rc "$WORK/python" "$APP/Contents/Resources/python"
install -m 755 "$ROOT/src/engine.sh" "$APP/Contents/Resources/engine.sh"
install -m 644 "$ROOT/src/engine.py" "$APP/Contents/Resources/engine.py"
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
	<key>CFBundleShortVersionString</key><string>1.1</string>
	<key>CFBundleVersion</key><string>2</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleDevelopmentRegion</key><string>es</string>
	<key>CFBundleLocalizations</key><array><string>es</string><string>en</string></array>
	<key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
	<key>LSMinimumSystemVersion</key><string>26.0</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSHumanReadableCopyright</key><string>Interfaz nativa sobre Ghidra ${GHIDRA_VERSION} (NSA, Apache 2.0)</string>
	<key>CFBundleURLTypes</key>
	<array>
		<dict>
			<key>CFBundleURLName</key><string>Ghidra URL</string>
			<key>CFBundleURLSchemes</key><array><string>ghidra</string></array>
		</dict>
	</array>
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
