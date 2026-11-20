/// Something that happened in the ledger, in order.
public enum LedgerEvent: Equatable, Sendable {
    case accepted(changeID: String, debtAdded: [String: Int])
    case blocked(changeID: String, reasons: [BlockReason])
    case explainedBack(module: String, explainer: String, witness: String, cleared: Int)
}

/// Meters comprehension debt per module and gates agent-written changes.
///
/// Rules, per module tier:
/// - `.open`: nothing is required.
/// - `.recordRequired`: agent changes need a complete decision record.
/// - `.mustStayExplainable`: agent changes need a complete record with an
///   invariant, and their lines add to the module's debt. A change that would
///   take the debt past the budget is blocked until a human explain-back
///   clears it.
///
/// Human-written changes need no record and add no debt. They do not clear
/// debt either: only an explain-back does.
///
/// A change is judged as a whole. If any file blocks it, nothing is applied.
/// The ledger is a value type and is not shared between threads.
public struct ComprehensionLedger: Equatable, Sendable {
    public let rules: [ModuleRule]
    public private(set) var debt: [String: Int]
    public private(set) var explainers: [String: Set<String>]
    public private(set) var history: [LedgerEvent]

    /// Canonical prefixes, longest first, so the most specific rule wins.
    private let resolvedRules: [(prefix: String, rule: ModuleRule)]

    public static func == (lhs: ComprehensionLedger, rhs: ComprehensionLedger) -> Bool {
        lhs.rules == rhs.rules && lhs.debt == rhs.debt
            && lhs.explainers == rhs.explainers && lhs.history == rhs.history
    }

    public init(rules: [ModuleRule]) throws {
        guard !rules.isEmpty else { throw LedgerError.noRules }
        var names = Set<String>()
        var prefixes = Set<String>()
        var resolved: [(prefix: String, rule: ModuleRule)] = []
        for rule in rules {
            guard !rule.name.isBlank else { throw LedgerError.blankModuleName }
            guard names.insert(rule.name).inserted else { throw LedgerError.duplicateModuleName(rule.name) }
            guard let prefix = PathResolver.canonical(rule.pathPrefix) else {
                throw LedgerError.invalidPrefix(rule.pathPrefix)
            }
            guard prefixes.insert(prefix).inserted else { throw LedgerError.duplicatePrefix(prefix) }
            if case .mustStayExplainable(let budget) = rule.tier, budget <= 0 {
                throw LedgerError.nonPositiveBudget(module: rule.name)
            }
            resolved.append((prefix, rule))
        }
        self.rules = rules
        self.resolvedRules = resolved.sorted { $0.prefix.count > $1.prefix.count }
        self.debt = [:]
        self.explainers = [:]
        self.history = []
    }

    /// The rule that governs a repository path, or `nil` if no rule covers it.
    public func rule(for path: String) -> ModuleRule? {
        guard let canonical = PathResolver.canonical(path) else { return nil }
        return rule(forCanonical: canonical)
    }

    private func rule(forCanonical path: String) -> ModuleRule? {
        resolvedRules.first { PathResolver.path(path, isInside: $0.prefix) }?.rule
    }

    public func debt(for module: String) -> Int { debt[module] ?? 0 }

