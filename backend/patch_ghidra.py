#!/usr/bin/env python3
"""Generates patched copies of Ghidra classes that the engine needs fixed.

They are compiled into studio-server.jar, which lives in Ghidra/patch and therefore
takes precedence over the original classes.

  patch_ghidra.py <ghidra home> <output source dir>

VTAbstractReferenceProgramCorrelator: accumulateFunctionReferences() walks back through
references up to 30 levels deep without remembering where it has been, so data that
references other data in a cycle (Mach-O headers do) makes it take exponential time and
Auto Version Tracking never finishes. The patch remembers the shallowest depth at which
each address was explored; the resulting set of functions is exactly the same.
"""
import os
import sys
import zipfile

ghidra, out = sys.argv[1], sys.argv[2]

NAME = "ghidra/feature/vt/api/correlator/program/VTAbstractReferenceProgramCorrelator.java"
ZIP = os.path.join(ghidra, "Ghidra/Features/VersionTracking/lib/VersionTracking-src.zip")

HEAD = """	private void accumulateFunctionReferences(int depth, Set<Function> list, Program program,
			Address address) {

		if (depth >= MAX_DEPTH) {
			return;
		}
"""
NEW_HEAD = """	private void accumulateFunctionReferences(int depth, Set<Function> list, Program program,
			Address address) {
		accumulateFunctionReferences(depth, list, program, address, new HashMap<>());
	}

	private void accumulateFunctionReferences(int depth, Set<Function> list, Program program,
			Address address, Map<Address, Integer> seen) {

		if (depth >= MAX_DEPTH) {
			return;
		}

		// Ghidra Studio patch: an address already explored from this depth or a shallower one
		// cannot contribute anything new (avoids exponential time on reference cycles).
		Integer previous = seen.get(address);
		if (previous != null && previous <= depth) {
			return;
		}
		seen.put(address, depth);
"""

try:
    src = zipfile.ZipFile(ZIP).read(NAME).decode("utf-8")
except (OSError, KeyError) as e:
    sys.exit(f"patch_ghidra: cannot read {NAME}: {e}")

calls = 0
if HEAD in src:
    src = src.replace(HEAD, NEW_HEAD, 1)
    for arg in ("thunkAddress", "entryPoint", "fromAddress"):
        old = f"accumulateFunctionReferences(depth + 1, list, program, {arg});"
        if old in src:
            src = src.replace(old, f"accumulateFunctionReferences(depth + 1, list, program, {arg}, seen);")
            calls += 1
if calls != 3:
    # A different Ghidra version: leave the original class alone rather than guess.
    print("patch_ghidra: VTAbstractReferenceProgramCorrelator has changed, not patching", file=sys.stderr)
    sys.exit(0)

path = os.path.join(out, NAME)
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "w", encoding="utf-8") as f:
    f.write(src)
print("patch_ghidra: patched VTAbstractReferenceProgramCorrelator")
