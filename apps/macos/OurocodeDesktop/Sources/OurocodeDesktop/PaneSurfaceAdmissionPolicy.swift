import Foundation

/// Explicit capacity tier requested before allocating a pane surface.
enum PaneSurfaceAdmissionTier: Equatable, Sendable {
    case normal
    case hard
}

enum PaneSurfaceAdmissionDecision: Equatable, Sendable {
    case admitted(tier: PaneSurfaceAdmissionTier)
    case requiresExplicitHardAdmission(normalLimit: Int, requestedTotal: Int)
    case deniedHardLimit(hardLimit: Int, requestedTotal: Int)
    case invalidCount
}

/// Pure pane-surface capacity preflight.
///
/// This value performs checked arithmetic only; it does not reserve capacity
/// and must never be used as a production concurrency gate. The process-wide
/// ledger below is the single atomic allocation entrypoint.
struct PaneSurfaceAdmissionPolicy: Equatable, Sendable {
    static let normalLimit = 4
    static let hardLimit = 8
    static let standard = PaneSurfaceAdmissionPolicy()

    func decision(
        currentSurfaceCount: Int,
        additionalSurfaceCount: Int = 1,
        requestedTier: PaneSurfaceAdmissionTier = .normal
    ) -> PaneSurfaceAdmissionDecision {
        guard currentSurfaceCount >= 0, additionalSurfaceCount > 0 else {
            return .invalidCount
        }

        let total = currentSurfaceCount.addingReportingOverflow(additionalSurfaceCount)
        guard !total.overflow else {
            return .deniedHardLimit(
                hardLimit: Self.hardLimit,
                requestedTotal: Int.max
            )
        }

        let requestedTotal = total.partialValue
        guard requestedTotal <= Self.hardLimit else {
            return .deniedHardLimit(
                hardLimit: Self.hardLimit,
                requestedTotal: requestedTotal
            )
        }

        if requestedTotal <= Self.normalLimit {
            return .admitted(tier: .normal)
        }
        if requestedTier == .hard {
            return .admitted(tier: .hard)
        }
        return .requiresExplicitHardAdmission(
            normalLimit: Self.normalLimit,
            requestedTotal: requestedTotal
        )
    }
}

enum PaneSurfaceAdmissionError: Error, Equatable, LocalizedError {
    case visibleSurfaceLimitReached(limit: Int)
    case candidateSurfaceBusy(limit: Int)
    case hardAdmissionDisabled(normalLimit: Int, hardLimit: Int)

    var errorDescription: String? {
        switch self {
        case let .visibleSurfaceLimitReached(limit):
            return "Ourocode can show up to \(limit) terminal panes at once. Close a pane before opening another."
        case let .candidateSurfaceBusy(limit):
            return "Ourocode is already preparing its \(limit) allowed recovery surface. Try again after the current transition finishes."
        case let .hardAdmissionDisabled(normalLimit, hardLimit):
            return "The experimental \(normalLimit + 1)–\(hardLimit) pane tier is unavailable until its memory benchmark is approved."
        }
    }
}

enum PaneSurfaceReservationKind: Equatable, Sendable {
    case active
    case candidate
}

struct PaneSurfaceAdmissionLedgerSnapshot: Equatable, Sendable {
    let activeSurfaceCount: Int
    let candidateSurfaceCount: Int
    let visibleSurfaceLimit: Int
    let candidateSurfaceLimit: Int
}

/// One process slot owned for exactly the lifetime of a surface allocation.
///
/// `release()` is idempotent and `deinit` is the rollback path for throwing
/// allocations. The ledger also tracks reservation identities, so even an
/// accidental duplicate release cannot decrement a different owner's slot.
final class PaneSurfaceAdmissionPermit: @unchecked Sendable {
    let kind: PaneSurfaceReservationKind

    private let id: UUID
    private let ledger: PaneSurfaceAdmissionLedger
    private let lock = NSLock()
    private var released = false

    fileprivate init(
        id: UUID,
        kind: PaneSurfaceReservationKind,
        ledger: PaneSurfaceAdmissionLedger
    ) {
        self.id = id
        self.kind = kind
        self.ledger = ledger
    }

    func release() {
        lock.lock()
        guard !released else {
            lock.unlock()
            return
        }
        released = true
        lock.unlock()
        ledger.release(id: id, kind: kind)
    }

    deinit {
        release()
    }
}

/// Atomic process-wide slot ledger for real terminal surface allocations.
///
/// The budget is deliberately expressed in slots, not guessed memory bytes.
/// Production permits at most four visible surfaces and one transient recovery
/// candidate across every coordinator in the process. The policy's five-to-
/// eight hard tier remains unavailable until a same-workload benchmark supplies
/// an evidence-backed memory budget.
final class PaneSurfaceAdmissionLedger: @unchecked Sendable {
    static let shared = PaneSurfaceAdmissionLedger()

    static let visibleSurfaceLimit = PaneSurfaceAdmissionPolicy.normalLimit
    static let candidateSurfaceLimit = 1

    private let lock = NSLock()
    private var activeReservations: Set<UUID> = []
    private var candidateReservations: Set<UUID> = []

    /// Independent ledgers would let callers multiply the process budget.
    /// Keep construction inside this type so `shared` is the only entrypoint.
    private init() {}

    func reserveActive(
        requestedTier: PaneSurfaceAdmissionTier = .normal
    ) throws -> PaneSurfaceAdmissionPermit {
        lock.lock()
        defer { lock.unlock() }

        guard requestedTier == .normal else {
            throw PaneSurfaceAdmissionError.hardAdmissionDisabled(
                normalLimit: Self.visibleSurfaceLimit,
                hardLimit: PaneSurfaceAdmissionPolicy.hardLimit
            )
        }
        guard activeReservations.count < Self.visibleSurfaceLimit else {
            throw PaneSurfaceAdmissionError.visibleSurfaceLimitReached(
                limit: Self.visibleSurfaceLimit
            )
        }

        let id = UUID()
        activeReservations.insert(id)
        return PaneSurfaceAdmissionPermit(id: id, kind: .active, ledger: self)
    }

    func reserveCandidate() throws -> PaneSurfaceAdmissionPermit {
        lock.lock()
        defer { lock.unlock() }

        guard candidateReservations.count < Self.candidateSurfaceLimit else {
            throw PaneSurfaceAdmissionError.candidateSurfaceBusy(
                limit: Self.candidateSurfaceLimit
            )
        }

        let id = UUID()
        candidateReservations.insert(id)
        return PaneSurfaceAdmissionPermit(id: id, kind: .candidate, ledger: self)
    }

    var snapshot: PaneSurfaceAdmissionLedgerSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return PaneSurfaceAdmissionLedgerSnapshot(
            activeSurfaceCount: activeReservations.count,
            candidateSurfaceCount: candidateReservations.count,
            visibleSurfaceLimit: Self.visibleSurfaceLimit,
            candidateSurfaceLimit: Self.candidateSurfaceLimit
        )
    }

    fileprivate func release(id: UUID, kind: PaneSurfaceReservationKind) {
        lock.lock()
        defer { lock.unlock() }
        switch kind {
        case .active:
            activeReservations.remove(id)
        case .candidate:
            candidateReservations.remove(id)
        }
    }
}
