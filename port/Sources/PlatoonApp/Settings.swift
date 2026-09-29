import Foundation

/// User preferences (persisted in UserDefaults).
final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard
    private init() {
        d.register(defaults: ["filter": 0, "aspect": true, "integer": false, "overscan": false, "curvature": true,
                              "scanlines": 0.35, "interpolate": false, "a500filter": true, "separation": 0.7, "volume": 1.0])
    }
    var filter: Int { get { d.integer(forKey: "filter") } set { d.set(newValue, forKey: "filter") } }
    var aspect: Bool { get { d.bool(forKey: "aspect") } set { d.set(newValue, forKey: "aspect") } }
    var integerScale: Bool { get { d.bool(forKey: "integer") } set { d.set(newValue, forKey: "integer") } }
    var overscan: Bool { get { d.bool(forKey: "overscan") } set { d.set(newValue, forKey: "overscan") } }
    var curvature: Bool { get { d.bool(forKey: "curvature") } set { d.set(newValue, forKey: "curvature") } }
    var scanlines: Double { get { d.double(forKey: "scanlines") } set { d.set(newValue, forKey: "scanlines") } }
    var interpolate: Bool { get { d.bool(forKey: "interpolate") } set { d.set(newValue, forKey: "interpolate") } }
    var a500Filter: Bool { get { d.bool(forKey: "a500filter") } set { d.set(newValue, forKey: "a500filter") } }
    var separation: Double { get { d.double(forKey: "separation") } set { d.set(newValue, forKey: "separation") } }
    var volume: Double { get { d.double(forKey: "volume") } set { d.set(newValue, forKey: "volume") } }
    /// Last section reached (1 or 2) and the carried globals, for "Continue".
    var continueSection: Int { get { d.integer(forKey: "contSection") } set { d.set(newValue, forKey: "contSection") } }
    var continueCarry: Data? { get { d.data(forKey: "contCarry") } set { d.set(newValue, forKey: "contCarry") } }
    var cheatAmmo: Bool { get { d.bool(forKey: "cheatAmmo") } set { d.set(newValue, forKey: "cheatAmmo") } }
    var cheatMorale: Bool { get { d.bool(forKey: "cheatMorale") } set { d.set(newValue, forKey: "cheatMorale") } }
    var cheatInvulnerable: Bool { get { d.bool(forKey: "cheatInvuln") } set { d.set(newValue, forKey: "cheatInvuln") } }
    var adfBookmark: Data? { get { d.data(forKey: "adf") } set { d.set(newValue, forKey: "adf") } }
}
