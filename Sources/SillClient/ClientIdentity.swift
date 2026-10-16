import Foundation
import Security
import StreamProtocol

/// This Mac's identity as a Device (DCritelli/sill#2): one P-256 key, made at the first pairing,
/// whose certificate is rebuilt at each launch (the Host pins the key). Where the key lives follows
/// Sill.app's rule (docs/keychain-plan.md): the data-protection keychain when the running binary is
/// entitled to a keychain access group (a build signed with a provisioning profile), where no other
/// process can pre-create or read it; otherwise the login keychain, the profile-free fallback. It is
/// never synced and never leaves this Mac.
///
/// `-SillMemoryIdentity 1` keeps it in memory for one run (tests against a Host on this Mac that
/// must not touch the keychain). Main thread.
enum ClientIdentity {
    static let tag = Data("me.saffer.sill.client.device-key".utf8)
    static let label = "Sill Client"

    enum Store: Equatable {
        case dataProtection(group: String)
        case login
        case memory
    }

    static let store: Store = {
        if UserDefaults.standard.bool(forKey: "SillMemoryIdentity") { return .memory }
        if let group = entitledAccessGroup() { return .dataProtection(group: group) }
        return .login
    }()

    private static var cached: RemoteIdentity?

    /// The identity, made now if this Mac has none yet. Nil only when the keychain refuses (it says
    /// why in the log).
    static func loadOrCreate() -> RemoteIdentity? {
        if let cached { return cached }
        let key: SecKey?
        switch store {
        case .memory: key = RemoteKey.generate()
        case .login, .dataProtection: key = readKey() ?? makeKey()
        }
        cached = key.flatMap(RemoteIdentity.init(privateKey:))
        if cached != nil { print("Identity: \(describe) (\(RemoteIdentity.shortName(cached!.fingerprint)))") }
        return cached
    }

    static var describe: String {
        switch store {
        case .dataProtection(let group): return "the data-protection keychain (access group \(group))"
        case .login: return "the login keychain (no keychain-access-groups entitlement)"
        case .memory: return "memory, for this run only"
        }
    }

    /// The `keychain-access-groups` entitlement the running binary holds, from its own signature:
    /// the group ending in the app's own ID, else the first. Nil for any build without one.
    private static func entitledAccessGroup() -> String? {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "keychain-access-groups" as CFString, nil) else { return nil }
        if let groups = value as? [String], !groups.isEmpty { return groups.first { $0.hasSuffix(".me.saffer.sill.client") } ?? groups.first }
        if let group = value as? String, !group.isEmpty { return group }
        return nil
    }

    /// Every query names its keychain: the data-protection one with its group, or the login one.
    private static func scoped(_ query: [String: Any]) -> [String: Any] {
        var q = query
        if case .dataProtection(let group) = store {
            q[kSecUseDataProtectionKeychain as String] = true
            q[kSecAttrAccessGroup as String] = group
        }
        return q
    }

    private static func readKey() -> SecKey? {
        let query = scoped([
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnRef as String: true,
        ])
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let item,
              CFGetTypeID(item) == SecKeyGetTypeID() else { return nil }
        return (item as! SecKey)      // the type was just checked
    }

    private static func makeKey() -> SecKey? {
        var privateAttributes: [String: Any] = [
            kSecAttrIsPermanent as String: true,
            kSecAttrApplicationTag as String: tag,
            kSecAttrLabel as String: label,
        ]
        var attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
        ]
        if case .dataProtection(let group) = store {
            // Readable after the first unlock (a session while the Mac is locked), never off this Mac.
            privateAttributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            privateAttributes[kSecAttrAccessGroup as String] = group
            attributes[kSecUseDataProtectionKeychain as String] = true
        }
        attributes[kSecPrivateKeyAttrs as String] = privateAttributes
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            print("Identity: no key could be made in \(describe) (\(error.map { "\($0.takeRetainedValue())" } ?? "no reason given"))")
            return nil
        }
        return key
    }
}
