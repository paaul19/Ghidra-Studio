#!/bin/bash
# Starts the headless Ghidra engine used by Ghidra Studio.
# stdin/stdout carry the JSON protocol; stderr is Ghidra's log.
#   engine.sh <projectDir>
# With the bundled CPython the engine is hosted by PyGhidra (Python scripts and interpreter);
# set STUDIO_NO_PYTHON=1 to start the plain Java engine instead.

RES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
GHIDRA_HOME="$RES/ghidra"
export JAVA_HOME="$RES/jdk"
JAVA="$JAVA_HOME/bin/java"
PYTHON="$RES/python/bin/python3"
export PYTHONDONTWRITEBYTECODE=1

# Remove the extensions marked for uninstall (the classic Ghidra does this when its GUI starts).
prop() { sed -n "s/^$1=//p" "$GHIDRA_HOME/Ghidra/application.properties" | tr -d '\r'; }
SETTINGS="$HOME/Library/ghidra/ghidra_$(prop application.version)_$(prop application.release.name)"
for marker in "$SETTINGS"/Extensions/*/extension.properties.uninstalled; do
	[ -f "$marker" ] && rm -rf "$(dirname "$marker")"
done

if [ -z "$STUDIO_NO_PYTHON" ] && [ -x "$PYTHON" ] && "$PYTHON" -c 'import pyghidra' 2>/dev/null; then
	exec "$PYTHON" -u -P "$RES/engine.py" "$GHIDRA_HOME" "$JAVA_HOME" "$@"
fi

LS_CPATH="$GHIDRA_HOME/support/LaunchSupport.jar"

VMARGS=()
while IFS=$'\r\n' read -r line; do
	[ -n "$line" ] && VMARGS+=("$line")
done < <("$JAVA" -cp "$LS_CPATH" LaunchSupport "$GHIDRA_HOME" -vmargs)

MAXMEM="${GHIDRA_MAXMEM}"
[ -n "$MAXMEM" ] && VMARGS+=("-Xmx$MAXMEM")

exec "$JAVA" "${VMARGS[@]}" -Djava.awt.headless=true -Dapple.awt.UIElement=true \
	-cp "$GHIDRA_HOME/Ghidra/Framework/Utility/lib/Utility.jar" \
	ghidra.Ghidra studio.StudioServer "$@"
