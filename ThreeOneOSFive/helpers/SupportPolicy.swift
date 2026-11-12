import Foundation

enum ExploitSupportPolicy {
    // Verified ranges. Offsets exist for 17/18/26 in kexploit/offsets.m.
    // 26/27 container grants prefer worse_query (vendor) + bad_query/MCM fallback.
    static let verifiedIOS17Range = "17.0–17.7.x"
    static let verifiedIOS18Range = "18.0–18.7.1"
    static let verifiedIOS26Range = "26.0–26.7.2"
    static let verifiedIOS27Range = "27.0–27.2.1"
    static let verifiedIOS273Beta1Build = "24C5037i"

    static let verifiedIOS27Builds: [(beta: Int, publicBeta: Int?, build: String)] = [
        (1, nil, "24A5355q"),
        (2, nil, "24A5370h"),
        (3, 1, "24A5380h"),
        (4, 2, "24A5390f")
    ]

    static func iOS27BetaNumber(for build: String) -> Int? {
        verifiedIOS27Builds.first { $0.build == build }?.beta
    }

    static func iOS27PublicBetaNumber(for build: String) -> Int? {
        verifiedIOS27Builds.first { $0.build == build }?.publicBeta
    }

    /// Classic kexploit_opa334 path (kernel R/W). Solid on 17/18; attempted on 26/27.
    static func supportsKernelExploit(major: Int, minor: Int, patch: Int) -> Bool {
        guard minor >= 0, patch >= 0 else { return false }
        if major == 17 { return minor <= 7 }
        if major == 18 { return minor < 7 || (minor == 7 && patch <= 1) }
        if major == 26 { return minor < 7 || (minor == 7 && patch <= 2) }
        if major == 27 {
            if minor < 2 { return true }
            if minor == 2 { return patch <= 1 }
            return false
        }
        return false
    }

    /// Full runtime support — any working access path (kexploit, sandbox_escape, worse_query, bad_query/MCM).
    static func isSupported(major: Int, minor: Int, patch: Int, build: String) -> Bool {
        if supportsKernelExploit(major: major, minor: minor, patch: patch) {
            return true
        }
        if major == 26 {
            guard minor >= 0, patch >= 0 else { return false }
            return minor < 7 || (minor == 7 && patch <= 2)
        }
        guard major == 27, minor >= 0, patch >= 0 else { return false }
        if minor < 2 { return true }
        if minor == 2 { return patch <= 1 }
        return minor == 3 && patch == 0 && build == verifiedIOS273Beta1Build
    }

    /// Prefer worse_query container grant on these builds (matches vendor policy).
    static func prefersWorseQuery(major: Int, minor: Int, patch: Int, build: String) -> Bool {
        if major == 26 {
            return minor < 7 || (minor == 7 && patch <= 2)
        }
        if major == 27 {
            if minor < 2 { return true }
            if minor == 2 { return patch <= 1 }
            return minor == 3 && patch == 0 && build == verifiedIOS273Beta1Build
        }
        return false
    }
}
