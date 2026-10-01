package studio;

import static studio.Json.*;

import java.math.BigInteger;
import java.util.*;

import ghidra.app.emulator.EmulatorHelper;
import ghidra.program.model.address.*;
import ghidra.program.model.lang.Register;
import ghidra.program.model.listing.*;
import ghidra.util.task.TaskMonitor;

/** P-code emulator for one session (like Ghidra's Emulator / EmulatorHelper scripts). */
final class Emulation {
	private static final int MAX_RUN_STEPS = 2_000_000;
	private static final long SENTINEL = 0x0ffff0000L;

	private final Session s;
	private EmulatorHelper emu;
	private final Set<Address> breakpoints = new TreeSet<>();
	private long steps;
	private String status = "Detenido";

	Emulation(Session s) {
		this.s = s;
	}

	Map<String, Object> start(Address start) {
		stop();
		Program p = s.program;
		emu = new EmulatorHelper(p);
		emu.enableMemoryWriteTracking(true);
		Register pc = emu.getPCRegister();
		Register sp = emu.getStackPointerRegister();
		int ptrBits = p.getDefaultPointerSize() * 8;
		long stack = ptrBits >= 64 ? 0x00007ffff0000000L : 0x7ff00000L;
		if (sp != null) {
			emu.writeRegister(sp, stack);
		}
		// Return sentinel so "run" stops when the function returns.
		Address sentinel = p.getAddressFactory().getDefaultAddressSpace().getAddress(SENTINEL);
		Register lr = p.getLanguage().getRegister("lr");
		if (lr == null) {
			lr = p.getLanguage().getRegister("x30");
		}
		if (lr == null) {
			lr = p.getLanguage().getRegister("ra");
		}
		if (lr != null) {
			emu.writeRegister(lr, SENTINEL);
		}
		else if (sp != null) {
			int size = p.getDefaultPointerSize();
			emu.writeMemoryValue(p.getAddressFactory().getDefaultAddressSpace().getAddress(stack), size, SENTINEL);
		}
		emu.setBreakpoint(sentinel);
		breakpoints.add(sentinel);
		emu.writeRegister(pc, start.getOffset());
		ghidra.program.model.lang.Register ctxReg = p.getProgramContext().getBaseContextRegister();
		if (ctxReg != null) {
			ghidra.program.model.lang.RegisterValue ctx = p.getProgramContext().getRegisterValue(ctxReg, start);
			if (ctx == null) {
				ctx = p.getProgramContext().getDefaultValue(ctxReg, start);
			}
			if (ctx != null) {
				emu.setContextRegister(ctx);
			}
		}
		steps = 0;
		status = "Listo en " + start;
		return state();
	}

	private EmulatorHelper require() {
		if (emu == null) {
			throw new IllegalStateException("Inicia el emulador primero");
		}
		return emu;
	}

	Map<String, Object> step(int count) throws Exception {
		EmulatorHelper e = require();
		for (int i = 0; i < Math.max(1, count); i++) {
			if (!e.step(TaskMonitor.DUMMY)) {
				status = "Error: " + e.getLastError();
				return state();
			}
			steps++;
			if (breakpoints.contains(e.getExecutionAddress()) && i < count - 1) {
				status = "Punto de ruptura en " + e.getExecutionAddress();
				return state();
			}
		}
		status = "Paso " + steps;
		return state();
	}

	Map<String, Object> run() throws Exception {
		EmulatorHelper e = require();
		long limit = steps + MAX_RUN_STEPS;
		// Step off a breakpoint we're sitting on.
		if (breakpoints.contains(e.getExecutionAddress())) {
			if (!e.step(TaskMonitor.DUMMY)) {
				status = "Error: " + e.getLastError();
				return state();
			}
			steps++;
		}
		while (steps < limit) {
			Address pc = e.getExecutionAddress();
			if (breakpoints.contains(pc)) {
				status = pc.getOffset() == SENTINEL ? "La función ha retornado" : "Punto de ruptura en " + pc;
				return state();
			}
			if (!e.step(TaskMonitor.DUMMY)) {
				status = "Error: " + e.getLastError();
				return state();
			}
			steps++;
		}
		status = "Límite de " + MAX_RUN_STEPS + " pasos alcanzado";
		return state();
	}

	Map<String, Object> setRegister(String name, String value) {
		EmulatorHelper e = require();
		e.writeRegister(name, parseNumber(value));
		return state();
	}

	Map<String, Object> writeMemory(Address a, String hexText) {
		require().writeMemory(a, parseHex(hexText));
		return state();
	}

	Map<String, Object> readMemory(Address a, int length) {
		byte[] bytes = require().readMemory(a, Math.max(1, Math.min(length, 4096)));
		List<Integer> list = new ArrayList<>();
		for (byte b : bytes) {
			list.add(b & 0xff);
		}
		return map("start", str(a), "bytes", list);
	}

