import Foundation
import Security
import ShadeCore

/// Stores the Claude API key in the iOS Keychain.
///
/// - Item: generic password, service `com.shadeapp.shade`, account `claude-api-key` (unchanged from 1.0,
///   so existing keys keep working).
/// - Accessible after first unlock, this device only: never synced to iCloud or restored to another phone.
/// - Replacing a key updates the item in place, so a failed write can never lose the previous key.
struct KeychainSecretStore {
    static let claudeAPIKey = KeychainSecretStore(account: "claude-api-key")

    let service = "com.shadeapp.shade"
    let account: String

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func read() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
                throw ShadeError(.storageReadFailed, "The saved API key is damaged. Enter it again in Settings.")
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw ShadeError(.storageReadFailed, "Couldn't read the API key from the Keychain.", detail: "OSStatus \(status)")
        }
    }

    /// True when a key is stored. Read errors count as "no key" for display purposes only.
    var hasValue: Bool { ((try? read()) ?? nil) != nil }

    /// Validates and stores the key. Throws `.claudeMissingKey` / `.claudeInvalidKey` for bad input.
    func save(_ rawValue: String) throws {
        let value = try ClaudeClient.validatedKey(rawValue)
        let data = Data(value.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw ShadeError(.storageWriteFailed, "Couldn't save the API key to the Keychain.", detail: "update OSStatus \(updateStatus)")
        }
        var add = baseQuery
        add.merge(attributes) { $1 }
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw ShadeError(.storageWriteFailed, "Couldn't save the API key to the Keychain.", detail: "add OSStatus \(addStatus)")
        }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ShadeError(.storageDeleteFailed, "Couldn't remove the API key.", detail: "OSStatus \(status)")
        }
    }
}
