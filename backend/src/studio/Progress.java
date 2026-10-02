package studio;

import static studio.Json.*;

import ghidra.util.task.TaskMonitorAdapter;

/** Task monitor that streams the progress of a long operation to the UI as "task" events, throttled. */
final class Progress extends TaskMonitorAdapter {
	private final StudioServer server;
	private final String task;
	private String message = "";
	private long max;
	private long value;
	private long last;

	Progress(StudioServer server, String task) {
		super(true);
		this.server = server;
		this.task = task;
	}

	@Override
	public void setMessage(String msg) {
		if (msg != null && !msg.isBlank()) {
			message = msg;
		}
		emit(false);
	}

	@Override
	public String getMessage() {
		return message;
	}

	@Override
	public void initialize(long maximum) {
		max = maximum;
		value = 0;
		emit(true);
	}

	@Override
	public void setMaximum(long maximum) {
		max = maximum;
	}

	@Override
	public long getMaximum() {
		return max;
	}

	@Override
	public void setProgress(long v) {
		value = v;
		emit(false);
	}

	@Override
	public void incrementProgress(long n) {
		value += n;
		emit(false);
	}

	@Override
	public long getProgress() {
		return value;
	}

	void done() {
		server.send(map("event", "task", "task", task, "message", null, "value", 1.0, "done", true));
	}

	private void emit(boolean force) {
		long now = System.currentTimeMillis();
		if (!force && now - last < 150) {
			return;
		}
		last = now;
		server.send(map("event", "task", "task", task, "message", Msg.t(message),
			"value", max > 0 ? Math.min(1.0, (double) value / max) : -1.0, "done", false));
	}
}
