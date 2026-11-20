/// The scripted week the demo app plays, and the article describes.
/// Tests pin every outcome, so the demo and the documented week stay in sync with the code.
public enum SampleScenario {
    public static let paymentsBudget = 400

    public static let rules: [ModuleRule] = [
        ModuleRule(name: "Payments", pathPrefix: "Sources/Payments",
                   tier: .mustStayExplainable(debtBudget: paymentsBudget)),
        ModuleRule(name: "Onboarding", pathPrefix: "Sources/Onboarding", tier: .recordRequired),
        ModuleRule(name: "Settings", pathPrefix: "Sources/Settings", tier: .open),
    ]

    public enum Step: Equatable, Sendable {
        case change(Change, note: String)
        case explainBack(ExplainBack, note: String)

        public var note: String {
            switch self {
            case .change(_, let note), .explainBack(_, let note): return note
            }
        }
    }

    static let agent = Author.agent(name: "Claude Code", drivenBy: "Asha")

    static let retryRecord = DecisionRecord(
        problem: "Card payments fail on flaky networks and users retry by hand.",
        chosen: "Retry idempotently with the same idempotency key, three attempts with backoff.",
        rejected: [RejectedAlternative(option: "Retry without a key",
                                       reason: "A timeout after the server charged would charge twice.")],
        invariants: ["Every retry of one checkout reuses one idempotency key."]
    )

    static let receiptRecord = DecisionRecord(
        problem: "Receipts are rebuilt from the cart, which can change after payment.",
        chosen: "Build the receipt from the payment response, not the cart.",
        rejected: [RejectedAlternative(option: "Snapshot the cart at checkout",
                                       reason: "A second source of truth that can disagree with the charge.")],
        invariants: ["A receipt total always equals the captured amount."]
    )

    static let refundRecord = DecisionRecord(
        problem: "Partial refunds round each line separately and drift by a cent.",
        chosen: "Compute the refund in minor units once, then split it across lines.",
        rejected: [RejectedAlternative(option: "Keep Double and round at the end",
                                       reason: "Binary floating point cannot hold most cent amounts exactly.")],
        invariants: ["The sum of line refunds equals the refund total, in minor units."]
    )

    public static let steps: [Step] = [
        .change(Change(id: "PR-101", author: agent,
                       files: [FileDiff(path: "Sources/Payments/RetryPolicy.swift", linesChanged: 180)],
                       record: retryRecord),
                note: "Agent adds payment retries, with a decision record."),
        .change(Change(id: "PR-102", author: agent,
                       files: [FileDiff(path: "Sources/Onboarding/Welcome.swift", linesChanged: 60)]),
                note: "Agent edits onboarding with no decision record."),
        .change(Change(id: "PR-103", author: agent,
                       files: [FileDiff(path: "Sources/Payments/Receipt.swift", linesChanged: 150)],
                       record: receiptRecord),
                note: "Agent rewrites receipts, with a decision record."),
        .change(Change(id: "PR-104", author: agent,
                       files: [FileDiff(path: "Sources/Payments/Refund.swift", linesChanged: 120)],
                       record: refundRecord),
                note: "Agent fixes refund rounding. Payments is near its budget."),
        .explainBack(ExplainBack(module: "Payments", explainer: "Asha", witness: "Ben",
                                 summary: "Retries reuse one key; receipts come from the charge, not the cart."),
                     note: "Asha explains Payments to Ben, without the agent."),
        .change(Change(id: "PR-104", author: agent,
                       files: [FileDiff(path: "Sources/Payments/Refund.swift", linesChanged: 120)],
                       record: refundRecord),
                note: "The same refund change, resubmitted."),
        .change(Change(id: "PR-105", author: agent,
                       files: [FileDiff(path: "Sources/Settings/../Payments/Refund.swift", linesChanged: 40)]),
                note: "Agent routes a Payments edit through a Settings path, with no record."),
    ]

    /// One played step and what the ledger said.
    public struct Outcome: Equatable, Sendable {
        public let step: Step
        public let verdict: Verdict?
        public let cleared: Int?
        public let error: LedgerError?
        public let paymentsDebtAfter: Int
    }

    /// Plays every step on a fresh ledger.
    public static func play() throws -> (ledger: ComprehensionLedger, outcomes: [Outcome]) {
        var ledger = try ComprehensionLedger(rules: rules)
        var outcomes: [Outcome] = []
        for step in steps {
            switch step {
            case .change(let change, _):
                let verdict = ledger.submit(change)
                outcomes.append(Outcome(step: step, verdict: verdict, cleared: nil, error: nil,
                                        paymentsDebtAfter: ledger.debt(for: "Payments")))
            case .explainBack(let explainBack, _):
                do {
                    let cleared = try ledger.recordExplainBack(explainBack)
                    outcomes.append(Outcome(step: step, verdict: nil, cleared: cleared, error: nil,
                                            paymentsDebtAfter: ledger.debt(for: "Payments")))
                } catch let error as LedgerError {
                    outcomes.append(Outcome(step: step, verdict: nil, cleared: nil, error: error,
                                            paymentsDebtAfter: ledger.debt(for: "Payments")))
                }
            }
        }
        return (ledger, outcomes)
    }
}
