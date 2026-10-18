import CryptoKit
import Foundation

/// Optional PIN that locks Settings (schedules and General) until unlocked, and guards quitting, exiting a
/// block early, and resuming a block in place of a snoozed one. It's a self-control speed bump rather than
/// security: a short PIN's hash is quick to brute-force, and the stored record can be removed with `defaults delete`.
final class PinLock: ObservableObject {
    static let shared = PinLock(defaults: .standard)

    static let credentialKey = "ScreenBlocker.pinCredential"
    static let lengthRange = 4...8

    /// A PIN is set. Also true when the stored record can't be read, so a corrupt record can't turn protection off.
    @Published private(set) var isEnabled: Bool
    /// Settings were unlocked with the PIN, until locked again
    @Published private(set) var isSettingsUnlocked = false
    /// Bumped whenever editing is locked, so an unlock prompt that was already open can't undo the lock
    private(set) var lockGeneration = 0

    private let defaults: UserDefaults

    private struct Credential: Codable {
        var version = 1
        var salt: Data
        var digest: Data
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        isEnabled = defaults.object(forKey: Self.credentialKey) != nil
    }

    var canEditSettings: Bool {
        !isEnabled || isSettingsUnlocked
    }

    /// 4–8 ASCII digits (leading zeros kept)
    static func isValidPin(_ pin: String) -> Bool {
        lengthRange.contains(pin.utf8.count) && pin.utf8.allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }
    }

    /// Turn the PIN on. Only allowed while it's off, so a PIN can't be replaced without knowing it.
    @discardableResult
    func enable(pin: String) -> Bool {
        guard !isEnabled, Self.isValidPin(pin) else { return false }
        let salt = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
        guard let data = try? JSONEncoder().encode(Credential(salt: salt, digest: Self.digest(pin, salt: salt))) else {
            return false
        }
        defaults.set(data, forKey: Self.credentialKey)
        isEnabled = true
        lockSettings()
        return true
    }

    func verify(_ pin: String) -> Bool {
        guard let data = defaults.data(forKey: Self.credentialKey),
              let credential = try? JSONDecoder().decode(Credential.self, from: data),
              credential.version == 1 else { return false }
        return Self.digest(pin, salt: credential.salt) == credential.digest
    }

    /// Turn the PIN off and forget it. Only while Settings are unlocked, which took the PIN.
    @discardableResult
    func disable() -> Bool {
        guard isEnabled, isSettingsUnlocked else { return false }
        defaults.removeObject(forKey: Self.credentialKey)
        isEnabled = false
        lockSettings()
        return true
    }

    /// Unlock Settings, unless they were locked again since `generation` was read
    @discardableResult
    func unlockSettings(pin: String, since generation: Int) -> Bool {
        guard isEnabled, generation == lockGeneration, verify(pin) else { return false }
        isSettingsUnlocked = true
        return true
    }

    func lockSettings() {
        lockGeneration += 1
        if isSettingsUnlocked {
            isSettingsUnlocked = false
        }
    }

    private static func digest(_ pin: String, salt: Data) -> Data {
        Data(SHA256.hash(data: salt + Data(pin.utf8)))
    }
}