    /// Judges a change without changing the ledger.
    public func evaluate(_ change: Change) -> Verdict {
        var reasons: [BlockReason] = []
        if change.id.isBlank { reasons.append(.blankID) }
        if change.files.isEmpty { reasons.append(.emptyChange) }
        switch change.author {
        case .human(let name):
            if name.isBlank { reasons.append(.blankIdentity) }
        case .agent(let name, let driver):
            if name.isBlank || driver.isBlank { reasons.append(.blankIdentity) }
        }

        // Lines per governed module, in first-seen order for stable output.
        var linesByModule: [String: Int] = [:]
        var touched: [ModuleRule] = []
        for file in change.files {
            guard file.linesChanged >= 0 else {
                reasons.append(.invalidLineCount(path: file.path, lines: file.linesChanged))
                continue
            }
            guard let canonical = PathResolver.canonical(file.path) else {
                reasons.append(.invalidPath(file.path))
                continue
            }
            guard let rule = rule(forCanonical: canonical) else {
                continue
            }
            if linesByModule[rule.name] == nil { touched.append(rule) }
            linesByModule[rule.name, default: 0] += file.linesChanged
        }

        var debtAdded: [String: Int] = [:]
        if change.author.isAgent {
            for rule in touched {
                let incoming = linesByModule[rule.name] ?? 0
                switch rule.tier {
                case .open:
                    continue
                case .recordRequired:
                    reasons += recordReasons(change.record, module: rule.name, needsInvariant: false)
                case .mustStayExplainable(let budget):
                    reasons += recordReasons(change.record, module: rule.name, needsInvariant: true)
                    let current = debt(for: rule.name)
                    if incoming > budget {
                        reasons.append(.changeLargerThanBudget(module: rule.name, incoming: incoming, budget: budget))
                    } else if current + incoming > budget {
                        reasons.append(.explainBackRequired(module: rule.name, debt: current, incoming: incoming, budget: budget))
                    }
                    if incoming > 0 { debtAdded[rule.name] = incoming }
                }
            }
        }
        return reasons.isEmpty ? .accepted(debtAdded: debtAdded) : .blocked(reasons)
    }

    /// Judges a change and, if it is accepted, adds its debt.
    @discardableResult
    public mutating func submit(_ change: Change) -> Verdict {
        let verdict = evaluate(change)
        switch verdict {
        case .accepted(let added):
            for (module, lines) in added { debt[module, default: 0] += lines }
            history.append(.accepted(changeID: change.id, debtAdded: added))
        case .blocked(let reasons):
            history.append(.blocked(changeID: change.id, reasons: reasons))
        }
        return verdict
    }

    /// Clears a metered module's debt after a human explain-back.
    /// Returns the number of lines cleared.
    @discardableResult
    public mutating func recordExplainBack(_ explainBack: ExplainBack) throws -> Int {
        guard let rule = rules.first(where: { $0.name == explainBack.module }) else {
            throw LedgerError.unknownModule(explainBack.module)
        }
        guard case .mustStayExplainable = rule.tier else { throw LedgerError.moduleNotMetered(rule.name) }
        let explainer = explainBack.explainer.trimmingWhitespace
        let witness = explainBack.witness.trimmingWhitespace
        guard !explainer.isEmpty, !witness.isEmpty, !explainBack.summary.isBlank else {
            throw LedgerError.blankExplainBackField
        }
        guard explainer.lowercased() != witness.lowercased() else { throw LedgerError.witnessIsExplainer }
        let cleared = debt(for: rule.name)
        debt[rule.name] = 0
        explainers[rule.name, default: []].insert(explainer)
        history.append(.explainedBack(module: rule.name, explainer: explainer, witness: witness, cleared: cleared))
        return cleared
    }

    private func recordReasons(_ record: DecisionRecord?, module: String, needsInvariant: Bool) -> [BlockReason] {
        guard let record else { return [.missingRecord(module: module)] }
        var problems: [RecordProblem] = []
        if record.problem.isBlank { problems.append(.blankProblem) }
        if record.chosen.isBlank { problems.append(.blankChoice) }
        let named = record.rejected.filter { !$0.option.isBlank }
        if named.isEmpty { problems.append(.noRejectedAlternative) }
        for alternative in named where alternative.reason.isBlank {
            problems.append(.rejectedAlternativeWithoutReason(option: alternative.option))
        }
        if needsInvariant && !record.invariants.contains(where: { !$0.isBlank }) {
            problems.append(.noInvariant)
        }
        return problems.isEmpty ? [] : [.incompleteRecord(module: module, problems: problems)]
    }
}
