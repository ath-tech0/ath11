import UIKit
import Darwin
import MachO
import CryptoKit
import Security
import CommonCrypto

public final class APONSDKConfig {

    public static var serverURL: String = {
        if let v = Bundle.main.object(forInfoDictionaryKey: "LicenseServerURL") as? String, !v.isEmpty { return v }
        return "https://YOUR_WORKER.workers.dev"
    }()

    public static var heartbeatSeconds: Int = 300
}

public struct APONLicenseState: Decodable {
    public let valid: Bool
    public let status: String?
    public let package: String?
    public let license: String?
    public let expiresAt: String?
    public let durationDays: Int?
    public let deviceHash: String?
    public let checksLeft: Int?
    public let devicesLeft: Int?
    public let allowInject: Bool
    public let signature: String?
    public let sigV2: String?
    public let ts: Int?
    public let message: String?

    public var isActive: Bool { valid && status != "expired" && status != "banned" }
    public var expiresDate: Date? {
        guard let s = expiresAt else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime, .withTimeZone]
        if let date = iso.date(from: s) { return date }

        // Cloudflare/D1 responses may include fractional seconds, which the
        // default ISO8601 parser does not accept on every iOS version.
        iso.formatOptions.insert(.withFractionalSeconds)
        if let date = iso.date(from: s) { return date }

        // Accept a backend timestamp without a timezone as UTC rather than
        // silently displaying "No expiry reported".
        let fallback = DateFormatter()
        fallback.locale = Locale(identifier: "en_US_POSIX")
        fallback.timeZone = TimeZone(secondsFromGMT: 0)
        fallback.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return fallback.date(from: s)
    }
}

public enum APONVerifyError: LocalizedError {
    case noCredentials
    case unsignedResponse
    case missingSignature
    case badSignature
    case keyNotFound
    case banned(String?)
    case expired
    case deviceLimit(Int)
    case invalidPackage
    case rateLimited
    case ipBanned
    case network(String)
    case serverMessage(String)

    public var errorDescription: String? {
        switch self {
        case .noCredentials:            return "SDK not configured — ask the owner for your token + HMAC secret."
        case .unsignedResponse:         return "Server response failed its signature check — refusing to trust it."
        case .missingSignature:         return "Missing HMAC signature."
        case .badSignature:             return "Invalid HMAC signature — wrong secret."
        case .keyNotFound:              return "License key not found."
        case .banned(let r):            return "License banned." + (r.map { " " + $0 } ?? "")
        case .expired:                  return "License expired."
        case .deviceLimit(let n):       return "Device limit reached (\(n) devices)."
        case .invalidPackage:           return "Unknown or inactive package."
        case .rateLimited:              return "Too many attempts. Try later."
        case .ipBanned:                 return "Your network is blocked."
        case .network(let m):           return "Connection failed: \(m)"
        case .serverMessage(let m):     return m
        }
    }
}

#if swift(>=6.0)
extension APONVerifyError: @retroactive Error {}
#else
extension APONVerifyError: Error {}
#endif

private enum APONRuntimeDylibs {
    static func names() -> [String] {
        let trusted = ["/system/library/", "/usr/lib/", "/private/preboot/", "/system/applications/"]
        let blocked = Set(["kabraxking.dylib", "bypassffmax.dylib", "fridagadget.dylib", "libobjection.dylib", "objection.dylib", "cycript.dylib"])
        let appBundle = Bundle.main.bundlePath.lowercased()
        var result = [String]()
        for i in 0..<_dyld_image_count() {
            guard let c = _dyld_get_image_name(i) else { continue }
            let path = String(cString: c).lowercased()
            guard path.hasSuffix(".dylib") && !trusted.contains(where: { path.hasPrefix($0) }) else { continue }
            let name = URL(fileURLWithPath: path).lastPathComponent
            // IPA-embedded frameworks are legitimate; retain known blocked names.
            if !appBundle.isEmpty && path.hasPrefix(appBundle) && !blocked.contains(name) { continue }
            if !name.isEmpty && !result.contains(name) { result.append(name) }
        }
        return result
    }
}

enum APONDeviceID {
    static let service = "com.aponls.deviceid"
    static let account = "main"

    static var current: String {
        if let existing = load() { return existing }
        let id = UUID().uuidString
        save(id)
        return id
    }

    static func load() -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }

    static func save(_ id: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ] as CFDictionary)
        let data = id.data(using: .utf8)!
        SecItemAdd([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data
        ] as CFDictionary, nil)
    }

    static var hash: String { APONCrypto.sha256(current) }
}

