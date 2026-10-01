#!/bin/bash
# Starts the headless Ghidra engine used by Ghidra Studio.
# stdin/stdout carry the JSON protocol; stderr is Ghidra's log.
#   engine.sh <projectDir>

RES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
GHIDRA_HOME="$RES/ghidra"
export JAVA_HOME="$RES/jdk"
JAVA="$JAVA_HOME/bin/java"
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
