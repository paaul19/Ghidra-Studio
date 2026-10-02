package studio;

import static studio.Json.*;

import java.awt.Component;
import java.io.File;
import java.io.IOException;
import java.net.Authenticator;
import java.util.*;

import javax.security.auth.callback.*;

import ghidra.framework.client.*;
import ghidra.framework.data.CheckinHandler;
import ghidra.framework.model.*;
import ghidra.framework.remote.AnonymousCallback;
import ghidra.framework.remote.SSHSignatureCallback;
import ghidra.framework.remote.User;
import ghidra.framework.store.ItemCheckoutStatus;
import ghidra.framework.store.Version;
import ghidra.util.task.TaskMonitor;

/** Ghidra Server client (shared projects) and version control of project files. */
final class Repo {
	private Repo() {
	}

	// ---------------------------------------------------------------- authentication

	/** Answers the server's login callbacks with the credentials typed in the UI. */
	private static final class Auth implements ClientAuthenticator {
		volatile String user;
		volatile char[] password;
		/** A PKCS12/JKS keystore (PKI servers) or an SSH private key file. */
		volatile String keyFile;

		@Override
		public Authenticator getAuthenticator() {
			return new Authenticator() {
				@Override
				protected java.net.PasswordAuthentication getPasswordAuthentication() {
					return password != null ? new java.net.PasswordAuthentication(
						user != null ? user : ClientUtil.getUserName(), password) : null;
				}
			};
		}

		@Override
		public boolean processPasswordCallbacks(String title, String serverType, String serverName,
				boolean allowUserNameEntry, NameCallback nameCb, PasswordCallback passCb, ChoiceCallback choiceCb,
				AnonymousCallback anonymousCb, String loginError) {
			if (loginError != null) {
				// second round after a rejected password: give up instead of looping
				return false;
			}
			if (password == null) {
				if (anonymousCb != null) {
					anonymousCb.setAnonymousAccessRequested(true);
					return true;
				}
				return false;
			}
			if (nameCb != null && user != null && !user.isBlank()) {
				nameCb.setName(user);
			}
			if (choiceCb != null) {
				choiceCb.setSelectedIndex(0);
			}
			passCb.setPassword(password.clone());
			return true;
		}

		@Override
		public boolean promptForReconnect(Component parent, String message) {
			return true;
		}

		@Override
		public char[] getNewPassword(Component parent, String serverInfo, String username) {
			return null;
		}

		private boolean isKeystore() {
			String k = keyFile == null ? "" : keyFile.toLowerCase();
			return k.endsWith(".p12") || k.endsWith(".pfx") || k.endsWith(".pks") || k.endsWith(".jks");
		}

		@Override
		public boolean isSSHKeyAvailable() {
			return keyFile != null && !isKeystore();
		}

		@Override
		public boolean processSSHSignatureCallbacks(String serverName, NameCallback nameCb,
				SSHSignatureCallback sshCb) {
			if (!isSSHKeyAvailable()) {
				return false;
			}
			try {
				ghidra.framework.remote.security.SSHKeyManager.setProtectedKeyStorePasswordProvider(this::getKeyStorePassword);
				Object key = ghidra.framework.remote.security.SSHKeyManager.getSSHPrivateKey(new java.io.File(keyFile));
				sshCb.sign(key);
				if (nameCb != null && user != null && !user.isBlank()) {
					nameCb.setName(user);
				}
				return true;
			}
			catch (Exception e) {
				return false;
			}
		}

		@Override
		public char[] getKeyStorePassword(String keystorePath, boolean passwordError) {
			return passwordError || password == null ? null : password.clone();
		}
	}

	private static final Auth AUTH = new Auth();
	private static boolean installed;

	/** Uses a client certificate keystore (PKI) or an SSH private key for the next connections; empty clears it. */
	static synchronized void keyFile(String path) {
		AUTH.keyFile = path == null || path.isBlank() ? null : path;
		ghidra.net.ApplicationKeyManagerFactory.setKeyStorePasswordProvider(AUTH::getKeyStorePassword);
		if (AUTH.keyFile != null && AUTH.isKeystore()) {
			System.setProperty(ghidra.net.DefaultKeyManagerFactory.KEYSTORE_PATH_PROPERTY, AUTH.keyFile);
			ghidra.net.DefaultKeyManagerFactory.setDefaultKeyStore(AUTH.keyFile, false);
		}
		else {
			System.clearProperty(ghidra.net.DefaultKeyManagerFactory.KEYSTORE_PATH_PROPERTY);
			ghidra.net.DefaultKeyManagerFactory.setDefaultKeyStore(null, false);
		}
		ghidra.net.ApplicationKeyManagerFactory.clearKeyManagerCache();
	}

