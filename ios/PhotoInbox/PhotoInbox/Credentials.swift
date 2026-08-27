import Foundation
import Security

enum CredentialsError: Error { case keychain(OSStatus) }

struct Credentials {
    private static let service = "com.asonas.weblog.PhotoInbox"
    private static let account = "mobile-upload-token"

    static func loadToken() throws -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw CredentialsError.keychain(status)
        }
        return String(data: data, encoding: .utf8)
    }

    static func saveToken(_ token: String) throws {
        let identity: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(identity as CFDictionary)
        var value = identity
        value[kSecValueData] = Data(token.utf8)
        value[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(value as CFDictionary, nil)
        guard status == errSecSuccess else { throw CredentialsError.keychain(status) }
    }
}
