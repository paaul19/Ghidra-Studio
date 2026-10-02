# Hosts the Ghidra Studio engine inside CPython (PyGhidra), so Python scripts and the
# interactive interpreter work. The JVM runs in this process through JPype.
#   engine.py <ghidra home> <jdk home> [engine args...]
import contextlib
import io
import os
import sys
import traceback

ghidra_home, java_home, args = sys.argv[1], sys.argv[2], sys.argv[3:]

# This script sits next to the "ghidra" folder: keep its directory off sys.path so that
# "import ghidra" resolves to the Java package and not to that folder.
here = os.path.dirname(os.path.abspath(__file__))
sys.path[:] = [p for p in sys.path if p and os.path.abspath(p) != here]

# The real stdout carries the JSON protocol: keep it aside and send everything else to the log.
protocol_fd = os.dup(1)
os.dup2(2, 1)
sys.stdout = sys.stderr

os.environ["JAVA_HOME_OVERRIDE"] = java_home
os.environ["JAVA_HOME"] = java_home

from pyghidra.launcher import HeadlessPyGhidraLauncher

launcher = HeadlessPyGhidraLauncher(verbose=True, install_dir=ghidra_home)
launcher.add_vmargs(
    "-Djava.awt.headless=true",
    "-Dapple.awt.UIElement=true",
    f"-Dstudio.protocol.fd={protocol_fd}",
    "-Dstudio.python=%d.%d.%d" % sys.version_info[:3],
)
if os.environ.get("GHIDRA_MAXMEM"):
    launcher.add_vmargs("-Xmx" + os.environ["GHIDRA_MAXMEM"])
launcher.start()

import jpype
from java.io import PrintWriter, StringWriter
from java.util.function import BiFunction
from ghidra.util.task import TaskMonitor
from pyghidra.script import PyGhidraScript

_console = None


def _complete(text):
    """Completions of the last name or attribute chain in text, like the classic interpreter's Tab."""
    import builtins
    import keyword
    import re
    m = re.search(r"[A-Za-z_][A-Za-z0-9_.]*$", text)
    if not m:
        return ""
    expr = m.group(0)
    scope = dict(_console) if _console is not None else {}
    out = []
    if "." in expr:
        base, _, prefix = expr.rpartition(".")
        try:
            # the console resolves currentProgram and the flat API on demand, so evaluate in it
            obj = eval(base, _console if _console is not None else scope)
        except BaseException:
            return ""
        for name in dir(obj):
            if name.startswith(prefix) and (prefix.startswith("_") or not name.startswith("_")):
                out.append(base + "." + name)
    else:
        api = ["currentProgram", "currentAddress", "currentLocation", "currentSelection", "currentHighlight", "monitor",
               "state", "getFunctionAt", "getFunctionContaining", "getSymbolAt", "toAddr", "getDataAt", "getInstructionAt",
               "createFunction", "createLabel", "setEOLComment", "getBytes", "getInt", "find", "findBytes", "println",
               "askString", "askInt", "askAddress", "getState", "getCurrentProgram", "getMonitor"]
        names = set(scope) | set(dir(builtins)) | set(keyword.kwlist) | set(api)
        out = [n for n in names if isinstance(n, str) and n.startswith(expr) and (expr.startswith("_") or not n.startswith("_"))]
    return "\n".join(sorted(out)[:200])


def _evaluate(state, source):
    """Interactive interpreter: runs source with the flat API in scope and returns what it printed."""
    global _console
    if source == "\x00reset":
        _console = None
        return ""
    if _console is None:
        import ghidra
        import java
        _console = PyGhidraScript()
        dict.__setitem__(_console, "ghidra", ghidra)
        dict.__setitem__(_console, "java", java)
    out = io.StringIO()
    java_out = StringWriter()
    writer = PrintWriter(java_out, True)
    if state is not None:
        _console.set(state, TaskMonitor.DUMMY, writer, writer)
    if source.startswith("\x00complete:"):
        return _complete(source[len("\x00complete:"):])

    def console_print(*objects, sep=" ", end="\n", file=None, flush=False):
        print(*objects, sep=sep, end=end, file=out if file is None else file, flush=flush)

    dict.__setitem__(_console, "print", console_print)
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
        try:
            try:
                code = compile(source, "<console>", "eval")
            except SyntaxError:
                code = None
            if code is not None:
                value = eval(code, _console)
                if value is not None:
                    dict.__setitem__(_console, "_", value)
                    out.write(repr(value) + "\n")
            else:
                exec(compile(source, "<console>", "exec"), _console)
        except SystemExit:
            pass
        except BaseException as e:
            # drop this function's own frame from the traceback
            tb = e.__traceback__.tb_next if e.__traceback__ else None
            traceback.print_exception(type(e), e, tb, file=out)
    writer.flush()
    return str(java_out.toString()) + out.getvalue()


# --- cancelling: remember which thread runs Python code so it can be interrupted from Java
import ctypes
import threading

_running = None


_original_run = PyGhidraScript.run


def _tracked_run(self, *args, **kwargs):
    """PyGhidraScript.run, remembering the thread so a running script can be interrupted."""
    global _running
    _running = threading.get_ident()
    try:
        return _original_run(self, *args, **kwargs)
    finally:
        _running = None


PyGhidraScript.run = _tracked_run


def _interrupt():
    """Raises KeyboardInterrupt in the Python code that is running (takes effect between bytecodes)."""
    thread = _running
    if thread is not None:
        ctypes.pythonapi.PyThreadState_SetAsyncExc(ctypes.c_ulong(thread), ctypes.py_object(KeyboardInterrupt))


def _evaluate_tracked(state, source):
    global _running
    _running = threading.get_ident()
    try:
        return _evaluate(state, source)
    finally:
        _running = None


from java.lang import Runnable

jpype.JClass("studio.Python").interrupter = Runnable @ _interrupt
jpype.JClass("studio.Python").evaluator = BiFunction @ _evaluate_tracked
jpype.JClass("studio.StudioServer").serve(args)
