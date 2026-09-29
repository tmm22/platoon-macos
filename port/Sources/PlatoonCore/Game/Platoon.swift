import Foundation

/// Shared context for the translated game. Every module adds its routines in an extension.
public final class Platoon {
    public let m: Machine
    public let mem: Memory
    public let chip: Chipset
    public let disk: Disk
    public let input: Input
    /// Host-side enhancement switches (default = original behaviour).
    public var enhancements = Enhancements()
    public var config = GameConfig()
    /// Code addresses that the original stores as data (jump tables, state pointers) -> translation.
    var dispatchTable: [UInt32: () -> Void] = [:]
    public var log: (String) -> Void = { _ in }

    // MARK: host-side kernel state (not part of the original RAM image)

    /// Pending 68000 execution time in cycles (CPU-time model, see KernelSupport.swift).
    var cpuCycles = 0
    /// Stand-in for "d1 of the interrupted code" that the vblank handler adds to the RNG ($10ede).
    /// Translated code may set it where the original's d1 is known; 0 otherwise. Unused with deterministicRNG.
    var interruptedD1: UInt32 = 0
    /// config.startSection has been acted upon (only once, at the first title start).
    var startSectionDone = false
    /// Which load section the loader at $11166 put at $17000 (decides the translated entry for jmp $17000).
    var loadedSection = -1
    /// Emulated disk head cylinder (for the disk timing model of the resident loader).
    var diskCylinder = 0

    public init(machine: Machine) {
        m = machine; mem = machine.memory; chip = machine.chip; disk = machine.disk; input = machine.input
    }

    func register(_ addr: UInt32, _ f: @escaping () -> Void) { dispatchTable[addr] = f }

    /// jsr/jmp through a code pointer held in RAM.
    func call(_ addr: UInt32) {
        guard let f = dispatchTable[addr] else {
            fatalError(String(format: "Platoon: no translation registered for code address $%06X", addr))
        }
        f()
    }
}

public struct Enhancements {
    public init() {}
    public var infiniteMorale = false
    public var infiniteAmmo = false
}
