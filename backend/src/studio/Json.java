package studio;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.LinkedHashMap;
import java.util.Map;

import com.google.gson.JsonElement;
import com.google.gson.JsonObject;

import ghidra.program.model.address.Address;

/** Small helpers shared by the engine modules. */
final class Json {
	private Json() {
	}

	static String str(Address a) {
		return a == null ? null : a.toString();
	}

	static String reqStr(JsonObject p, String k) {
		JsonElement e = p.get(k);
		if (e == null || e.isJsonNull()) {
			throw new IllegalArgumentException("Falta el parámetro «" + k + "»");
		}
		return e.getAsString();
	}

	static String optStr(JsonObject p, String k, String def) {
		JsonElement e = p.get(k);
		return e == null || e.isJsonNull() ? def : e.getAsString();
	}

	static boolean optBool(JsonObject p, String k, boolean def) {
		JsonElement e = p.get(k);
		return e == null || e.isJsonNull() ? def : e.getAsBoolean();
	}

	static int optInt(JsonObject p, String k, int def) {
		JsonElement e = p.get(k);
		return e == null || e.isJsonNull() ? def : e.getAsInt();
	}

	/** JSON has no NaN / Infinity. */
	static double num(double d) {
		return Double.isNaN(d) ? 0 : Double.isInfinite(d) ? (d > 0 ? 1e308 : -1e308) : d;
	}

	static Map<String, Object> map(Object... kv) {
		Map<String, Object> m = new LinkedHashMap<>();
		for (int i = 0; i + 1 < kv.length; i += 2) {
			m.put((String) kv[i], kv[i + 1]);
		}
		return m;
	}

	static String shortHash(String s) {
		try {
			byte[] d = MessageDigest.getInstance("SHA-1").digest(s.getBytes(StandardCharsets.UTF_8));
			return String.format("%02x%02x%02x%02x", d[0], d[1], d[2], d[3]);
		}
		catch (Exception e) {
			return Integer.toHexString(s.hashCode());
		}
	}

	static String safeName(String name) {
		String s = name.replaceAll("[^A-Za-z0-9._ -]", "_").trim();
		return s.isEmpty() ? "programa" : s;
	}

	static String hex(byte[] bytes, int max) {
		StringBuilder sb = new StringBuilder();
		for (int i = 0; i < Math.min(bytes.length, max); i++) {
			sb.append(String.format("%02x ", bytes[i] & 0xff));
		}
		if (bytes.length > max) {
			sb.append("…");
		}
		return sb.toString().trim();
	}

	static byte[] parseHex(String text) {
		String clean = text.replaceAll("(?i)0x", "").replaceAll("[^0-9A-Fa-f]", "");
		if (clean.isEmpty() || clean.length() % 2 != 0) {
			throw new IllegalArgumentException("Bytes hexadecimales inválidos: " + text);
		}
		byte[] out = new byte[clean.length() / 2];
		for (int i = 0; i < out.length; i++) {
			out[i] = (byte) Integer.parseInt(clean.substring(i * 2, i * 2 + 2), 16);
		}
		return out;
	}
}
