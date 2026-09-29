import AppKit
import PlatoonCore

// App-side extension API for feature owners (wave-2 agents). Everything here runs on the MAIN thread.
//
// Threading: the emulation runs from MTKView.draw on the main thread. `onFrame` observers run inside
// Machine.frameHook (start of every emulated frame, several per display frame under fast-forward); `onDisplay`
// observers run once per displayed frame after the emulation step. In both, the game thread is parked, so reading
// game RAM (machine.memory) is race-free. Observers must NOT write game RAM unless they implement an explicit,
// default-off gameplay option (and then call `markAssisted`).
//
// Registration without touching AppDelegate: put your code in your own stub file
//   Menus/Menu<Owner>.swift   -> `install(_ app:)` hook (called once at launch) + menu contributions
//   Prefs/Prefs<Owner>.swift  -> declarative preference sections
// and use AppServices.shared from there.

/// Why the emulation is paused. The game runs only while the set is empty.
enum PauseReason: Hashable {
    case user          // ⌘P / Game menu
    case menu          // the pause-menu overlay (M1)
    case focus         // window lost focus / minimised / app hidden (S4, optional)
    case sleep         // system or display sleep (S4, optional)
    case controller    // the game controller disconnected (S4, optional)
    case dialog        // a host dialog/sheet/modal alert is up (S4, optional)
    case custom(String) // feature-defined (e.g. a modal assist overlay)
}

/// Opaque handle returned by observer registrations; call `cancel()` (or drop it via `AppServices.remove`).
final class ObserverToken {
    fileprivate let id: Int
    fileprivate weak var owner: AppServices?
    fileprivate init(_ id: Int, _ owner: AppServices) { self.id = id; self.owner = owner }
    func cancel() { owner?.remove(self) }
}

/// Per-frame view of the running game handed to observers. Valid only during the callback.
struct FrameContext {
    let host: GameHost
    var machine: Machine { host.machine }
    var memory: Memory { host.machine.memory }
    /// Emulated frame number (Machine.frameCount at the start of this frame).
    var frame: UInt64 { host.machine.frameCount }
    /// Load section currently being played (0/1/2); nil on title / loading / game over.
    var section: Int? { host.currentSection }
    /// F1: what is on screen (core GameProbe context, refreshed every frame): screen, area, men, items, timer,
    /// message queue, per-section RAM views, decoded text screen, assisted state ...
    var game: GameContext { host.probe.context }
}

/// Snapshot / quick-save provider (implemented by the snapshot agent in SaveStates*.swift and installed with
/// `AppServices.shared.snapshots = ...` from its install hook). The pause menu and Game menu use it when set.
protocol SnapshotService: AnyObject {
    /// Number of save slots shown in the pause menu.
    var slotCount: Int { get }
    /// Short description of a slot for menus ("Tunnels — 12 Sep 14:02 — 01250 pts"), nil = empty slot.
    func slotSummary(_ slot: Int) -> String?
    /// Optional thumbnail for the slot (shown in the pause menu).
    func slotThumbnail(_ slot: Int) -> NSImage?
    /// Request a save into `slot`; the provider takes it at the next safe point and calls `done` (main thread)
    /// with nil on success or a user-facing error message.
    func save(slot: Int, done: @escaping (String?) -> Void)
    /// Restore `slot`; `done` as for save.
    func load(slot: Int, done: @escaping (String?) -> Void)
    /// Whether saving is possible right now (e.g. false on the title screen); a reason string when not.
    var saveUnavailableReason: String? { get }
}

extension SnapshotService {
    func slotThumbnail(_ slot: Int) -> NSImage? { nil }
    var saveUnavailableReason: String? { nil }
}

/// An extra entry in the pause menu (M1), contributed by a feature (e.g. "Message Log", "Tunnel Map").
struct PauseMenuItem {
    var id: String
    var title: () -> String
    /// Lower sorts first. Built-ins: Resume 0, Save/Load 100-199, Restart 300, Options 400, Controls 410,
    /// Abort to title 900, Quit 1000. Feature panels: 200-299 suggested.
    var order: Int
    var isEnabled: () -> Bool = { true }
    /// Runs on selection. Return true to close the pause menu and resume, false to keep it open.
    var action: () -> Bool
}

final class AppServices {
    static let shared = AppServices()
    private init() {}

    /// The app delegate (window, renderer); set at launch.
    weak var app: AppDelegate?
    /// The running game host (nil until a disk is loaded). The GameHost object survives resets; its `machine`
    /// is replaced by every reset (observe `onReset`).
    var host: GameHost? { app?.host }
    var window: NSWindow? { app?.window }
    /// The assist overlay layer (F3).
    let overlay = OverlayManager()
    /// F1/F2 (core): context + game-event observers (onMessage, onFx, onScore, onDeath, addObserver ...). The
    /// probe object lives as long as the GameHost and survives resets. nil before a disk is loaded — use
    /// onHostReady { host in host.probe.onMessage { ... } } to register early.
    var probe: GameProbe? { host?.probe }
    /// Quick-save provider (snapshot agent). nil = save/load entries hidden.
    var snapshots: SnapshotService?

