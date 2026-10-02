package studio;

import static studio.Json.*;

import java.math.BigInteger;
import java.util.*;

import ghidra.app.emulator.EmulatorHelper;
import ghidra.pcode.emu.*;
import ghidra.pcode.exec.PcodeExecutorStatePiece;
import ghidra.pcode.exec.PcodeExecutorStatePiece.Reason;
import ghidra.pcode.exec.PcodeFrame;
import ghidra.pcode.utils.Utils;
import ghidra.program.model.address.*;
import ghidra.program.model.lang.Register;
import ghidra.program.model.lang.RegisterValue;
import ghidra.program.model.pcode.PcodeOp;
import ghidra.program.model.pcode.Varnode;
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
	private boolean skipExternal = true;
	private final Deque<String> log = new ArrayDeque<>();

	/** P-code stepping: a p-code machine that runs one instruction of the emulator, operation by operation. */
	private PcodeThread<byte[]> pthread;
	private Address pcodeAt;
	private final Map<Address, byte[]> pcodeWrites = new LinkedHashMap<>();
	/** Watched expressions and the other threads (register sets that share the memory). */
	private final List<String> watches = new ArrayList<>();
	private final List<Map<Register, BigInteger>> threads = new ArrayList<>();
	private int currentThread;

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
		log.clear();
		status = "Listo en " + start;
		return state();
	}

	/**
	 * Starts the emulator from a real machine state (the debugger's): registers by name and chunks of
	 * memory, so the emulation continues from where the process is stopped.
	 */
	Map<String, Object> startFrom(Address start, Map<String, String> registers, List<String[]> memory) {
		start(start);
		EmulatorHelper e = emu;
		Program p = s.program;
		// the debugger's stack and return address are real: no sentinel
		e.clearBreakpoint(p.getAddressFactory().getDefaultAddressSpace().getAddress(SENTINEL));
		breakpoints.clear();
		Register pc = e.getPCRegister();
		int set = 0;
		for (Map.Entry<String, String> entry : registers.entrySet()) {
			Register r = register(p, entry.getKey());
			if (r == null || r.equals(pc) || r.isProcessorContext()) {
				continue;
			}
			try {
				e.writeRegister(r, parseNumber(entry.getValue()));
				set++;
			}
			catch (Exception ex) {
				// a register the emulator cannot hold (wrong size, hidden): leave it
			}
		}
		int bytes = 0;
		for (String[] chunk : memory) {
			try {
				byte[] data = parseHex(chunk[1]);
				e.writeMemory(p.getAddressFactory().getDefaultAddressSpace().getAddress(parseNumber(chunk[0]).longValue()),
					data);
				bytes += data.length;
			}
			catch (Exception ex) {
				// outside the address space
			}
		}
		log.clear();
		status = "Listo en " + start;
		log.add(Msg.t("Estado del depurador") + ": " + set + " reg, " + bytes + " bytes");
		return state();
	}

	/** Finds a register by the name a debugger uses for it (case, and the usual aliases). */
	private static Register register(Program p, String name) {
		ghidra.program.model.lang.Language language = p.getLanguage();
		for (String candidate : new String[] { name, name.toUpperCase(), name.toLowerCase() }) {
			Register r = language.getRegister(candidate);
			if (r != null) {
				return r;
			}
		}
		switch (name.toLowerCase()) {
			case "fp": return language.getRegister("x29");
			case "lr": return language.getRegister("x30");
			case "rflags": return language.getRegister("rflags");
			default: return null;
		}
	}

	private EmulatorHelper require() {
		if (emu == null) {
			throw new IllegalStateException("Inicia el emulador primero");
		}
		return emu;
	}

	void setSkipExternal(boolean on) {
		skipExternal = on;
	}

	/**
	 * If the PC sits on an imported function (external thunk), returns to the caller instead of
	 * emulating library code that isn't there. Returns true when a call was skipped.
	 */
	private boolean skipExternalCall(EmulatorHelper e) throws Exception {
		if (!skipExternal) {
			return false;
		}
		Address pc = e.getExecutionAddress();
		Function f = s.program.getFunctionManager().getFunctionAt(pc);
		boolean external = pc.isExternalAddress() || !s.program.getMemory().contains(pc) && pc.getOffset() != SENTINEL
				|| (f != null && (f.isExternal() || (f.isThunk() && f.getThunkedFunction(true) != null
						&& f.getThunkedFunction(true).isExternal())));
		if (!external) {
			return false;
		}
		Register pcReg = e.getPCRegister();
		Register lr = s.program.getLanguage().getRegister("lr");
		if (lr == null) {
			lr = s.program.getLanguage().getRegister("x30");
		}
		if (lr == null) {
			lr = s.program.getLanguage().getRegister("ra");
		}
		if (lr != null) {
			e.writeRegister(pcReg, e.readRegister(lr));
		}
		else {
			Register sp = e.getStackPointerRegister();
			int size = s.program.getDefaultPointerSize();
			BigInteger ret = e.readStackValue(0, size, false);
			e.writeRegister(sp, e.readRegister(sp).add(BigInteger.valueOf(size)));
			e.writeRegister(pcReg, ret);
		}
		log.addLast((f != null ? f.getName() : str(pc)) + "()");
		while (log.size() > 60) {
			log.removeFirst();
		}
		return true;
	}

	// ---------------------------------------------------------------- p-code stepping

	private List<Register> baseRegisters() {
		List<Register> out = new ArrayList<>();
		for (Register r : s.program.getLanguage().getRegisters()) {
			if (r.isBaseRegister() && !r.isProcessorContext()) {
				out.add(r);
			}
		}
		return out;
	}

	private void beginPcode(EmulatorHelper e, Address pc) {
		boolean big = s.program.getLanguage().isBigEndian();
		pcodeWrites.clear();
		PcodeEmulator machine = new PcodeEmulator(s.program.getLanguage(), new PcodeEmulationCallbacks<byte[]>() {
			@Override
			@SuppressWarnings("unchecked")
			public <A, U> AddressSetView readUninitialized(PcodeThread<byte[]> thread, PcodeExecutorStatePiece<A, U> piece,
					AddressSetView set, Reason reason) {
				// memory the p-code machine has not seen yet comes from the emulator
				AddressSet left = new AddressSet();
				for (AddressRange r : set) {
					if (!r.getAddressSpace().isMemorySpace() || r.getLength() > (1 << 20)) {
						left.add(r);
						continue;
					}
					try {
						byte[] data = e.readMemory(r.getMinAddress(), (int) r.getLength());
						piece.setVarInternal(r.getAddressSpace(), r.getMinAddress().getOffset(), data.length, (U) data);
					}
					catch (Exception ex) {
						left.add(r);
					}
				}
				return left;
			}

			@Override
			public <A, U> void dataWritten(PcodeThread<byte[]> thread, PcodeExecutorStatePiece<A, U> piece, Address address,
					int length, U value) {
				if (address.getAddressSpace().isMemorySpace() && value instanceof byte[] bytes) {
					pcodeWrites.put(address, bytes.clone());
				}
			}
		});
		pthread = machine.newThread();
		for (Register r : baseRegisters()) {
			try {
				pthread.getState().setVar(r, Utils.bigIntegerToBytes(e.readRegister(r), r.getNumBytes(), big));
			}
			catch (Exception ex) {
				// a register the emulator does not keep
			}
		}
		pthread.overrideCounter(pc);
		RegisterValue ctx = e.getContextRegister();
		if (ctx != null) {
			pthread.overrideContext(ctx);
		}
		else {
			pthread.overrideContextWithDefault();
		}
		pcodeAt = pc;
	}

	/** Copies what the instruction did (registers, memory, program counter) back into the emulator. */
	private void commitPcode(EmulatorHelper e) {
		boolean big = s.program.getLanguage().isBigEndian();
		for (Register r : baseRegisters()) {
			try {
				byte[] v = pthread.getState().getVar(r, Reason.INSPECT);
				e.writeRegister(r, Utils.bytesToBigInteger(v, v.length, big, false));
			}
			catch (Exception ex) {
				// not readable: left as it was
			}
		}
		for (Map.Entry<Address, byte[]> w : pcodeWrites.entrySet()) {
			e.writeMemory(w.getKey(), w.getValue());
		}
		e.writeRegister(e.getPCRegister(), pthread.getCounter().getOffset());
		RegisterValue ctx = pthread.getContext();
		if (ctx != null) {
			e.setContextRegister(ctx);
		}
		pthread = null;
		pcodeAt = null;
		pcodeWrites.clear();
	}

	/** Runs one p-code operation of the instruction at the program counter. */
	Map<String, Object> pcodeStep(int count) throws Exception {
		EmulatorHelper e = require();
		for (int i = 0; i < Math.max(1, count); i++) {
			Address pc = e.getExecutionAddress();
			if (pc.getOffset() == SENTINEL) {
				status = "La función ha retornado";
				break;
			}
			if (pthread == null || !pc.equals(pcodeAt)) {
				beginPcode(e, pc);
			}
			try {
				pthread.stepPcodeOp();
				PcodeFrame frame = pthread.getFrame();
				if (frame != null && frame.isFinished()) {
					// the instruction is done: move on and hand the result to the emulator
					pthread.stepPcodeOp();
					commitPcode(e);
					steps++;
					status = "Paso " + steps;
				}
				else if (frame != null) {
					status = "P-code " + frame.index() + " de " + frame.getCode().size();
				}
			}
			catch (Exception ex) {
				status = "Error: " + (ex.getMessage() == null ? ex.getClass().getSimpleName() : ex.getMessage());
				pthread = null;
				pcodeAt = null;
				break;
			}
		}
		return state();
	}

	/** Leaves the instruction half done as if it had not started (its p-code effects are discarded). */
	private void dropPcode() {
		pthread = null;
		pcodeAt = null;
		pcodeWrites.clear();
	}

	private String describe(Varnode v) {
		if (v == null) {
			return "";
		}
		if (v.isConstant()) {
			return "0x" + Long.toHexString(v.getOffset());
		}
		if (v.isRegister()) {
			Register r = s.program.getLanguage().getRegister(v.getAddress(), v.getSize());
			if (r != null) {
				return r.getName();
			}
		}
		if (v.isUnique()) {
			return "$U" + Long.toHexString(v.getOffset()) + ":" + v.getSize();
		}
		return v.getAddress().toString() + ":" + v.getSize();
	}

	private Map<String, Object> pcodeState() {
		Instruction ins = s.program.getListing().getInstructionAt(emu.getExecutionAddress());
		List<String> ops = new ArrayList<>();
		int index = -1;
		PcodeOp[] code = null;
		PcodeFrame frame = pthread != null ? pthread.getFrame() : null;
		if (frame != null) {
			code = frame.copyCode();
			index = frame.index();
		}
		else if (ins != null) {
			code = ins.getPcode();
		}
		if (code != null) {
			for (PcodeOp op : code) {
				StringBuilder sb = new StringBuilder();
				if (op.getOutput() != null) {
					sb.append(describe(op.getOutput())).append(" = ");
				}
				sb.append(op.getMnemonic());
				for (int i = 0; i < op.getNumInputs(); i++) {
					sb.append(i == 0 ? " " : ", ").append(describe(op.getInput(i)));
				}
				ops.add(sb.toString());
			}
		}
		// values of the temporaries of the frame, once computed
		List<Map<String, Object>> uniques = new ArrayList<>();
		if (frame != null && code != null) {
			Set<String> seen = new HashSet<>();
			for (int i = 0; i < Math.min(index, code.length); i++) {
				Varnode out = code[i].getOutput();
				if (out == null || !out.isUnique() || !seen.add(describe(out))) {
					continue;
				}
				try {
					byte[] v = pthread.getState().getVar(out, Reason.INSPECT);
					uniques.add(map("name", describe(out), "value", "0x" + Utils
							.bytesToBigInteger(v, v.length, s.program.getLanguage().isBigEndian(), false).toString(16)));
				}
				catch (Exception ex) {
					// not kept
				}
			}
		}
		return map("ops", ops, "index", index, "active", frame != null, "uniques", uniques);
	}

	// ---------------------------------------------------------------- watches

	Map<String, Object> setWatches(List<String> expressions) {
		watches.clear();
		watches.addAll(expressions);
		return state();
	}

	/**
	 * Registers, numbers, + - * and parentheses, and *expr (or *:N expr) to read N bytes of memory
	 * (the pointer size by default).
	 */
	private BigInteger evaluate(String text) {
		return new Object() {
			int pos;
			final String t = text;

			void skip() {
				while (pos < t.length() && Character.isWhitespace(t.charAt(pos))) {
					pos++;
				}
			}

			BigInteger sum() {
				BigInteger v = product();
				for (skip(); pos < t.length() && (t.charAt(pos) == '+' || t.charAt(pos) == '-'); skip()) {
					char op = t.charAt(pos++);
					BigInteger r = product();
					v = op == '+' ? v.add(r) : v.subtract(r);
				}
				return v;
			}

			BigInteger product() {
				BigInteger v = unary();
				for (skip(); pos < t.length() && t.charAt(pos) == '*'; skip()) {
					pos++;
					v = v.multiply(unary());
				}
				return v;
			}

			BigInteger unary() {
				skip();
				if (pos < t.length() && t.charAt(pos) == '*') {
					pos++;
					int size = s.program.getDefaultPointerSize();
					if (pos < t.length() && t.charAt(pos) == ':') {
						int start = ++pos;
						while (pos < t.length() && Character.isDigit(t.charAt(pos))) {
							pos++;
						}
						size = Integer.parseInt(t.substring(start, pos));
					}
					BigInteger address = unary();
					Address a = s.program.getAddressFactory().getDefaultAddressSpace().getAddress(address.longValue());
					byte[] bytes = emu.readMemory(a, Math.max(1, Math.min(size, 16)));
					return Utils.bytesToBigInteger(bytes, bytes.length, s.program.getLanguage().isBigEndian(), false);
				}
				if (pos < t.length() && t.charAt(pos) == '(') {
					pos++;
					BigInteger v = sum();
					skip();
					if (pos < t.length() && t.charAt(pos) == ')') {
						pos++;
					}
					return v;
				}
				int start = pos;
				while (pos < t.length() && (Character.isLetterOrDigit(t.charAt(pos)) || t.charAt(pos) == '_')) {
					pos++;
				}
				String word = t.substring(start, pos);
				if (word.isEmpty()) {
					throw new IllegalArgumentException("Expresión inválida");
				}
				Register r = register(s.program, word);
				if (r != null) {
					return emu.readRegister(r);
				}
				return parseNumber(word);
			}

			BigInteger all() {
				BigInteger v = sum();
				skip();
				if (pos < t.length()) {
					throw new IllegalArgumentException("Expresión inválida");
				}
				return v;
			}
		}.all();
	}

	// ---------------------------------------------------------------- threads

	private Map<Register, BigInteger> saveRegisters() {
		Map<Register, BigInteger> out = new LinkedHashMap<>();
		for (Register r : baseRegisters()) {
			try {
				out.put(r, emu.readRegister(r));
			}
			catch (Exception e) {
				// not kept by the emulator
			}
		}
		return out;
	}

	/** A new thread: its own registers and stack, the same memory. It starts at the given address. */
	Map<String, Object> newThread(Address start) {
		EmulatorHelper e = require();
		dropPcode();
		if (threads.isEmpty()) {
			threads.add(saveRegisters());
			currentThread = 0;
		}
		else {
			threads.set(currentThread, saveRegisters());
		}
		int ptrBits = s.program.getDefaultPointerSize() * 8;
		long stack = (ptrBits >= 64 ? 0x00007ffff0000000L : 0x7ff00000L) - threads.size() * 0x100000L;
		Register sp = e.getStackPointerRegister();
		if (sp != null) {
			e.writeRegister(sp, stack);
		}
		e.writeRegister(e.getPCRegister(), start.getOffset());
		threads.add(saveRegisters());
		currentThread = threads.size() - 1;
		status = "Hilo " + currentThread + " en " + start;
		return state();
	}

	Map<String, Object> switchThread(int index) {
		EmulatorHelper e = require();
		if (index < 0 || index >= threads.size() || index == currentThread) {
			return state();
		}
		dropPcode();
		threads.set(currentThread, saveRegisters());
		for (Map.Entry<Register, BigInteger> r : threads.get(index).entrySet()) {
			e.writeRegister(r.getKey(), r.getValue());
		}
		currentThread = index;
		status = "Hilo " + index;
		return state();
	}

	Map<String, Object> step(int count) throws Exception {
		EmulatorHelper e = require();
		dropPcode();
		for (int i = 0; i < Math.max(1, count); i++) {
			if (skipExternalCall(e)) {
				steps++;
				continue;
			}
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
		dropPcode();
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
			if (skipExternalCall(e)) {
				steps++;
				continue;
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
		dropPcode();
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
		dropPcode();
		threads.clear();
		currentThread = 0;
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
		m.put("skipExternal", skipExternal);
		m.put("log", new ArrayList<>(log));
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
		m.put("pcode", pcodeState());
		List<Map<String, Object>> watched = new ArrayList<>();
		for (String w : watches) {
			String value;
			try {
				value = "0x" + evaluate(w).toString(16);
			}
			catch (Exception ex) {
				value = "—";
			}
			watched.add(map("expression", w, "value", value));
		}
		m.put("watches", watched);
		List<Map<String, Object>> threadList = new ArrayList<>();
		Register pcReg = emu.getPCRegister();
		for (int i = 0; i < threads.size(); i++) {
			BigInteger at = i == currentThread ? emu.readRegister(pcReg) : threads.get(i).get(pcReg);
			threadList.add(map("index", i, "pc", at == null ? "" : at.toString(16), "current", i == currentThread));
		}
		m.put("threads", threadList);
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
