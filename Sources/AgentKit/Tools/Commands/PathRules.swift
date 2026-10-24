import Foundation

/// Where a path sits relative to the places Glide may freely change. Shared by the shell
/// checker (`CommandSafety`) and the file tools so a write is judged the same way whether the
/// model uses `fs.write` or `echo … > file`.
///
/// Every comparison is case-insensitive because the default APFS volume is: `/USERS/me` and
/// `~/library/keychains` name the same folders as their properly cased spellings, and a
/// case-sensitive check would let them slip through.
public enum PathRules {
    public enum WriteZone: Sendable, Equatable {
        /// `/dev/null`, `/dev/stdout`…: writing there changes nothing.
        case discard
        /// Inside the home folder or a temporary folder.
        case allowed
        /// Anywhere else (system folders, other users, external volumes).
        case outside
        /// Inside home, but a file whose change affects security or what runs at login
        /// (SSH keys, keychains, shell startup files, LaunchAgents, Glide's own settings).
        case sensitive
    }

    /// The user's home folder, without a trailing slash.
    public static var home: String { normalize(NSHomeDirectory()) }

    /// Folders where scratch files are expected. `/tmp` and `/var` are symlinks into `/private`
    /// on macOS, so both spellings are listed; the per-user temporary folder lives under
    /// `/var/folders`.
    static var tempRoots: [String] {
        var roots = ["/tmp", "/private/tmp", "/var/tmp", "/private/var/tmp", "/var/folders", "/private/var/folders"]
        let t = normalize(NSTemporaryDirectory())
        if !roots.contains(t) { roots.append(t) }
        return roots
    }

    static let discardPaths: Set<String> = ["/dev/null", "/dev/stdout", "/dev/stderr", "/dev/tty", "/dev/zero"]

    /// Collapses `.`/`..`/repeated slashes and drops a trailing slash. Purely textual (never
    /// touches the disk) so the shell checker stays deterministic; `..` above `/` stays at `/`.
    public static func normalize(_ path: String) -> String {
        let absolute = path.hasPrefix("/")
        var parts: [Substring] = []
        for comp in path.split(separator: "/", omittingEmptySubsequences: true) {
            if comp == "." { continue }
            if comp == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
            parts.append(comp)
        }
        let joined = parts.joined(separator: "/")
        return absolute ? "/" + joined : (joined.isEmpty ? "." : joined)
    }

