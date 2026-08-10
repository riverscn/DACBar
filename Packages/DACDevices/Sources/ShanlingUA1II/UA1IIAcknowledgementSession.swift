import Foundation

extension ShanlingUA1II {
    /// Tracks UA1 II write acknowledgements independently of IOHID delivery.
    ///
    /// The wire protocol echoes only `(command, value)`, not a submission ID.
    /// A timed-out submission therefore leaves one acknowledgement debt behind.
    /// Matching that debt before an identical retry prevents an old ACK from
    /// confirming the retry and gives every submission at most one terminal
    /// result: either `timeout` or `acknowledge`, never both.
    struct AcknowledgementSession {
        typealias SubmissionID = Int

        enum Acknowledgement: Equatable {
            case confirmed(SubmissionID, Write)
            case ignoredLate(SubmissionID, Write)
            case unmatched(Write)
        }

        private struct Pending {
            let id: SubmissionID
            let write: Write
        }

        private struct AcknowledgementDebt {
            let id: SubmissionID
            let write: Write
            let expiresAt: ContinuousClock.Instant
        }

        private let debtRetention: Duration
        private let debtCapacity: Int
        private var nextID: SubmissionID = 0
        private var pending: [Pending] = []
        private var debts: [AcknowledgementDebt] = []

        init(debtRetention: Duration, debtCapacity: Int = 16) {
            self.debtRetention = debtRetention
            self.debtCapacity = max(1, debtCapacity)
        }

        mutating func reserve(_ write: Write) -> SubmissionID {
            nextID += 1
            pending.append(Pending(id: nextID, write: write))
            return nextID
        }

        mutating func acknowledge(
            _ write: Write,
            now: ContinuousClock.Instant = .now
        ) -> Acknowledgement {
            pruneDebts(now: now)

            // The device preserves report order. An ACK owed by an earlier
            // timed-out submission must be consumed before an identical retry.
            if let index = debts.firstIndex(where: { $0.write == write }) {
                let debt = debts.remove(at: index)
                return .ignoredLate(debt.id, debt.write)
            }
            if let index = pending.firstIndex(where: { $0.write == write }) {
                let submission = pending.remove(at: index)
                return .confirmed(submission.id, submission.write)
            }
            return .unmatched(write)
        }

        /// Returns the write only on its first transition to the dropped state.
        mutating func timeout(
            _ id: SubmissionID,
            now: ContinuousClock.Instant = .now
        ) -> Write? {
            pruneDebts(now: now)
            guard let index = pending.firstIndex(where: { $0.id == id })
            else { return nil }
            let submission = pending.remove(at: index)
            debts.append(AcknowledgementDebt(
                id: submission.id,
                write: submission.write,
                expiresAt: now + debtRetention))
            if debts.count > debtCapacity {
                debts.removeFirst(debts.count - debtCapacity)
            }
            return submission.write
        }

        /// Removes a submission that never reached a successful IOHID issue.
        mutating func cancel(_ id: SubmissionID) {
            guard let index = pending.firstIndex(where: { $0.id == id })
            else { return }
            pending.remove(at: index)
        }

        func contains(_ id: SubmissionID) -> Bool {
            pending.contains(where: { $0.id == id })
        }

        mutating func removeAll() {
            pending.removeAll()
            debts.removeAll()
        }

        private mutating func pruneDebts(now: ContinuousClock.Instant) {
            debts.removeAll { $0.expiresAt <= now }
        }
    }
}
