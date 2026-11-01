import Foundation
#if canImport(Security)
import Security
#endif

/// Where the SDK keeps the little it keeps -- the installation ID and whether a step-up re-enrolment
/// is pending -- beside the key, never the key itself.
@MainActor
public protocol SecureStorage: AnyObject {
    func read(_ key: String) async throws -> String?
    func write(_ key: String, _ value: String) async throws
    func delete(_ key: String) async throws
}

/// The installation: its key, made on first use, and its ID, kept in the platform's secure storage --
/// on iOS in the Keychain, on this device only, readable after the first unlock, never synchronized.
@MainActor
open class InstallationStore {
    public let key: InstallationKeyProvider
    public let storage: SecureStorage

    static let installationIdKey = "recognition.installation_id.v2"
    static let stepUpReenrolKey = "recognition.stepup_reenrol_pending.v1"

    private var loading: (id: UUID, task: Task<InstallationIdentity, Error>)?

    /// `key` and `storage` replace the native ones in tests.
    public init(key: InstallationKeyProvider? = nil, storage: SecureStorage? = nil) {
        self.key = key ?? NativeInstallationKey()
        self.storage = storage ?? KeychainStorage()
    }

    /// The installation: its key, made on first use, and its ID. A key made now
    /// (`InstallationIdentity.createdThisLaunch`) is a new installation, so it gets a new ID even where
    /// one was stored: that ID belongs to the key that was lost, and a backend refuses a known ID under
    /// another key. Calls at once share one load, so that one key never gets two IDs.
    open func loadOrCreate() async throws -> InstallationIdentity {
        if let running = loading { return try await running.task.value }
        let id = UUID()
        let task = Task<InstallationIdentity, Error> { @MainActor in
            defer { if self.loading?.id == id { self.loading = nil } }
            return try await self.loadOrCreateOnce()
        }
        loading = (id, task)
        return try await task.value
    }

    private func loadOrCreateOnce() async throws -> InstallationIdentity {
        let stored = try await storage.read(InstallationStore.installationIdKey)
        let metadata = try await key.getOrCreateKey()
        var installationId = stored ?? ""
        if installationId.isEmpty || metadata.created {
            installationId = UUID().uuidString.lowercased()
            try await saveInstallationId(installationId)
        }
        return InstallationIdentity(installationId: installationId, nativeKey: key, metadata: metadata)
    }

    /// Keeps the installation your backend answered for this key, which may not be the ID proposed.
    /// Only this opaque ID is stored here; the private key never leaves the keystore.
    open func saveInstallationId(_ installationId: String) async throws {
        try await storage.write(InstallationStore.installationIdKey, installationId)
    }

    /// Whether a step-up key was replaced and the backend has not yet taken the new one
    /// (`DeviceTrust.reenrolStepUp`) -- kept across restarts.
    open func stepUpReenrolPending() async throws -> Bool {
        try await storage.read(InstallationStore.stepUpReenrolKey) != nil
    }

    open func setStepUpReenrolPending(_ pending: Bool) async throws {
        if pending {
            try await storage.write(InstallationStore.stepUpReenrolKey, "1")
        } else {
            try await storage.delete(InstallationStore.stepUpReenrolKey)
        }
    }

    /// Deletes the key and the installation ID: the next start is a new installation.
    open func clear() async throws {
        try await key.deleteKey()
        try await storage.delete(InstallationStore.installationIdKey)
        try await storage.delete(InstallationStore.stepUpReenrolKey)
    }
}

/// The SDK's values in memory: for tests, and for a platform with no Keychain.
@MainActor
public final class MemoryStorage: SecureStorage {
    public private(set) var values: [String: String]

    public init(_ values: [String: String] = [:]) { self.values = values }

    public func read(_ key: String) async throws -> String? { values[key] }
    public func write(_ key: String, _ value: String) async throws { values[key] = value }
    public func delete(_ key: String) async throws { values[key] = nil }
}

/// Generic-password items in the Keychain, readable after the first unlock, on this device only,
/// never synchronized (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`).
@MainActor
public final class KeychainStorage: SecureStorage {
    public let service: String

    public init(service: String = "com.necessarysdk.necessary") { self.service = service }

    #if canImport(Security) && !os(Linux)
    public func read(_ key: String) async throws -> String? {
        let service = self.service
        return try await NativeWorker.run {
            var query = KeychainStorage.query(service, key)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess, let data = item as? Data else {
                throw InstallationKeyFailure(
                    code: "STORAGE_READ_FAILED",
                    message: "The keychain could not read \(key) (OSStatus \(status)).")
            }
            return String(decoding: data, as: UTF8.self)
        }
    }

    public func write(_ key: String, _ value: String) async throws {
        let service = self.service
        try await NativeWorker.run {
            let query = KeychainStorage.query(service, key)
            let update: [String: Any] = [
                kSecValueData as String: Data(value.utf8),
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]
            var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            if status == errSecItemNotFound {
                var item = query
                item.merge(update) { _, new in new }
                status = SecItemAdd(item as CFDictionary, nil)
            }
            guard status == errSecSuccess else {
                throw InstallationKeyFailure(
                    code: "STORAGE_WRITE_FAILED",
                    message: "The keychain could not write \(key) (OSStatus \(status)).")
            }
        }
    }

    public func delete(_ key: String) async throws {
        let service = self.service
        try await NativeWorker.run {
            let status = SecItemDelete(KeychainStorage.query(service, key) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw InstallationKeyFailure(
                    code: "STORAGE_DELETE_FAILED",
                    message: "The keychain could not delete \(key) (OSStatus \(status)).")
            }
        }
    }

    private nonisolated static func query(_ service: String, _ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: false,
        ]
    }
    #else
    public func read(_ key: String) async throws -> String? { throw NativeWorker.missingKey }
    public func write(_ key: String, _ value: String) async throws { throw NativeWorker.missingKey }
    public func delete(_ key: String) async throws { throw NativeWorker.missingKey }
    #endif
}