	static synchronized void credentials(String user, String password) {
		if (!installed) {
			ClientUtil.setClientAuthenticator(AUTH);
			installed = true;
		}
		if (user != null) {
			AUTH.user = user.isBlank() ? null : user;
		}
		if (password != null) {
			AUTH.password = password.isEmpty() ? null : password.toCharArray();
		}
	}

	private static RepositoryServerAdapter server(String host, int port) throws IOException {
		RepositoryServerAdapter rsa = ClientUtil.getRepositoryServer(host, port, true);
		if (rsa == null || !rsa.isConnected()) {
			Throwable cause = rsa != null ? rsa.getLastConnectError() : null;
			String detail = cause != null && cause.getMessage() != null ? cause.getMessage() : "";
			if (rsa != null) {
				ClientUtil.clearRepositoryAdapter(host, port);
			}
			throw new IOException("No se pudo conectar con el servidor" + (detail.isEmpty() ? "" : ": " + detail));
		}
		return rsa;
	}

	// ---------------------------------------------------------------- server

	static Map<String, Object> connect(String host, int port, String user, String password) throws Exception {
		credentials(user, password);
		ClientUtil.clearRepositoryAdapter(host, port);
		RepositoryServerAdapter rsa = server(host, port);
		List<String> users = new ArrayList<>();
		try {
			users.addAll(Arrays.asList(rsa.getAllUsers()));
		}
		catch (IOException e) {
			// anonymous or restricted users may not list the server's users
		}
		return map("connected", true, "host", host, "port", port, "user", rsa.getUser(),
			"readOnly", rsa.isReadOnly(), "repositories", Arrays.asList(rsa.getRepositoryNames()),
			"users", users, "systemUser", ClientUtil.getUserName());
	}

	/** Changes the password of the connected user (servers with password authentication). */
	static Object setPassword(String host, int port, String newPassword) throws Exception {
		RepositoryServerAdapter rsa = server(host, port);
		if (!rsa.canSetPassword()) {
			throw new IllegalStateException("Este servidor no permite cambiar la contraseña");
		}
		char[] hash = generic.hash.HashUtilities.getSaltedHash(generic.hash.HashUtilities.SHA256_ALGORITHM,
			newPassword.toCharArray());
		if (!rsa.setPassword(hash)) {
			throw new IllegalStateException("El servidor rechazó la nueva contraseña");
		}
		AUTH.password = newPassword.toCharArray();
		return true;
	}

	static Map<String, Object> createRepository(String host, int port, String name) throws Exception {
		RepositoryServerAdapter rsa = server(host, port);
		rsa.createRepository(name);
		return map("repositories", Arrays.asList(rsa.getRepositoryNames()));
	}

	/** Users of a repository with their access level. */
	static List<Map<String, Object>> repositoryUsers(String host, int port, String name) throws Exception {
		RepositoryAdapter repo = server(host, port).getRepository(name);
		repo.connect();
		List<Map<String, Object>> out = new ArrayList<>();
		for (User u : repo.getUserList()) {
			out.add(map("name", u.getName(), "access",
				u.isAdmin() ? "admin" : u.hasWritePermission() ? "write" : "read"));
		}
		return out;
	}

	static Object setRepositoryUser(String host, int port, String name, String user, String access)
			throws Exception {
		RepositoryAdapter repo = server(host, port).getRepository(name);
		repo.connect();
		List<User> users = new ArrayList<>();
		for (User u : repo.getUserList()) {
			if (!u.getName().equals(user)) {
				users.add(u);
			}
		}
		if (!"none".equals(access)) {
			users.add(new User(user, "admin".equals(access) ? User.ADMIN
					: "write".equals(access) ? User.WRITE : User.READ_ONLY));
		}
		repo.setUserList(users.toArray(new User[0]), repo.anonymousAccessAllowed());
		return repositoryUsers(host, port, name);
	}

	private static final class Manager extends ghidra.framework.project.DefaultProjectManager {
		Manager() {
			super();
		}
	}

	/** Creates a local project bound to a server repository; returns the path of its .gpr. */
	static String createSharedProject(String host, int port, String repository, String directory, String name)
			throws Exception {
		File dir = new File(directory);
		dir.mkdirs();
		if (new File(dir, name + ".gpr").exists()) {
			throw new IllegalArgumentException("Ya existe un proyecto «" + name + "» en esa carpeta");
		}
		RepositoryAdapter repo = server(host, port).getRepository(repository);
		repo.connect();
		ProjectLocator locator = new ProjectLocator(dir.getAbsolutePath(), name);
		Project created = new Manager().createProject(locator, repo, false);
		created.close();
		return locator.getMarkerFile().getAbsolutePath();
	}

