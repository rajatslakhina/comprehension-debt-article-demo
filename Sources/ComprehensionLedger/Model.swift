/// Who produced a change.
///
/// Identities are plain strings. The ledger trusts them as given: it is a
/// process gate for a team, not an authentication system.
public enum Author: Hashable, Sendable {
    /// A person wrote the change by hand.
    case human(String)
    /// A coding agent wrote the change while a person drove it.
    case agent(name: String, drivenBy: String)

    public var isAgent: Bool {
        if case .agent = self { return true }
        return false
    }
}

/// How much understanding a module must keep, as a team rule.
public enum ExplainTier: Equatable, Sendable {
    /// No requirements. Agent changes are accepted as they are.
    case open
    /// Agent changes must carry a decision record with at least one
    /// rejected alternative.
    case recordRequired
    /// Agent changes must carry a decision record with at least one rejected
    /// alternative and one invariant, and their changed lines accrue as
    /// comprehension debt. Once the next change would push the debt past
    /// `debtBudget`, the module needs a human explain-back first.
    case mustStayExplainable(debtBudget: Int)
}

/// A module the team has made a rule about, identified by a path prefix.
public struct ModuleRule: Equatable, Sendable {
    public let name: String
    public let pathPrefix: String
    public let tier: ExplainTier

    public init(name: String, pathPrefix: String, tier: ExplainTier) {
        self.name = name
        self.pathPrefix = pathPrefix
        self.tier = tier
    }
}

/// An option the author considered and did not take, with the reason.
public struct RejectedAlternative: Equatable, Sendable {
    public let option: String
    public let reason: String

    public init(option: String, reason: String) {
        self.option = option
        self.reason = reason
    }
}

/// The "why" that travels with an agent-written change.
///
/// The ledger checks that a record is complete. It cannot check that the
/// record is true; that is what the explain-back is for.
public struct DecisionRecord: Equatable, Sendable {
    public let problem: String
    public let chosen: String
    public let rejected: [RejectedAlternative]
    public let invariants: [String]

    public init(problem: String, chosen: String, rejected: [RejectedAlternative], invariants: [String]) {
        self.problem = problem
        self.chosen = chosen
        self.rejected = rejected
        self.invariants = invariants
    }
}

/// One file in a change and how many lines it adds or modifies.
public struct FileDiff: Equatable, Sendable {
    public let path: String
    public let linesChanged: Int

    public init(path: String, linesChanged: Int) {
        self.path = path
        self.linesChanged = linesChanged
    }
}

/// A proposed change, such as a pull request.
public struct Change: Equatable, Sendable {
    public let id: String
    public let author: Author
    public let files: [FileDiff]
    public let record: DecisionRecord?

    public init(id: String, author: Author, files: [FileDiff], record: DecisionRecord? = nil) {
        self.id = id
        self.author = author
        self.files = files
        self.record = record
    }
}

/// A person explains a module's recent changes, without the agent, to a
/// second person who signs it off.
public struct ExplainBack: Equatable, Sendable {
    public let module: String
    public let explainer: String
    public let witness: String
    public let summary: String

    public init(module: String, explainer: String, witness: String, summary: String) {
        self.module = module
        self.explainer = explainer
        self.witness = witness
        self.summary = summary
    }
}