	Map<String, Object> breakpoint(Address a, boolean on) {
		if (on) {
			breakpoints.add(a);
			if (emu != null) {
				emu.setBreakpoint(a);
			}
		}
		else {
			breakpoints.remove(a);
			if (emu != null) {
				emu.clearBreakpoint(a);
			}
		}
		return emu != null ? state() : map("breakpoints", bpList());
	}

	void stop() {
		if (emu != null) {
			emu.dispose();
			emu = null;
		}
		status = "Detenido";
	}

	private List<String> bpList() {
		List<String> list = new ArrayList<>();
		for (Address a : breakpoints) {
			if (a.getOffset() != SENTINEL) {
				list.add(str(a));
			}
		}
		return list;
	}

	Map<String, Object> state() {
		Map<String, Object> m = new LinkedHashMap<>();
		m.put("running", emu != null);
		m.put("status", Msg.t(status));
		m.put("steps", steps);
		m.put("breakpoints", bpList());
		if (emu == null) {
			return m;
		}
		Address pc = emu.getExecutionAddress();
		m.put("pc", str(pc));
		Function f = s.program.getFunctionManager().getFunctionContaining(pc);
		m.put("function", f != null ? f.getName(true) : null);
		Instruction ins = s.program.getListing().getInstructionAt(pc);
		m.put("instruction", ins != null ? ins.toString() : null);

		// General-purpose registers first (pc, sp, x0..x30 / rax.. / r0..), then flags, then the rest.
		int ptrBits = s.program.getDefaultPointerSize() * 8;
		List<Register> candidates = new ArrayList<>();
		for (Register r : s.program.getLanguage().getRegisters()) {
			if (r.isBaseRegister() && !r.isHidden() && !r.isProcessorContext() && r.getBitLength() <= 128) {
				candidates.add(r);
			}
		}
		candidates.sort(Comparator.comparingInt((Register r) -> regRank(r, ptrBits))
				.thenComparingInt(Emulation::regNumber).thenComparing(Register::getName));
		List<Map<String, Object>> regs = new ArrayList<>();
		for (Register r : candidates) {
			if (regRank(r, ptrBits) > 3 || regs.size() >= 72) {
				break;
			}
			BigInteger v = emu.readRegister(r);
			regs.add(map("name", r.getName(), "value", "0x" + v.toString(16), "bits", r.getBitLength()));
		}
		m.put("registers", regs);

		List<Map<String, Object>> writes = new ArrayList<>();
		AddressSetView set = emu.getTrackedMemoryWriteSet();
		for (AddressRange r : set) {
			if (writes.size() >= 200) {
				break;
			}
			if (!r.getAddressSpace().isMemorySpace() || r.getAddressSpace().isUniqueSpace()) {
				continue;
			}
			try {
				int len = (int) Math.min(r.getLength(), 32);
				byte[] bytes = emu.readMemory(r.getMinAddress(), len);
				writes.add(map("address", str(r.getMinAddress()), "length", r.getLength(), "bytes", hex(bytes, 32)));
			}
			catch (Exception ignored) {
				// unreadable range
			}
		}
		m.put("writes", writes);
		return m;
	}

	private static final Set<String> X86 = Set.of("rax", "rbx", "rcx", "rdx", "rsi", "rdi", "rbp", "rsp", "rip",
		"eax", "ebx", "ecx", "edx", "esi", "edi", "ebp", "esp", "eip");

	private int regRank(Register r, int ptrBits) {
		String n = r.getName().toLowerCase();
		if (r == emu.getPCRegister() || r == emu.getStackPointerRegister() || n.equals("lr") || n.equals("fp")) {
			return 0;
		}
		if (X86.contains(n) || n.matches("(x|r|a|s|t|v)\\d+") && r.getBitLength() == ptrBits) {
			return 1;
		}
		if (n.equals("nzcv") || n.equals("cpsr") || n.equals("eflags") || n.equals("rflags") || n.matches("[nzcv]f?")
				|| n.matches("[czsoapd]f")) {
			return 2;
		}
		if (r.getBitLength() == ptrBits && !n.contains("_") && n.length() <= 4) {
			return 3;
		}
		return 9;
	}

	private static int regNumber(Register r) {
		String digits = r.getName().replaceAll("\\D", "");
		return digits.isEmpty() || digits.length() > 3 ? 999 : Integer.parseInt(digits);
	}

	static BigInteger parseNumber(String text) {
		String t = text.trim().toLowerCase().replace("_", "");
		boolean neg = t.startsWith("-");
		if (neg) {
			t = t.substring(1);
		}
		BigInteger v = t.startsWith("0x") ? new BigInteger(t.substring(2), 16)
				: t.matches("[0-9]+") ? new BigInteger(t) : new BigInteger(t, 16);
		return neg ? v.negate() : v;
	}
}
