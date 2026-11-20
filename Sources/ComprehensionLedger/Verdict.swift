/// What is missing from a decision record.
public enum RecordProblem: Equatable, Sendable {
    case blankProblem
    case blankChoice
    case noRejectedAlternative
    case rejectedAlternativeWithoutReason(option: String)
    case noInvariant
}

/// Why a change was blocked. A blocked change changes nothing in the ledger.
public enum BlockReason: Equatable, Sendable {
    case emptyChange
    case blankID
    case blankIdentity
    case invalidPath(String)
    case invalidLineCount(path: String, lines: Int)
    case missingRecord(module: String)
    case incompleteRecord(module: String, problems: [RecordProblem])
    /// Accepting the change would take the module's debt past its budget.
    case explainBackRequired(module: String, debt: Int, incoming: Int, budget: Int)
    /// The change alone is larger than the module's budget, so no
    /// explain-back can make room for it. Split it.
    case changeLargerThanBudget(module: String, incoming: Int, budget: Int)
}

/// The ledger's answer for one change.
public enum Verdict: Equatable, Sendable {
    /// Accepted. `debtAdded` lists the agent-written lines added to each
    /// metered module (empty when nothing was metered).
    case accepted(debtAdded: [String: Int])
    case blocked([BlockReason])

    public var isAccepted: Bool {
        if case .accepted = self { return true }
        return false
    }
}

/// Errors from building a ledger or recording an explain-back.
public enum LedgerError: Error, Equatable, Sendable {
    case noRules
    case blankModuleName
    case duplicateModuleName(String)
    case invalidPrefix(String)
    case duplicatePrefix(String)
    case nonPositiveBudget(module: String)
    case unknownModule(String)
    case moduleNotMetered(String)
    case blankExplainBackField
    case witnessIsExplainer
}