enum APONCrypto {
    static func hmacSha256(_ message: String, secret: String) -> String {
        let key = secret.data(using: .utf8)!
        var mac = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        key.withUnsafeBytes { kPtr in
            message.data(using: .utf8)!.withUnsafeBytes { mPtr in
                CCHmac(UInt32(kCCHmacAlgSHA256), kPtr.baseAddress!, key.count, mPtr.baseAddress!, message.count, &mac)
            }
        }
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(_ s: String) -> String {
        let data = Data(s.utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func v3Headers(method: String, path: String, body: [String: Any], token: String, key: String, deviceID: String, secret: String) -> [String: String] {
        let now = String(Int(Date().timeIntervalSince1970))
        var random = [UInt8](repeating: 0, count: 18)
        _ = SecRandomCopyBytes(kSecRandomDefault, random.count, &random)
        let nonce = Data(random).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let bodyData = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        let bodyHash = SHA256.hash(data: bodyData).map { String(format: "%02x", $0) }.joined()
        let canonical = ["M3SB-API-SIGNATURE-V3", method.uppercased(), path, now, nonce, bodyHash, token, key, deviceID].joined(separator: "\n")
        return ["X-M3SB-Signature-Version": "3", "X-M3SB-Timestamp": now, "X-M3SB-Nonce": nonce, "X-M3SB-Body-SHA256": bodyHash, "X-M3SB-Signature": hmacSha256(canonical, secret: secret)]
    }

    static let responseFields = ["valid", "status", "license", "device_hash",
                                "expires_at", "devices_left", "allow_inject", "ts"]

    static func canonicalPayload(_ json: [String: Any]) -> String {
        responseFields.map { field -> String in
            guard let v = json[field], !(v is NSNull) else { return "\(field)=" }

            if CFGetTypeID(v as CFTypeRef) == CFBooleanGetTypeID() {
                return "\(field)=\(((v as? Bool) ?? false) ? "true" : "false")"
            }
            if let n = v as? NSNumber { return "\(field)=\(n.stringValue)" }
            return "\(field)=\(v)"
        }.joined(separator: "&")
    }

    static func verifyResponse(payload: String, signature: String, secret: String) -> Bool {
        guard !signature.isEmpty else { return false }
        let expected = hmacSha256(payload, secret: secret)
        let a = Array(expected.utf8), b = Array(signature.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }
}

public enum APONLicenseSDK {

    @discardableResult
    public static func verify(licenseKey key: String,
                              completion: @escaping (Result<APONLicenseState, APONVerifyError>) -> Void) -> URLSessionTask?
    {
        let deviceID = APONDeviceID.current
        let body: [String: Any] = [
            "key": key,
            "device_id": deviceID,
            "device_name": UIDevice.current.name,
            "os_version": UIDevice.current.systemVersion
        ]
        guard let url = URL(string: APONSDKConfig.serverURL + "/api/license/mobile-verify") else {
            completion(.failure(.network("bad url"))); return nil
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("ATH-External-iOS/2.0", forHTTPHeaderField: "X-ATH-Client")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
        req.timeoutInterval = 20

        let task = URLSession.shared.dataTask(with: req) { data, response, err in
            if let err = err { completion(.failure(.network(err.localizedDescription))); return }
            guard let http = response as? HTTPURLResponse,
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(.failure(.network("empty response"))); return
            }
            let state = APONLicenseSDK.decode(json)
            if http.statusCode == 429 { completion(.failure(.rateLimited)); return }
            if !state.valid {
                switch state.status {
                case "expired": completion(.failure(.expired))
                case "device_mismatch", "device_limit_reached": completion(.failure(.deviceLimit(json["device_limit"] as? Int ?? 1)))
                case "banned", "revoked", "suspended": completion(.failure(.banned(state.message)))
                default: completion(.failure(.keyNotFound))
                }
                return
            }
            completion(.success(state))
        }
        task.resume()
        return task
    }

    @discardableResult
    public static func check(licenseKey key: String,
                             completion: @escaping (Bool) -> Void) -> URLSessionTask? {
        verify(licenseKey: key) { result in
            switch result {
            case .success(let state): completion(state.isActive)
            case .failure: completion(false)
            }
        }
    }

    static func decode(_ json: [String: Any]) -> APONLicenseState {
        let s = { (k: String) -> String? in json[k] as? String }
        return APONLicenseState(
            valid: json["valid"] as? Bool ?? false,
            status: s("status"),
            package: s("package"),
            license: s("license"),
            expiresAt: s("expires_at"),
            durationDays: json["duration_days"] as? Int,
            deviceHash: s("device_hash"),
            checksLeft: json["checks_left"] as? Int,
            devicesLeft: json["devices_left"] as? Int,
            allowInject: json["allow_inject"] as? Bool ?? false,
            signature: s("signature"),
            sigV2: s("sig_v2"),
            ts: json["ts"] as? Int,
            message: s("message")
        )
    }
}

@objc(APONSDKResult)
public final class APONSDKResult: NSObject {
    @objc public let valid: Bool
    @objc public let status: String?
    @objc public let packageName: String?
    @objc public let licenseKey: String?
    @objc public let expiresAt: String?
    @objc public let durationDays: Int
    @objc public let deviceHash: String?
    @objc public let checksLeft: Int
    @objc public let allowInject: Bool
    @objc public let message: String?
    @objc public var isActive: Bool { valid && status != "expired" && status != "banned" }

    init(_ state: APONLicenseState) {
        valid = state.valid
        status = state.status
        packageName = state.package
        licenseKey = state.license
        expiresAt = state.expiresAt
        durationDays = state.durationDays ?? 0
        deviceHash = state.deviceHash
        checksLeft = state.checksLeft ?? 0
        allowInject = state.allowInject
        message = state.message
    }
}

@objc(APONSDKBridge)
public final class APONSDKBridge: NSObject {
    @objc public static func configure(withToken token: String, hmacSecret secret: String) {
        // Kept for source compatibility with older callers. Mobile verification
        // does not ship or use a shared API secret in the app.
    }

    @objc public static func configure(withToken token: String, hmacSecret secret: String, serverURL url: String) {
        APONSDKConfig.serverURL = url
    }

    @objc public static func verify(withLicenseKey key: String, completion: @escaping (APONSDKResult?, Error?) -> Void) -> URLSessionTask? {
        APONLicenseSDK.verify(licenseKey: key) { result in
            switch result {
            case .success(let s): completion(APONSDKResult(s), nil)
            case .failure(let e): completion(nil, e as Error)
            }
        }
    }

    @objc public static func check(withLicenseKey key: String, completion: @escaping (Bool) -> Void) -> URLSessionTask? {
        APONLicenseSDK.check(licenseKey: key, completion: completion)
    }

    @objc public static func deviceIDHash() -> String { APONDeviceID.hash }
}
