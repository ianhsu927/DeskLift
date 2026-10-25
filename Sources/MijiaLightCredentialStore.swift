import Foundation
import Security

protocol MijiaLightCredentialStoring {
    func load() throws -> MijiaLightCredentials?
    func save(_ credentials: MijiaLightCredentials) throws
    func remove() throws
}

enum MijiaLightStoreError: LocalizedError {
    case keychain(OSStatus)
    case invalidRecord

    var errorDescription: String? {
        switch self {
        case .keychain:
            return "无法访问登录钥匙串。请解锁钥匙串并允许 DeskLift 访问挂灯凭据。"
        case .invalidRecord:
            return "已保存的挂灯凭据无效，请重新设置。"
        }
    }
}

struct KeychainMijiaLightStore: MijiaLightCredentialStoring {
    private let service = "local.ian.desklift.mijia-light"
    private let account = "primary"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    func load() throws -> MijiaLightCredentials? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw MijiaLightStoreError.keychain(status) }
        guard let data = result as? Data,
              let credentials = try? JSONDecoder().decode(MijiaLightCredentials.self, from: data) else {
            throw MijiaLightStoreError.invalidRecord
        }
        return credentials
    }

    func save(_ credentials: MijiaLightCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        let changes = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "DeskLift 米家显示器挂灯"
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw MijiaLightStoreError.keychain(status) }
    }

    func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MijiaLightStoreError.keychain(status)
        }
    }

    /// One-time migration from the private diagnostic export. Never logs input.
    static func importDiagnosticFile(_ path: String) throws {
        let url = URL(fileURLWithPath: path)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 8192 else { throw MijiaLightStoreError.invalidRecord }
        let data = try Data(contentsOf: url)
        struct Export: Decodable {
            let host: String
            let token: String
            let deviceID: String
            let model: String
            enum CodingKeys: String, CodingKey {
                case host, token, model
                case deviceID = "device_id"
            }
        }
        guard let record = try? JSONDecoder().decode(Export.self, from: data),
              record.model == "xiaomi.light.bar2", let deviceID = UInt32(record.deviceID) else {
            throw MijiaLightStoreError.invalidRecord
        }
        let credentials = try MijiaLightCredentials(host: record.host, tokenHex: record.token, deviceID: deviceID)
        try KeychainMijiaLightStore().save(credentials)
    }
}
