// Native Mach-O entry point for Ghidra.app.
// Resolves the bundle location and exec()s the launcher script, keeping the
// same PID so macOS attributes the JVM window to this bundle (single Dock icon).
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <libgen.h>

int main(int argc, char *argv[]) {
    char raw[PATH_MAX];
    uint32_t size = sizeof(raw);
    if (_NSGetExecutablePath(raw, &size) != 0) {
        fprintf(stderr, "Ghidra: executable path too long\n");
        return 1;
    }

    char exe[PATH_MAX];
    if (!realpath(raw, exe)) {
        perror("Ghidra: realpath");
        return 1;
    }

    // exe = .../Ghidra.app/Contents/MacOS/Ghidra
    char script[PATH_MAX];
    snprintf(script, sizeof(script), "%s/../Resources/launcher.sh", dirname(exe));

    char **args = calloc((size_t)argc + 2, sizeof(char *));
    args[0] = "/bin/bash";
    args[1] = script;
    for (int i = 1; i < argc; i++) {
        args[i + 1] = argv[i];
    }

    execv("/bin/bash", args);
    perror("Ghidra: execv");
    return 1;
}
