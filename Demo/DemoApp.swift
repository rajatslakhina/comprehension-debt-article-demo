import SwiftUI
import ComprehensionLedger

@main
struct DemoApp: App {
    var body: some Scene {
        WindowGroup {
            RootView(initial: Screen(launchArgument: UserDefaults.standard.string(forKey: "screen")))
        }
    }
}

enum Screen: String, CaseIterable, Identifiable {
    case week = "The week"
    case modules = "Modules"
    var id: String { rawValue }

    init(launchArgument: String?) {
        self = launchArgument == "modules" ? .modules : .week
    }
}

struct RootView: View {
    @State var screen: Screen
    let played: Result<(ledger: ComprehensionLedger, outcomes: [SampleScenario.Outcome]), Error>

    init(initial: Screen) {
        _screen = State(initialValue: initial)
        played = Result { try SampleScenario.play() }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Screen", selection: $screen) {
                    ForEach(Screen.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 8)

                switch played {
                case .success(let result):
                    switch screen {
                    case .week: WeekView(outcomes: result.outcomes,
                                         scrollToEnd: UserDefaults.standard.bool(forKey: "scrollToEnd"))
                    case .modules: ModulesView(ledger: result.ledger)
                    }
                case .failure(let error):
                    ContentUnavailableView("Could not build the ledger",
                                           systemImage: "exclamationmark.triangle",
                                           description: Text(String(describing: error)))
                }
            }
            .navigationTitle("Comprehension debt")
        }
    }
}

struct WeekView: View {
    let outcomes: [SampleScenario.Outcome]
    var scrollToEnd = false

    var body: some View {
        ScrollViewReader { proxy in
            list.onAppear {
                if scrollToEnd, !outcomes.isEmpty { proxy.scrollTo(outcomes.count - 1, anchor: .bottom) }
            }
        }
    }

    var list: some View {
        List {
            ForEach(Array(outcomes.enumerated()), id: \.offset) { index, outcome in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(index + 1). \(title(outcome.step))").font(.headline)
                        Spacer()
                        badge(outcome)
                    }
                    Text(outcome.step.note).font(.subheadline).foregroundStyle(.secondary)
                    Text(detail(outcome)).font(.footnote)
                    DebtBar(debt: outcome.paymentsDebtAfter, budget: SampleScenario.paymentsBudget)
                }
                .padding(.vertical, 4)
                .id(index)
            }
        }
        .listStyle(.plain)
    }

    func title(_ step: SampleScenario.Step) -> String {
        switch step {
        case .change(let change, _): return change.id
        case .explainBack: return "Explain-back"
        }
    }

    @ViewBuilder func badge(_ outcome: SampleScenario.Outcome) -> some View {
        let (label, color): (String, Color) = {
            if let verdict = outcome.verdict { return verdict.isAccepted ? ("Accepted", .green) : ("Blocked", .red) }
            return outcome.error == nil ? ("Cleared", .blue) : ("Rejected", .red)
        }()
        Text(label)
            .font(.caption.bold())
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    func detail(_ outcome: SampleScenario.Outcome) -> String {
        if let cleared = outcome.cleared { return "Cleared \(cleared) lines of Payments debt." }
        if let error = outcome.error { return "Explain-back rejected: \(error)" }
        switch outcome.verdict {
        case .accepted(let added)?:
            if added.isEmpty { return "No metered lines." }
            return added.sorted { $0.key < $1.key }.map { "+\($0.value) lines of \($0.key) debt" }.joined(separator: ", ")
        case .blocked(let reasons)?:
            return reasons.map(Self.describe).joined(separator: "\n")
        case nil:
            return ""
        }
    }

    static func describe(_ reason: BlockReason) -> String {
        switch reason {
        case .emptyChange: return "The change touches no files."
        case .blankID: return "The change has no ID."
        case .blankIdentity: return "The author or driver is blank."
        case .invalidPath(let path): return "Invalid path: \(path)"
        case .invalidLineCount(let path, let lines): return "Invalid line count \(lines) for \(path)"
        case .missingRecord(let module): return "\(module) needs a decision record."
        case .incompleteRecord(let module, let problems): return "\(module) record is incomplete (\(problems.count) problems)."
        case .explainBackRequired(let module, let debt, let incoming, let budget):
            return "\(module): \(debt) + \(incoming) lines would pass the \(budget)-line budget. Explain-back first."
        case .changeLargerThanBudget(let module, let incoming, let budget):
            return "\(module): \(incoming) lines is over the \(budget)-line budget on its own. Split it."
        }
    }
}

struct DebtBar: View {
    let debt: Int
    let budget: Int

    var body: some View {
        let fraction = budget > 0 ? min(Double(debt) / Double(budget), 1) : 0
        HStack(spacing: 8) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule().fill(fraction > 0.8 ? Color.orange : Color.accentColor)
                        .frame(width: proxy.size.width * fraction)
                }
            }
            .frame(height: 6)
            Text("Payments \(debt)/\(budget)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Payments debt \(debt) of \(budget) lines")
    }
}

struct ModulesView: View {
    let ledger: ComprehensionLedger

    var body: some View {
        List {
            Section {
                ForEach(ledger.rules, id: \.name) { rule in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(rule.name).font(.headline)
                            Spacer()
                            Text(tierName(rule.tier)).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(rule.pathPrefix + "/").font(.caption.monospaced()).foregroundStyle(.secondary)
                        if case .mustStayExplainable(let budget) = rule.tier {
                            DebtBar(debt: ledger.debt(for: rule.name), budget: budget)
                            let names = ledger.explainers[rule.name, default: []].sorted()
                            Text(names.isEmpty ? "No explain-back yet" : "Explained back by: \(names.joined(separator: ", "))")
                                .font(.footnote)
                        } else {
                            Text(rule.tier == .open ? "No requirements." : "Agent changes need a decision record.")
                                .font(.footnote)
                        }
                    }
                    .padding(.vertical, 4)
                }
            } footer: {
                Text("Debt counts agent-written lines since the last explain-back. Human changes add none. Accepted \(acceptedCount) of \(changeCount) changes this week.")
            }
        }
    }

    var changeCount: Int {
        ledger.history.filter { if case .explainedBack = $0 { return false }; return true }.count
    }
    var acceptedCount: Int {
        ledger.history.filter { if case .accepted = $0 { return true }; return false }.count
    }

    func tierName(_ tier: ExplainTier) -> String {
        switch tier {
        case .open: return "Open"
        case .recordRequired: return "Record required"
        case .mustStayExplainable(let budget): return "Must stay explainable · \(budget)"
        }
    }
}
