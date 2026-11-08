import Foundation

/// Reads the DeepSeek Harness local credential file on explicit user request.
///
/// DSH keeps its platform grant in `~/.dsh/.credentials.yaml` as a plain YAML
/// record (`records.deepseek-account-platform.default.payload`). The file is
/// owner-readable only. This importer intentionally understands just that
/// stable shape, validates the issuer, and never logs a value.
enum HarnessImportError: LocalizedError, Equatable {
    case fileMissing
    case noLogin
    case noAPIKey
    case invalidLogin
    case unreadable

    var errorDescription: String? {
        switch self {
        case .fileMissing:
            return "No DeepSeek Harness credential file was found at ~/.dsh/.credentials.yaml."
        case .noLogin:
            return "DeepSeek Harness is not signed in."
        case .noAPIKey:
            return "No DeepSeek API key was found in the Harness credential file."
        case .invalidLogin:
            return "The Harness login is not a production DeepSeek Platform grant."
        case .unreadable:
            return "Could not read the DeepSeek Harness credential file."
        }
    }
}

struct HarnessLogin: Equatable, Sendable {
    let accountToken: String
    let apiKey: String?
    let issuer: String
}

enum HarnessImporter {
    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dsh", isDirectory: true)
            .appendingPathComponent(".credentials.yaml", isDirectory: false)
    }

    static func fileExists(at url: URL = defaultURL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    static func load(from url: URL = defaultURL) throws -> HarnessLogin {
        guard fileExists(at: url) else { throw HarnessImportError.fileMissing }
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw HarnessImportError.unreadable
        }
        guard let parsed = parse(text) else { throw HarnessImportError.noLogin }
        guard !parsed.token.hasPrefix("dsh_mock_"),
              let issuerURL = URL(string: parsed.issuer),
              issuerURL.scheme == "https",
              issuerURL.host == "platform.deepseek.com"
        else {
            throw HarnessImportError.invalidLogin
        }
        return HarnessLogin(
            accountToken: parsed.token,
            apiKey: parsed.apiKey,
            issuer: parsed.issuer)
    }

    struct Parsed: Equatable, Sendable {
        let token: String
        let issuer: String
        let apiKey: String?
    }

    /// Minimal indentation parser for DSH's credential document. It only extracts
    /// `refs.DEEPSEEK_API_KEY` and the `deepseek-account-platform/default` grant.
    static func parse(_ text: String) -> Parsed? {
        var section = ""
        var recordName = ""
        var payloadField = ""
        var token: String?
        var issuer: String?
        var apiKey: String?

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.replacingOccurrences(of: "\t", with: "  ")
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            let indent = line.prefix { $0 == " " }.count
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            let rawValue = String(trimmed[trimmed.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            let value = unquote(rawValue)

            switch indent {
            case 0:
                section = key
                recordName = ""
                payloadField = ""
            case 2:
                if section == "refs", key == "DEEPSEEK_API_KEY" {
                    apiKey = value.isEmpty ? nil : value
                } else if section == "records" {
                    recordName = key
                    payloadField = ""
                }
            case 4:
                if section == "records", recordName == "deepseek-account-platform/default" {
                    payloadField = key
                }
            case 6:
                if section == "records",
                   recordName == "deepseek-account-platform/default",
                   payloadField == "payload" {
                    if key == "token" { token = value }
                    if key == "issuer" { issuer = value }
                }
            default:
                break
            }
        }

        guard let token, !token.isEmpty, let issuer, !issuer.isEmpty else { return nil }
        return Parsed(token: token, issuer: issuer, apiKey: apiKey)
    }

    private static func unquote(_ value: String) -> String {
        if value.hasPrefix("\"") {
            let body = value.dropFirst()
            if let end = body.firstIndex(of: "\"") {
                return String(body[..<end])
            }
        }
        if value.hasPrefix("'") {
            let body = value.dropFirst()
            if let end = body.firstIndex(of: "'") {
                return String(body[..<end])
            }
        }
        if let hash = value.firstIndex(of: "#"), hash != value.startIndex {
            let before = value[..<hash]
            if before.last?.isWhitespace == true {
                return String(before).trimmingCharacters(in: .whitespaces)
            }
        }
        return value
    }
}