	static Map<String, Object> status(Project project) {
		RepositoryAdapter repo = project.getRepository();
		if (repo == null) {
			return map("shared", false);
		}
		ServerInfo info = repo.getServerInfo();
		String user = null;
		String access = null;
		try {
			if (repo.isConnected()) {
				User u = repo.getUser();
				user = u.getName();
				access = u.isAdmin() ? "admin" : u.hasWritePermission() ? "write" : "read";
			}
		}
		catch (IOException e) {
			// not connected
		}
		return map("shared", true, "host", info.getServerName(), "port", info.getPortNumber(),
			"repository", repo.getName(), "connected", repo.isConnected(), "user", user, "access", access);
	}

	/** Reconnects the open shared project to its server. */
	static Map<String, Object> reconnect(Project project, String user, String password) throws Exception {
		RepositoryAdapter repo = project.getRepository();
		if (repo == null) {
			throw new IllegalStateException("El proyecto no es compartido");
		}
		credentials(user, password);
		repo.connect();
		return status(project);
	}

	// ---------------------------------------------------------------- version control

	private static String state(DomainFile f) {
		if (f.isHijacked()) {
			return "hijacked";
		}
		if (!f.isVersioned()) {
			return "private";
		}
		if (!f.isCheckedOut()) {
			return "versioned";
		}
		return f.modifiedSinceCheckout() || f.isChanged() ? "modified" : "checkedOut";
	}

	private static Map<String, Object> describe(StudioServer server, DomainFile f) {
		String who = null;
		if (f.isVersioned()) {
			try {
				List<String> names = new ArrayList<>();
				for (ItemCheckoutStatus s : f.getCheckouts()) {
					names.add(s.getUser());
				}
				who = String.join(", ", names);
			}
			catch (IOException e) {
				// server not reachable
			}
		}
		return map("path", f.getPathname(), "name", f.getName(), "contentType", f.getContentType(),
			"state", state(f), "versioned", f.isVersioned(), "checkedOut", f.isCheckedOut(),
			"exclusive", f.isCheckedOutExclusive(), "version", f.isVersioned() ? f.getVersion() : null,
			"latest", f.isVersioned() ? f.getLatestVersion() : null, "canCheckout", f.canCheckout(),
			"canCheckin", f.canCheckin(), "canMerge", f.canMerge(), "canAdd", f.canAddToRepository(),
			"checkedOutBy", who, "open", server.sessionFor(f.getPathname()) != null);
	}

	static List<Map<String, Object>> files(StudioServer server) {
		List<Map<String, Object>> out = new ArrayList<>();
		collect(server, server.project().getRootFolder(), out);
		out.sort(Comparator.comparing(o -> (String) o.get("path")));
		return out;
	}

	private static void collect(StudioServer server, DomainFolder folder, List<Map<String, Object>> out) {
		for (DomainFile f : folder.getFiles()) {
			out.add(describe(server, f));
		}
		for (DomainFolder sub : folder.getFolders()) {
			collect(server, sub, out);
		}
	}

	private static DomainFile file(StudioServer server, String path) {
		DomainFile f = server.project().getProjectData().getFile(path);
		if (f == null) {
			throw new IllegalArgumentException("No existe " + path);
		}
		return f;
	}

	private static void requireClosed(StudioServer server, String path) {
		if (server.sessionFor(path) != null) {
			throw new IllegalStateException("Cierra el programa antes de cambiar su estado de versiones");
		}
	}

	static Object add(StudioServer server, String path, String comment, boolean keepCheckedOut,
			TaskMonitor monitor) throws Exception {
		requireClosed(server, path);
		DomainFile f = file(server, path);
		f.addToVersionControl(comment, keepCheckedOut, monitor);
		return describe(server, f);
	}

	static Object checkout(StudioServer server, String path, boolean exclusive, TaskMonitor monitor)
			throws Exception {
		requireClosed(server, path);
		DomainFile f = file(server, path);
		if (!f.checkout(exclusive, monitor)) {
			throw new IllegalStateException("No se pudo hacer el check-out: otro usuario lo tiene en exclusiva");
		}
		return describe(server, f);
	}

