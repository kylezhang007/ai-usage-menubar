import Foundation
import Security

/// API keys and the Claude login copy live in the login Keychain, never in plain files.
///
/// Items are read and written through Apple's /usr/bin/security tool (the way Claude Code
/// stores its own login), so the Keychain trusts that fixed, Apple-signed tool rather than
/// this app. An unsigned app gets a new identity on every build, which would otherwise
/// make macOS ask for your password after each update.
enum Keychain {
    private static let service = "com.local.aiusage.v2"
    private static let legacyService = "com.local.aiusage"   // items saved by v1.0–1.1 directly

    enum Key: String, CaseIterable {
        case anthropicAdmin, openAIAdmin, deepSeek, claudeSessionKey
        case claudeOAuth   // the app's own copy of the Claude Code login (JSON)
    }

    static func get(_ key: Key) -> String? {
        let result = security(["find-generic-password", "-s", service, "-a", key.rawValue, "-w"])
        guard result.status == 0, let value = result.output, !value.isEmpty else { return nil }
        return value
    }

    static func set(_ key: Key, _ value: String?) {
        _ = security(["delete-generic-password", "-s", service, "-a", key.rawValue])
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
        // Sent as hex on stdin through `security -i`, so the value never appears in the process list.
        let hex = Data(value.utf8).map { String(format: "%02x", $0) }.joined()
        _ = security(["-i"], stdin: "add-generic-password -s \"\(service)\" -a \"\(key.rawValue)\" -X \(hex)\n")
    }

    /// One-time move of items saved by earlier versions. Reading them may ask for your
    /// password one last time; after that, updates never ask again.
    static func migrateLegacyItems() {
        let flag = "keychainMigratedToSecurityTool"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        for key in Key.allCases where get(key) == nil {
            let base: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: legacyService,
                kSecAttrAccount as String: key.rawValue,
            ]
            var query = base
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
                  let data = out as? Data, let value = String(data: data, encoding: .utf8) else { continue }
            set(key, value)
            SecItemDelete(base as CFDictionary)
        }
        UserDefaults.standard.set(true, forKey: flag)
    }

    private static func security(_ args: [String], stdin: String? = nil) -> (status: Int32, output: String?) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        let input = Pipe()
        if stdin != nil { p.standardInput = input }
        do { try p.run() } catch { return (-1, nil) }
        if let stdin {
            input.fileHandleForWriting.write(Data(stdin.utf8))
            try? input.fileHandleForWriting.close()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (p.terminationStatus, text)
    }
}
