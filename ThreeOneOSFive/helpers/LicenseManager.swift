import Combine
import Foundation
import Security

@MainActor
final class LicenseManager: ObservableObject {
    @Published private(set) var expirationDate: Date?
    @Published private(set) var isActive = false
    @Published private(set) var injectionAllowed = false
    @Published private(set) var isBusy = false
    @Published private(set) var message: String?
    @Published private(set) var contactOwner: String?
    @Published private(set) var lastVerifiedAt: Date?
    @Published private(set) var licenseStatus = "Not verified"
    @Published private(set) var activeLicenseKey: String?
    @Published var rememberKey = true

    // Use a new Keychain namespace so an old APON activation cannot silently
    // bypass the new Worker-backed activation screen.
    private let service = "com.ath.external-ios.activation.v2"
    private let keyAccount = "license-key"
    private let expiryAccount = "license-expiry"
    private let verifiedAccount = "license-verified-at"
    private let statusAccount = "license-status"
    private let injectionPolicyAccount = "license-injection-allowed"
    private var lastAttemptAt: Date?
    private var verificationTask: URLSessionTask?

    init() {
        restoreCachedActivation()
        if let saved = rememberedKey() {
            // Keep the last known-good screen visible while the server rechecks the key.
            verifyOnServer(key: saved, saveKey: false)
        }
    }

    func beginLaunchSession() {
        guard !isBusy else { return }
        guard let saved = rememberedKey() else {
            isActive = false
            injectionAllowed = false
            expirationDate = nil
            licenseStatus = "Key required"
            message = "Key required — enter your access key"
            return
        }
        verifyOnServer(key: saved, saveKey: false)
    }

    func activate(key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isBusy else { return }
        if let lastAttemptAt, Date().timeIntervalSince(lastAttemptAt) < 1 {
            message = "Please wait a moment before trying again"
            return
        }
        lastAttemptAt = Date()
        verifyOnServer(key: trimmed, saveKey: rememberKey)
    }

    func rememberedKey() -> String? { string(for: keyAccount) }

    func refresh() { beginLaunchSession() }

    func deactivate() {
        verificationTask?.cancel()
        delete(keyAccount)
        delete(expiryAccount)
        delete(verifiedAccount)
        delete(statusAccount)
        delete(injectionPolicyAccount)
        isActive = false
        injectionAllowed = false
        activeLicenseKey = nil
        expirationDate = nil
        lastVerifiedAt = nil
        licenseStatus = "Not activated"
        message = "Activation removed from this device"
    }

    private func restoreCachedActivation() {
        guard let savedKey = rememberedKey() else { return }
        activeLicenseKey = savedKey
        expirationDate = date(for: expiryAccount)
        lastVerifiedAt = date(for: verifiedAccount)
        licenseStatus = string(for: statusAccount) ?? "Cached"

        // Do not open the main app from a cached value. The Worker must confirm
        // the saved key in this launch before access is granted.
        isActive = false
        injectionAllowed = false
        message = "Checking saved license…"
    }

    private func verifyOnServer(key: String, saveKey: Bool) {
        isBusy = true
        // Keep the key visible for this session even when Keychain persistence
        // is disabled by the user.
        activeLicenseKey = key
        // Injection permission is server-controlled; disable patching until this check completes.
        injectionAllowed = false
        // Do not hide the main app while a previously verified key is being rechecked.
        if !isActive { message = "Checking access key…" }

        verificationTask = APONLicenseSDK.verify(licenseKey: key) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.isBusy = false
                self.verificationTask = nil

                switch result {
                case .success(let state):
                    guard state.isActive else {
                        self.isActive = false
                        self.injectionAllowed = false
                        self.expirationDate = nil
                        self.licenseStatus = state.status?.capitalized ?? "Inactive"
                        self.message = state.message ?? self.friendlyMessage(for: state.status)
                        self.contactOwner = nil
                        self.delete(self.expiryAccount)
                        self.delete(self.verifiedAccount)
                        self.delete(self.injectionPolicyAccount)
                        self.save(self.licenseStatus, for: self.statusAccount)
                        return
                    }
                    if saveKey { self.save(key, for: self.keyAccount) }
                    self.isActive = true
                    self.injectionAllowed = state.allowInject
                    self.expirationDate = state.expiresDate
                    self.lastVerifiedAt = Date()
                    self.licenseStatus = state.allowInject ? "Active" : "Injection disabled"
                    self.saveDate(state.expiresDate, for: self.expiryAccount)
                    self.saveDate(self.lastVerifiedAt, for: self.verifiedAccount)
                    self.save(state.allowInject ? "true" : "false", for: self.injectionPolicyAccount)
                    self.save(self.licenseStatus, for: self.statusAccount)
                    self.contactOwner = nil
                    self.message = state.allowInject
                        ? (state.message ?? "Activated successfully")
                        : (state.message ?? "Injection is disabled by this package's API policy")

                case .failure(let error):
                    // Do not allow a cached injection policy to survive a failed server check.
                    self.injectionAllowed = false
                    self.save("false", for: self.injectionPolicyAccount)
                    if let expiry = self.expirationDate, expiry <= Date() {
                        self.isActive = false
                        self.expirationDate = nil
                        self.licenseStatus = "Verification failed"
                    } else {
                        self.licenseStatus = "Verification unavailable"
                    }
                    self.save(self.licenseStatus, for: self.statusAccount)
                    self.message = error.localizedDescription
                }
            }
        }
    }

    private func friendlyMessage(for status: String?) -> String {
        switch status {
        case "expired": return "License expired"
        case "banned": return "License banned"
        case "invalid": return "Invalid license key"
        default: return "License is not active"
        }
    }

    private func date(for account: String) -> Date? {
        guard let raw = string(for: account) else { return nil }
        return ISO8601DateFormatter().date(from: raw)
    }

    private func saveDate(_ value: Date?, for account: String) {
        guard let value else { delete(account); return }
        save(ISO8601DateFormatter().string(from: value), for: account)
    }

    private func string(for account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func save(_ value: String, for account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)
        var item = base
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    private func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