	static Object checkin(StudioServer server, String path, String comment, boolean keepCheckedOut,
			TaskMonitor monitor) throws Exception {
		Session open = server.sessionFor(path);
		if (open != null) {
			open.save();
		}
		DomainFile f = file(server, path);
		try {
			doCheckin(f, comment, keepCheckedOut || open != null, monitor);
		}
		catch (IOException e) {
			throw needsMerge(e);
		}
		if (open != null) {
			open.invalidate();
		}
		return describe(server, f);
	}

	private static void doCheckin(DomainFile f, String comment, boolean keep, TaskMonitor monitor)
			throws Exception {
		f.checkin(new CheckinHandler() {
			@Override
			public String getComment() {
				return comment;
			}

			@Override
			public boolean keepCheckedOut() {
				return keep;
			}

			@Override
			public boolean createKeepFile() {
				return false;
			}
		}, monitor);
	}

	static Object undoCheckout(StudioServer server, String path, boolean keepCopy) throws Exception {
		requireClosed(server, path);
		DomainFile f = file(server, path);
		f.undoCheckout(keepCopy);
		return describe(server, f);
	}

	/** Brings a checked-out file up to the latest version (merges other users' changes). */
	static Object update(StudioServer server, String path, TaskMonitor monitor) throws Exception {
		requireClosed(server, path);
		DomainFile f = file(server, path);
		if (!f.isCheckedOut() || f.getVersion() >= f.getLatestVersion()) {
			return describe(server, f);
		}
		if (!f.modifiedSinceCheckout()) {
			// Nothing of ours to merge: take the latest version by checking out again.
			boolean exclusive = f.isCheckedOutExclusive();
			f.undoCheckout(false);
			f.checkout(exclusive, monitor);
			return describe(server, f);
		}
		try {
			f.merge(true, monitor);
		}
		catch (IOException e) {
			throw needsMerge(e);
		}
		return describe(server, f);
	}

	/** Ghidra only merges concurrent edits through its GUI merge tool. */
	private static IOException needsMerge(IOException e) {
		String m = String.valueOf(e.getMessage());
		if (m.contains("headless")) {
			return new IOException("Otro usuario ha subido una versión nueva y tú también has modificado el " +
				"archivo: esa fusión solo se puede hacer en Ghidra clásico");
		}
		return e;
	}

	/** Who has the file checked out (all users), with the id needed to terminate a checkout. */
	static List<Map<String, Object>> checkouts(StudioServer server, String path) throws Exception {
		List<Map<String, Object>> out = new ArrayList<>();
		ItemCheckoutStatus[] list = file(server, path).getCheckouts();
		if (list != null) {
			for (ItemCheckoutStatus c : list) {
				out.add(map("id", c.getCheckoutId(), "user", c.getUser(), "version", c.getCheckoutVersion(),
					"date", c.getCheckoutTime(), "project", c.getProjectPath(),
					"exclusive", c.getCheckoutType() != ghidra.framework.store.CheckoutType.NORMAL));
			}
		}
		return out;
	}

	/** Ends somebody's checkout (repository administrators only); their unsent changes become a private copy. */
	static Object terminateCheckout(StudioServer server, String path, long id) throws Exception {
		file(server, path).terminateCheckout(id);
		return checkouts(server, path);
	}

	/** Turns the open local project into a shared one bound to a server repository. */
	static void convertToShared(Project project, String host, int port, String repository, TaskMonitor monitor)
			throws Exception {
		if (project.getRepository() != null) {
			throw new IllegalStateException("El proyecto ya es compartido");
		}
		RepositoryAdapter repo = server(host, port).getRepository(repository);
		repo.connect();
		if (!(project.getProjectData() instanceof ghidra.framework.data.DefaultProjectData data)) {
			throw new IllegalStateException("El proyecto no admite la conversión");
		}
		data.convertProjectToShared(repo, monitor);
	}

	static List<Map<String, Object>> history(StudioServer server, String path) throws Exception {
		List<Map<String, Object>> out = new ArrayList<>();
		Version[] versions = file(server, path).getVersionHistory();
		if (versions != null) {
			for (Version v : versions) {
				out.add(map("version", v.getVersion(), "user", v.getUser(), "comment", v.getComment(),
					"date", v.getCreateTime()));
			}
		}
		Collections.reverse(out);
		return out;
	}

	/** Copies an old version of a file into the project as a private file. */
	static Object extractVersion(StudioServer server, String path, int version, TaskMonitor monitor)
			throws Exception {
		DomainFile f = file(server, path);
		DomainFile copy = f.copyVersionTo(version, f.getParent(), monitor);
		return map("path", copy.getPathname(), "name", copy.getName());
	}
}