    /// Expands `~`, `~user`, `$HOME` and `${HOME}` and makes the path absolute against `cwd`.
    /// Returns nil when the path still depends on something only known at run time (another
    /// variable or a command substitution), because then nothing reliable can be said about it.
    /// `literalDollar` is for paths that never pass through a shell (the file tools): there a
    /// `$` is just a character, and only a leading `$NAME`, `${…}` or `$(…)` is refused as an
    /// unexpanded variable the model probably meant the shell to fill in.
    public static func expand(_ raw: String, home: String = PathRules.home, cwd: String? = nil, literalDollar: Bool = false) -> String? {
        var p = raw
        if p.isEmpty { return nil }
        for token in ["${HOME}", "$HOME"] where p.hasPrefix(token) {
            p = home + p.dropFirst(token.count)
            break
        }
        if p == "~" || p.hasPrefix("~/") {
            p = home + p.dropFirst(1)
        } else if p.hasPrefix("~") {
            // ~name → that user's home folder (macOS keeps them under /Users).
            let rest = p.dropFirst()
            let name = rest.prefix { $0 != "/" }
            p = "/Users/" + name + rest.dropFirst(name.count)
        }
        if literalDollar {
            if p.range(of: #"^\$[A-Za-z_]|\$\{|\$\("#, options: .regularExpression) != nil { return nil }
        } else if p.contains("$") || p.contains("`") {
            return nil
        }
        if !p.hasPrefix("/") { p = (cwd ?? home) + "/" + p }
        return normalize(p)
    }

    /// True when `path` is `dir` or inside it (case-insensitive).
    public static func isInside(_ path: String, _ dir: String) -> Bool {
        let p = path.lowercased(), d = dir.lowercased()
        if d == "/" { return true }
        return p == d || p.hasPrefix(d + "/")
    }

    /// Files and folders whose *contents* are secrets: reading them would hand private keys or
    /// credentials to a model, and changing them weakens security.
    static func secretRoots(home: String) -> [String] {
        [home + "/.ssh", home + "/.gnupg", home + "/.aws", home + "/.netrc", home + "/.kube", home + "/.docker/config.json",
         home + "/Library/Keychains", "/Library/Keychains", home + "/Library/Application Support/com.apple.TCC",
         "/Library/Application Support/com.apple.TCC", home + "/Library/Cookies"]
    }

    /// Files that decide what runs at login or how the shell starts, and Glide's own settings
    /// (an agent must not be able to switch off its own safety settings).
    static func persistenceRoots(home: String) -> [String] {
        [".zshrc", ".zprofile", ".zshenv", ".zlogin", ".zlogout", ".bashrc", ".bash_profile", ".bash_login", ".profile",
         "Library/LaunchAgents", "Library/Preferences/dev.notchbuddy.app.plist", ".config/fish/config.fish"]
            .map { home + "/" + $0 }
    }

    /// True for paths whose contents are private keys or credentials. Public keys are fine.
    public static func isSecret(_ path: String, home: String = PathRules.home) -> Bool {
        if path.lowercased().hasSuffix(".pub") { return false }
        return secretRoots(home: home).contains { isInside(path, $0) }
    }

    public static func writeZone(_ path: String, home: String = PathRules.home) -> WriteZone {
        let p = normalize(path)
        if discardPaths.contains(p.lowercased()) || p.lowercased().hasPrefix("/dev/fd/") { return .discard }
        if isSecret(p, home: home) || persistenceRoots(home: home).contains(where: { isInside(p, $0) }) { return .sensitive }
        if isInside(p, home) { return .allowed }
        if tempRoots.contains(where: { isInside(p, $0) }) { return .allowed }
        return .outside
    }

    /// Trees whose recursive deletion (or recursive chmod/chown) would wreck the system or the
    /// user's account: the root, every top-level system folder, any user's home, a mounted
    /// volume's root. These are blocked outright, not just approval-gated.
    public static func isCriticalTree(_ path: String, home: String = PathRules.home) -> Bool {
        let p = normalize(path).lowercased()
        if p == "/" { return true }
        let topLevel: Set<String> = ["/system", "/library", "/applications", "/users", "/usr", "/bin", "/sbin", "/etc", "/var",
                                     "/private", "/private/var", "/private/etc", "/opt", "/volumes", "/cores", "/dev"]
        if topLevel.contains(p) { return true }
        if p == home.lowercased() { return true }
        // Any user's home folder or any volume root: /Users/<name>, /Volumes/<name>.
        for root in ["/users/", "/volumes/"] where p.hasPrefix(root) {
            if !p.dropFirst(root.count).contains("/") { return true }
        }
        return isProtectedFromDeletion(p, home: home)
    }

    /// Folders whose deletion (recursive or not) destroys the account: `~/Library` itself and
    /// the keychains.
    public static func isProtectedFromDeletion(_ path: String, home: String = PathRules.home) -> Bool {
        let p = normalize(path)
        if p.lowercased() == (home + "/Library").lowercased() { return true }
        return isInside(p, home + "/Library/Keychains") || isInside(p, "/Library/Keychains")
    }

    /// Strips trailing glob segments (`/*`, `/**`) so `rm -rf ~/*` is judged as deleting `~`.
    static func stripTrailingGlob(_ raw: String) -> String {
        var p = raw
        while p.hasSuffix("/*") || p.hasSuffix("/**") {
            p = String(p.dropLast(p.hasSuffix("/**") ? 3 : 2))
            if p.isEmpty { return "/" }
        }
        if p == "*" { return "." }
        return p
    }

    /// Short display form: `~/x` for paths in home.
    public static func display(_ path: String, home: String = PathRules.home) -> String {
        if isInside(path, home) { return "~" + path.dropFirst(home.count) }
        return path
    }
}
