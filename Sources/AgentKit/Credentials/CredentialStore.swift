import Foundation
import Security

/// API keys and tokens live only in the macOS Keychain (generic passwords, this device only).
/// Nothing here is logged, persisted elsewhere, or placed in model prompts.
public final class CredentialStore: @unchecked Sendable {
    public static let shared = CredentialStore()

    public let service: String
    private let lock = NSLock()
    private var memo: [String: String?] = [:]
    private var memoryOnly = false

    public init(service: String = "dev.notchbuddy.credentials") {
        self.service = service
    }

    public enum Key: Sendable, Hashable {
        case provider(String)
        case composio
        case jev
        case vercelGateway
        case mcpHeader(server: String, header: String)
        case custom(String)

        public var account: String {
            switch self {
            case .provider(let id): return "provider.\(id)"
            case .composio: return "composio.api-key"
            case .jev: return "typesafe.jev"
            case .vercelGateway: return "vercel.ai-gateway"
            case .mcpHeader(let s, let h): return "mcp.\(s).\(h)"
            case .custom(let s): return s
            }
        }
    }

    /// Serves (and stores) values in memory only and never touches the Keychain. Used by
    /// offscreen UI snapshots so rendering never reads real keys or triggers Keychain prompts.
    public func useMemoryOnly(_ values: [Key: String] = [:]) {
        lock.withLock {
            memoryOnly = true
            memo = Dictionary(uniqueKeysWithValues: values.map { ($0.key.account, Optional($0.value)) })
        }
    }

    public func get(_ key: Key) -> String? {
        let account = key.account
        if let cached = lock.withLock({ memo[account] }) { return cached }
        if lock.withLock({ memoryOnly }) { return nil }
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        let value: String? = status == errSecSuccess ? (item as? Data).map { String(decoding: $0, as: UTF8.self) } : nil
        lock.withLock { memo[account] = value }
        return value
    }

    public func has(_ key: Key) -> Bool {
        guard let v = get(key) else { return false }
        return !v.isEmpty
    }

    @discardableResult
    public func set(_ value: String, for key: Key) -> Bool {
        let account = key.account
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return remove(key) }
        if lock.withLock({ memoryOnly }) {
            lock.withLock { memo[account] = trimmed }
            return true
        }
        let data = Data(trimmed.utf8)
        var status = SecItemUpdate(baseQuery(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery(account)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            add[kSecAttrLabel as String] = "NotchBuddy (\(account))"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        lock.withLock { memo[account] = status == errSecSuccess ? trimmed : nil }
        return status == errSecSuccess
    }

    @discardableResult
    public func remove(_ key: Key) -> Bool {
        if lock.withLock({ memoryOnly }) {
            lock.withLock { memo[key.account] = .some(nil) }
            return true
        }
        let status = SecItemDelete(baseQuery(key.account) as CFDictionary)
        lock.withLock { memo[key.account] = .some(nil) }
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Masked preview for UI ("sk-…a1B2").
    public static func mask(_ secret: String) -> String {
        guard secret.count > 8 else { return String(repeating: "•", count: secret.count) }
        return String(secret.prefix(3)) + "…" + String(secret.suffix(4))
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

/// Removes anything that looks like a credential from text before it is logged or stored.
public enum SecretScrubber {
    static let patterns: [NSRegularExpression] = [
        #"sk-[A-Za-z0-9_\-]{12,}"#, #"sk-ant-[A-Za-z0-9_\-]{12,}"#, #"(?i)bearer\s+[A-Za-z0-9._\-]{16,}"#,
        #"ak_[A-Za-z0-9_\-]{12,}"#, #"(?i)x-api-key[:=]\s*\S+"#, #"ghp_[A-Za-z0-9]{20,}"#, #"xox[abp]-[A-Za-z0-9\-]{10,}"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    public static func scrub(_ text: String, knownSecrets: [String] = []) -> String {
        var out = text
        for secret in knownSecrets where secret.count >= 8 {
            out = out.replacingOccurrences(of: secret, with: "[redacted]")
        }
        for re in patterns {
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "[redacted]")
        }
        return out
    }
}