    // MARK: pause / control
    func pause(_ r: PauseReason) { host?.pause(r) }
    func resume(_ r: PauseReason) { host?.resume(r) }
    var isPaused: Bool { host?.paused ?? false }
    func tapKey(_ amigaKey: UInt8) { host?.tapKey(amigaKey) }
    /// Full reset; optional start section / carry (see GameHost.reset). Marks the run assisted when it starts
    /// mid-game (roadmap S5).
    func reset(startSection: Int? = nil, carry: [UInt8]? = nil) { host?.reset(startSection: startSection, carry: carry) }
    func showPauseMenu() { app?.showPauseMenu() }
    func openPreferences(tab: PrefTab? = nil) { app?.openPreferences(tab: tab) }
    /// Short transient message in the overlay (never in screenshots).
    func toast(_ text: String, seconds: Double = 2.0) { overlay.toast(text, seconds: seconds) }
    /// Marks the current run as assisted/tainted (F4/S5): it must not enter the original hiscore table.
    func markAssisted(_ reason: String) { host?.markAssisted(reason) }

    // MARK: observers
    private var nextID = 0
    private(set) var frameObservers: [(Int, (FrameContext) -> Void)] = []
    private(set) var displayObservers: [(Int, (FrameContext) -> Void)] = []
    private(set) var resetObservers: [(Int, (GameHost) -> Void)] = []
    private(set) var sectionObservers: [(Int, (Int) -> Void)] = []
    private(set) var pauseObservers: [(Int, (Bool) -> Void)] = []
    private(set) var hostObservers: [(Int, (GameHost) -> Void)] = []
    private(set) var pauseMenuItems: [PauseMenuItem] = []

    private func token() -> ObserverToken { nextID += 1; return ObserverToken(nextID, self) }

    /// Every emulated frame (inside Machine.frameHook, before the frame's lines run).
    @discardableResult func onFrame(_ f: @escaping (FrameContext) -> Void) -> ObserverToken {
        let t = token(); frameObservers.append((t.id, f)); return t
    }
    /// Every displayed frame, after the emulation step (also while paused, so overlays can animate).
    @discardableResult func onDisplay(_ f: @escaping (FrameContext) -> Void) -> ObserverToken {
        let t = token(); displayObservers.append((t.id, f)); return t
    }
    /// After every reset (new Machine) — drop cached per-run state here.
    @discardableResult func onReset(_ f: @escaping (GameHost) -> Void) -> ObserverToken {
        let t = token(); resetObservers.append((t.id, f)); return t
    }
    /// When a load section starts (0 jungle & village, 1 tunnels & flare, 2 final jungle & foxhole). Delivered on
    /// the main thread at the next frame boundary (the game reports it from the game thread).
    @discardableResult func onSectionStart(_ f: @escaping (Int) -> Void) -> ObserverToken {
        let t = token(); sectionObservers.append((t.id, f)); return t
    }
    /// Paused state changed (true = now paused).
    @discardableResult func onPauseChange(_ f: @escaping (Bool) -> Void) -> ObserverToken {
        let t = token(); pauseObservers.append((t.id, f)); return t
    }
    /// Once, when the GameHost is created (after the disk is loaded). If it already exists, called immediately.
    @discardableResult func onHostReady(_ f: @escaping (GameHost) -> Void) -> ObserverToken {
        let t = token(); hostObservers.append((t.id, f)); if let h = host { f(h) }; return t
    }
    /// Host hotkeys (e.g. hold-to-rewind): consulted for every key event after the modal overlay, Esc (pause
    /// menu) and fast-forward checks, before the game sees the key. Return true to consume.
    /// Arguments: Mac virtual keycode, down, isRepeat.
    var keyHooks: [(UInt16, Bool, Bool) -> Bool] = []
    /// Same for controller buttons (after the modal overlay and fast-forward L3). A consumed press is hidden
    /// from the game until released; the release is delivered to the hooks too.
    var padHooks: [(PadButton, Bool) -> Bool] = []

    func addPauseMenuItem(_ item: PauseMenuItem) {
        pauseMenuItems.removeAll { $0.id == item.id }
        pauseMenuItems.append(item)
    }

    func remove(_ t: ObserverToken) {
        frameObservers.removeAll { $0.0 == t.id }; displayObservers.removeAll { $0.0 == t.id }
        resetObservers.removeAll { $0.0 == t.id }; sectionObservers.removeAll { $0.0 == t.id }
        pauseObservers.removeAll { $0.0 == t.id }; hostObservers.removeAll { $0.0 == t.id }
    }

    // MARK: dispatch (called by GameHost / AppDelegate)
    func dispatchFrame(_ h: GameHost) {
        guard !frameObservers.isEmpty else { return }
        let c = FrameContext(host: h)
        for (_, f) in frameObservers { f(c) }
    }
    func dispatchDisplay(_ h: GameHost) {
        let c = FrameContext(host: h)
        for (_, f) in displayObservers { f(c) }
    }
    func dispatchReset(_ h: GameHost) { for (_, f) in resetObservers { f(h) } }
    func dispatchSection(_ s: Int) { for (_, f) in sectionObservers { f(s) } }
    func dispatchPause(_ p: Bool) { for (_, f) in pauseObservers { f(p) } }
    func dispatchHostReady(_ h: GameHost) { for (_, f) in hostObservers { f(h) } }
}
