import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

private func fail(_ message: String) -> Never {
    require(false, message)
    fatalError("unreachable")
}

private func tryOrFail<T>(_ operation: () throws -> T, _ message: String) -> T {
    do { return try operation() } catch { fail(message) }
}

private final class ReservationSink: @unchecked Sendable {
    private let lock = NSLock()
    private var storedPermits: [PaneSurfaceAdmissionPermit] = []
    private var storedErrors: [PaneSurfaceAdmissionError] = []

    func append(_ permit: PaneSurfaceAdmissionPermit) {
        lock.lock()
        storedPermits.append(permit)
        lock.unlock()
    }

    func append(_ error: PaneSurfaceAdmissionError) {
        lock.lock()
        storedErrors.append(error)
        lock.unlock()
    }

    func snapshot() -> (
        permits: [PaneSurfaceAdmissionPermit],
        errors: [PaneSurfaceAdmissionError]
    ) {
        lock.lock()
        defer { lock.unlock() }
        return (storedPermits, storedErrors)
    }
}

private enum SyntheticAllocationError: Error { case failed }

@main
private enum PaneSurfaceAdmissionLedgerFixture {
    static func main() {
        concurrentNPlusOneIsAtomic()
        activeAndCandidateBudgetsAreSeparate()
        candidateContentionIsProcessWide()
        permitReleaseIsExactlyOnce()
        permitDeinitReleases()
        failedAllocationRollsBack()
        hardUserAdmissionIsDisabled()
        print("PASS: process-wide pane surface ledger atomically enforces 4 active / 1 candidate slots")
    }

    private static func concurrentNPlusOneIsAtomic() {
        let ledger = emptyLedger()
        let requestCount = PaneSurfaceAdmissionLedger.visibleSurfaceLimit + 1
        let start = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        let queue = DispatchQueue(
            label: "works.ourocode.surface-admission-fixture",
            attributes: .concurrent
        )
        let sink = ReservationSink()

        for _ in 0..<requestCount {
            group.enter()
            queue.async {
                start.wait()
                do {
                    sink.append(try ledger.reserveActive())
                } catch let error as PaneSurfaceAdmissionError {
                    sink.append(error)
                } catch {
                    fail("active reservation returned an unrelated error")
                }
                group.leave()
            }
        }
        for _ in 0..<requestCount { start.signal() }
        group.wait()

        let result = sink.snapshot()
        require(
            result.permits.count == PaneSurfaceAdmissionLedger.visibleSurfaceLimit,
            "concurrent N+1 active reservation did not stop exactly at four"
        )
        require(
            result.errors == [
                .visibleSurfaceLimitReached(
                    limit: PaneSurfaceAdmissionLedger.visibleSurfaceLimit
                )
            ],
            "concurrent N+1 active reservation returned the wrong rejection"
        )
        require(
            ledger.snapshot.activeSurfaceCount == PaneSurfaceAdmissionLedger.visibleSurfaceLimit,
            "active ledger count diverged from retained permits"
        )
        result.permits.forEach { $0.release() }
        requireEmpty(ledger, "N+1 fixture leaked active permits")
    }

    private static func activeAndCandidateBudgetsAreSeparate() {
        let ledger = emptyLedger()
        let active = tryOrFail({ try ledger.reserveActive() }, "active reservation failed")
        let candidate = tryOrFail({ try ledger.reserveCandidate() }, "candidate reservation failed")
        let snapshot = ledger.snapshot
        require(snapshot.activeSurfaceCount == 1, "active surface was not counted separately")
        require(snapshot.candidateSurfaceCount == 1, "candidate surface was not counted separately")
        active.release()
        candidate.release()
        requireEmpty(ledger, "separate active/candidate permits leaked")
    }

    private static func candidateContentionIsProcessWide() {
        let ledger = emptyLedger()
        let candidate = tryOrFail({ try ledger.reserveCandidate() }, "first candidate reservation failed")
        do {
            _ = try ledger.reserveCandidate()
            fail("second concurrent candidate reservation was admitted")
        } catch let error as PaneSurfaceAdmissionError {
            require(
                error == .candidateSurfaceBusy(
                    limit: PaneSurfaceAdmissionLedger.candidateSurfaceLimit
                ),
                "candidate contention returned the wrong rejection"
            )
        } catch {
            fail("candidate contention returned an unrelated error")
        }
        candidate.release()
        let reopened = tryOrFail({ try ledger.reserveCandidate() }, "candidate slot did not reopen")
        reopened.release()
        requireEmpty(ledger, "candidate contention fixture leaked a permit")
    }

    private static func permitReleaseIsExactlyOnce() {
        let ledger = emptyLedger()
        let permit = tryOrFail({ try ledger.reserveActive() }, "double-release reservation failed")
        permit.release()
        permit.release()
        requireEmpty(ledger, "double release changed the ledger after the first release")
    }

    private static func permitDeinitReleases() {
        let ledger = emptyLedger()
        do {
            let permit = tryOrFail({ try ledger.reserveActive() }, "deinit reservation failed")
            withExtendedLifetime(permit) {}
        }
        requireEmpty(ledger, "permit deinit did not release its active slot")
    }

    private static func failedAllocationRollsBack() {
        let ledger = emptyLedger()
        do {
            let permit = tryOrFail({ try ledger.reserveCandidate() }, "rollback reservation failed")
            _ = permit
            throw SyntheticAllocationError.failed
        } catch SyntheticAllocationError.failed {
            // Scope exit models an allocator throwing before publishing its candidate.
        } catch {
            fail("synthetic allocation returned an unexpected error")
        }
        requireEmpty(ledger, "failed allocation did not roll its permit back")
    }

    private static func hardUserAdmissionIsDisabled() {
        let ledger = emptyLedger()
        do {
            _ = try ledger.reserveActive(requestedTier: .hard)
            fail("hard 5-8 admission was exposed before benchmark approval")
        } catch let error as PaneSurfaceAdmissionError {
            require(
                error == .hardAdmissionDisabled(normalLimit: 4, hardLimit: 8),
                "hard admission returned the wrong disabled-tier error"
            )
        } catch {
            fail("hard admission returned an unrelated error")
        }
        requireEmpty(ledger, "disabled hard admission consumed a slot")
    }

    private static func emptyLedger() -> PaneSurfaceAdmissionLedger {
        let ledger = PaneSurfaceAdmissionLedger.shared
        requireEmpty(ledger, "fixture began with a leaked process reservation")
        return ledger
    }

    private static func requireEmpty(
        _ ledger: PaneSurfaceAdmissionLedger,
        _ message: String
    ) {
        let snapshot = ledger.snapshot
        require(snapshot.activeSurfaceCount == 0, message)
        require(snapshot.candidateSurfaceCount == 0, message)
    }
}
