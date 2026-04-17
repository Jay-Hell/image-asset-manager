import Foundation
import Security

public enum KeychainService {
    public enum KeychainError: Error {
        case itemNotFound
        case unexpectedData
        case unhandledError(OSStatus)
    }

    public static func store(_ value: String, service: String, account: String) throws {
        let data = Data(value.utf8)
        let query: [CFString: Any] = [
            kSecClass:              kSecClassGenericPassword,
            kSecAttrService:        service,
            kSecAttrAccount:        account,
            kSecValueData:          data,
            kSecAttrAccessible:     kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrSynchronizable: false,
        ]

        let addStatus = SecItemAdd(query as CFDictionary, nil)

        if addStatus == errSecDuplicateItem {
            let search: [CFString: Any] = [
                kSecClass:       kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: account,
            ]
            let update: [CFString: Any] = [kSecValueData: data]
            let updateStatus = SecItemUpdate(search as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainError.unhandledError(updateStatus)
            }
        } else if addStatus != errSecSuccess {
            throw KeychainError.unhandledError(addStatus)
        }
    }

    public static func retrieve(service: String, account: String) throws -> String {
        let query: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrService:      service,
            kSecAttrAccount:      account,
            kSecReturnData:       true,
            kSecMatchLimit:       kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let string = String(data: data, encoding: .utf8) else {
                throw KeychainError.unexpectedData
            }
            return string
        case errSecItemNotFound:
            throw KeychainError.itemNotFound
        default:
            throw KeychainError.unhandledError(status)
        }
    }

    public static func delete(service: String, account: String) throws {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandledError(status)
        }
    }
}
