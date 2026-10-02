#!/bin/bash
# Ghidra.app launcher: runs the bundled Ghidra with the bundled JDK.
# Equivalent to ghidraRun / support/launch.sh, but exec()s the JVM in-process.
#
# Environment overrides (same as upstream ghidraRun):
#   GHIDRA_MAXMEM / GHIDRA_GUI_MAXMEM          e.g. 8G
#   GHIDRA_JAVA_OPTIONS / GHIDRA_GUI_JAVA_OPTIONS
#   GHIDRA_MAIN_CLASS                          class to launch instead of ghidra.GhidraRun

RES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
GHIDRA_HOME="$RES/ghidra"
export JAVA_HOME="$RES/jdk"
JAVA="$JAVA_HOME/bin/java"
LS_CPATH="$GHIDRA_HOME/support/LaunchSupport.jar"

LOG_DIR="$HOME/Library/Logs/Ghidra"
mkdir -p "$LOG_DIR"
exec >>"$LOG_DIR/launcher.log" 2>&1
echo "=== $(date) Ghidra.app launch ==="

# Environment variables from support/launch.properties (only if unset)
while IFS=$'\r\n' read -r line; do
	[ -z "$line" ] && continue
	IFS='=' read -r key value <<< "$line"
	[ -z "${!key}" ] && export "$key=$value"
done < <("$JAVA" -cp "$LS_CPATH" LaunchSupport "$GHIDRA_HOME" -envvars)

# VM arguments from support/launch.properties
VMARGS=()
while IFS=$'\r\n' read -r line; do
	[ -n "$line" ] && VMARGS+=("$line")
done < <("$JAVA" -cp "$LS_CPATH" LaunchSupport "$GHIDRA_HOME" -vmargs)

VMARGS+=("-Xdock:name=Ghidra" "-Xdock:icon=$RES/Ghidra.icns")

MAXMEM="${GHIDRA_GUI_MAXMEM:-$GHIDRA_MAXMEM}"
[ -n "$MAXMEM" ] && VMARGS+=("-Xmx$MAXMEM")

read -ra EXTRA <<< "${GHIDRA_JAVA_OPTIONS} ${GHIDRA_GUI_JAVA_OPTIONS}"

# Drop legacy Finder process-serial-number arguments
ARGS=()
for a in "$@"; do
	[[ "$a" == -psn_* ]] || ARGS+=("$a")
done

exec "$JAVA" "${VMARGS[@]}" "${EXTRA[@]}" \
	-cp "$GHIDRA_HOME/Ghidra/Framework/Utility/lib/Utility.jar" \
	ghidra.Ghidra "${GHIDRA_MAIN_CLASS:-ghidra.GhidraRun}" "${ARGS[@]}"
