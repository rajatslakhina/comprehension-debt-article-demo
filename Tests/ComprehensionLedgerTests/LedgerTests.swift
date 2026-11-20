import XCTest
@testable import ComprehensionLedger

final class LedgerTests: XCTestCase {
    let agent = Author.agent(name: "Claude Code", drivenBy: "Asha")
    let fullRecord = DecisionRecord(
        problem: "p", chosen: "c",
        rejected: [RejectedAlternative(option: "o", reason: "r")],
        invariants: ["i"]
    )

    func makeLedger(budget: Int = 100) throws -> ComprehensionLedger {
        try ComprehensionLedger(rules: [
            ModuleRule(name: "Payments", pathPrefix: "Sources/Payments", tier: .mustStayExplainable(debtBudget: budget)),
            ModuleRule(name: "Onboarding", pathPrefix: "Sources/Onboarding", tier: .recordRequired),
            ModuleRule(name: "Settings", pathPrefix: "Sources/Settings", tier: .open),
        ])
    }

    func agentChange(_ id: String, _ path: String, _ lines: Int, record: DecisionRecord? = nil) -> Change {
        Change(id: id, author: agent, files: [FileDiff(path: path, linesChanged: lines)], record: record)
    }

    // MARK: - Debt and budget

    func testDebtAtExactlyTheBudgetIsAcceptedAndOneMoreLineIsBlocked() throws {
        var ledger = try makeLedger(budget: 100)
        XCTAssertEqual(ledger.submit(agentChange("a", "Sources/Payments/A.swift", 60, record: fullRecord)),
                       .accepted(debtAdded: ["Payments": 60]))
        XCTAssertEqual(ledger.submit(agentChange("b", "Sources/Payments/B.swift", 40, record: fullRecord)),
                       .accepted(debtAdded: ["Payments": 40]))
        XCTAssertEqual(ledger.debt(for: "Payments"), 100)
        XCTAssertEqual(ledger.submit(agentChange("c", "Sources/Payments/C.swift", 1, record: fullRecord)),
                       .blocked([.explainBackRequired(module: "Payments", debt: 100, incoming: 1, budget: 100)]))
        XCTAssertEqual(ledger.debt(for: "Payments"), 100)
    }

    func testBlockedChangeLeavesDebtUntouchedAndIsLogged() throws {
        var ledger = try makeLedger()
        _ = ledger.submit(agentChange("a", "Sources/Payments/A.swift", 30))
        XCTAssertEqual(ledger.debt(for: "Payments"), 0)
        XCTAssertEqual(ledger.history, [.blocked(changeID: "a", reasons: [.missingRecord(module: "Payments")])])
    }

    func testChangeLargerThanBudgetCannotBeUnblockedByExplainBack() throws {
        var ledger = try makeLedger(budget: 100)
        XCTAssertEqual(ledger.submit(agentChange("big", "Sources/Payments/A.swift", 101, record: fullRecord)),
                       .blocked([.changeLargerThanBudget(module: "Payments", incoming: 101, budget: 100)]))
        try ledger.recordExplainBack(ExplainBack(module: "Payments", explainer: "Asha", witness: "Ben", summary: "s"))
        XCTAssertEqual(ledger.submit(agentChange("big", "Sources/Payments/A.swift", 101, record: fullRecord)),
                       .blocked([.changeLargerThanBudget(module: "Payments", incoming: 101, budget: 100)]))
    }

    func testASingleChangeExactlyAtTheBudgetIsAccepted() throws {
        var ledger = try makeLedger(budget: 100)
        XCTAssertEqual(ledger.submit(agentChange("full", "Sources/Payments/A.swift", 100, record: fullRecord)),
                       .accepted(debtAdded: ["Payments": 100]))
    }

    func testOverflowingLineCountsBlockInsteadOfCrashing() throws {
        let ledger = try makeLedger(budget: 100)
        let change = Change(id: "huge", author: agent, files: [
            FileDiff(path: "Sources/Payments/A.swift", linesChanged: Int.max),
            FileDiff(path: "Sources/Payments/B.swift", linesChanged: Int.max),
        ], record: fullRecord)
        XCTAssertEqual(ledger.evaluate(change), .blocked([.lineCountOverflow(module: "Payments")]))
        let maxBudget = try ComprehensionLedger(rules: [
            ModuleRule(name: "P", pathPrefix: "P", tier: .mustStayExplainable(debtBudget: Int.max)),
        ])
        XCTAssertTrue(maxBudget.evaluate(agentChange("m", "P/A.swift", Int.max, record: fullRecord)).isAccepted)
    }

    func testAnAcceptedChangeCannotBeCountedTwice() throws {
        var ledger = try makeLedger()
        let change = agentChange("PR-1", "Sources/Payments/A.swift", 30, record: fullRecord)
        XCTAssertTrue(ledger.submit(change).isAccepted)
        XCTAssertEqual(ledger.submit(change), .blocked([.duplicateChange(id: "PR-1")]))
        XCTAssertEqual(ledger.debt(for: "Payments"), 30)
    }

    func testLinesAcrossFilesInOneModuleAreSummed() throws {
        var ledger = try makeLedger(budget: 100)
        let change = Change(id: "x", author: agent, files: [
            FileDiff(path: "Sources/Payments/A.swift", linesChanged: 30),
            FileDiff(path: "Sources/Payments/Sub/B.swift", linesChanged: 25),
        ], record: fullRecord)
        XCTAssertEqual(ledger.submit(change), .accepted(debtAdded: ["Payments": 55]))
        XCTAssertEqual(ledger.debt(for: "Payments"), 55)
    }

    func testOneBlockingModuleBlocksTheWholeChangeAtomically() throws {
        var ledger = try ComprehensionLedger(rules: [
            ModuleRule(name: "Payments", pathPrefix: "Sources/Payments", tier: .mustStayExplainable(debtBudget: 100)),
            ModuleRule(name: "Auth", pathPrefix: "Sources/Auth", tier: .mustStayExplainable(debtBudget: 100)),
        ])
        _ = ledger.submit(agentChange("seed", "Sources/Payments/A.swift", 95, record: fullRecord))
        let change = Change(id: "mixed", author: agent, files: [
            FileDiff(path: "Sources/Auth/Login.swift", linesChanged: 20),
            FileDiff(path: "Sources/Payments/B.swift", linesChanged: 10),
        ], record: fullRecord)
        XCTAssertEqual(ledger.submit(change),
                       .blocked([.explainBackRequired(module: "Payments", debt: 95, incoming: 10, budget: 100)]))
        XCTAssertEqual(ledger.debt(for: "Auth"), 0)
        XCTAssertEqual(ledger.debt(for: "Payments"), 95)
    }

    // MARK: - Who pays

    func testHumanChangesNeedNoRecordAndNeitherAddNorClearDebt() throws {
        var ledger = try makeLedger()
        _ = ledger.submit(agentChange("a", "Sources/Payments/A.swift", 50, record: fullRecord))
        let human = Change(id: "h", author: .human("Ben"),
                           files: [FileDiff(path: "Sources/Payments/A.swift", linesChanged: 200)])
        XCTAssertEqual(ledger.submit(human), .accepted(debtAdded: [:]))
        XCTAssertEqual(ledger.debt(for: "Payments"), 50)
    }

    func testHumanChangesStillGetPathAndDuplicateChecks() throws {
        var ledger = try makeLedger()
        XCTAssertEqual(ledger.submit(Change(id: "h2", author: .human("Ben"),
                                            files: [FileDiff(path: "../x.swift", linesChanged: 1)])),
                       .blocked([.invalidPath("../x.swift")]))
        let human = Change(id: "h", author: .human("Ben"),
                           files: [FileDiff(path: "Sources/Payments/A.swift", linesChanged: 5)])
        XCTAssertTrue(ledger.submit(human).isAccepted)
        XCTAssertEqual(ledger.submit(human), .blocked([.duplicateChange(id: "h")]))
    }

    func testOpenModuleAcceptsAgentChangesWithoutRecord() throws {
        var ledger = try makeLedger()
        XCTAssertEqual(ledger.submit(agentChange("s", "Sources/Settings/Theme.swift", 500)), .accepted(debtAdded: [:]))
        XCTAssertEqual(ledger.submit(agentChange("u", "README.md", 10)), .accepted(debtAdded: [:]))
    }

    // MARK: - Decision records

    func testRecordRequiredNeedsARejectedAlternativeButNoInvariant() throws {
        let ledger = try makeLedger()
        let noInvariant = DecisionRecord(problem: "p", chosen: "c",
                                         rejected: [RejectedAlternative(option: "o", reason: "r")], invariants: [])
        XCTAssertTrue(ledger.evaluate(agentChange("a", "Sources/Onboarding/A.swift", 5, record: noInvariant)).isAccepted)
        let noAlternative = DecisionRecord(problem: "p", chosen: "c", rejected: [], invariants: ["i"])
        XCTAssertEqual(ledger.evaluate(agentChange("b", "Sources/Onboarding/A.swift", 5, record: noAlternative)),
                       .blocked([.incompleteRecord(module: "Onboarding", problems: [.noRejectedAlternative])]))
    }

    func testBlankFieldsInARecordAreReportedPrecisely() throws {
        let ledger = try makeLedger()
        let record = DecisionRecord(problem: "  ", chosen: "",
                                    rejected: [RejectedAlternative(option: "Keep Double", reason: " "),
                                               RejectedAlternative(option: " ", reason: "ignored")],
                                    invariants: ["   "])
        XCTAssertEqual(ledger.evaluate(agentChange("a", "Sources/Payments/A.swift", 5, record: record)),
                       .blocked([.incompleteRecord(module: "Payments", problems: [
                           .blankProblem, .blankChoice,
                           .rejectedAlternativeWithoutReason(option: "Keep Double"), .noInvariant,
                       ])]))
    }

    // MARK: - Paths

    func testPrefixMatchesOnDirectoryBoundaryOnly() throws {
        let ledger = try makeLedger()
        XCTAssertEqual(ledger.rule(for: "Sources/Payments/A.swift")?.name, "Payments")
        XCTAssertNil(ledger.rule(for: "Sources/PaymentsUI/A.swift"))
        XCTAssertNil(ledger.rule(for: "Sources/Payments"))
    }

    func testMatchingIgnoresCaseLikeTheDefaultMacFileSystem() throws {
        let ledger = try makeLedger()
        XCTAssertEqual(ledger.rule(for: "sources/payments/Refund.swift")?.name, "Payments")
        XCTAssertEqual(ledger.evaluate(agentChange("c", "SOURCES/Payments/Refund.swift", 5)),
                       .blocked([.missingRecord(module: "Payments")]))
    }

    func testDotDotIsResolvedSoItCannotDodgeAMeteredModule() throws {
        let ledger = try makeLedger()
        XCTAssertEqual(ledger.rule(for: "Sources/Settings/../Payments/A.swift")?.name, "Payments")
        XCTAssertEqual(ledger.rule(for: "./Sources//Payments/./A.swift")?.name, "Payments")
        XCTAssertEqual(ledger.evaluate(agentChange("x", "Sources/Settings/../Payments/A.swift", 5)),
                       .blocked([.missingRecord(module: "Payments")]))
    }

    func testPathsThatEscapeTheRootOrAreAbsoluteAreBlocked() throws {
        let ledger = try makeLedger()
        for bad in ["../Payments/A.swift", "/Sources/Payments/A.swift", "Sources\\Payments\\A.swift", "  ", "./."] {
            XCTAssertEqual(ledger.evaluate(agentChange("x", bad, 5)), .blocked([.invalidPath(bad)]), bad)
        }
    }

    func testMostSpecificPrefixWins() throws {
        let ledger = try ComprehensionLedger(rules: [
            ModuleRule(name: "Core", pathPrefix: "Sources", tier: .open),
            ModuleRule(name: "Payments", pathPrefix: "Sources/Payments/", tier: .recordRequired),
        ])
        XCTAssertEqual(ledger.rule(for: "Sources/Payments/A.swift")?.name, "Payments")
        XCTAssertEqual(ledger.rule(for: "Sources/Other/A.swift")?.name, "Core")
        let reversed = try ComprehensionLedger(rules: [
            ModuleRule(name: "Payments", pathPrefix: "Sources/Payments/", tier: .recordRequired),
            ModuleRule(name: "Core", pathPrefix: "Sources", tier: .open),
        ])
        XCTAssertEqual(reversed.rule(for: "Sources/Payments/A.swift")?.name, "Payments")
        XCTAssertEqual(reversed.rule(for: "Sources/Other/A.swift")?.name, "Core")
    }

    // MARK: - Malformed changes

    func testMalformedChangesAreBlocked() throws {
        let ledger = try makeLedger()
        XCTAssertEqual(ledger.evaluate(Change(id: "e", author: agent, files: [])), .blocked([.emptyChange]))
        XCTAssertEqual(ledger.evaluate(Change(id: " ", author: .human("Ben"),
                                              files: [FileDiff(path: "README.md", linesChanged: 1)])),
                       .blocked([.blankID]))
        XCTAssertEqual(ledger.evaluate(Change(id: "n", author: .agent(name: "Claude Code", drivenBy: " "),
                                              files: [FileDiff(path: "README.md", linesChanged: 1)])),
                       .blocked([.blankIdentity]))
        XCTAssertEqual(ledger.evaluate(agentChange("neg", "Sources/Payments/A.swift", -5, record: fullRecord)),
                       .blocked([.invalidLineCount(path: "Sources/Payments/A.swift", lines: -5)]))
    }

    // MARK: - Explain-back

    func testExplainBackClearsDebtAndRecordsTheExplainer() throws {
        var ledger = try makeLedger()
        _ = ledger.submit(agentChange("a", "Sources/Payments/A.swift", 70, record: fullRecord))
        let cleared = try ledger.recordExplainBack(
            ExplainBack(module: "payments", explainer: " Asha ", witness: "Ben", summary: "why"))
        XCTAssertEqual(cleared, 70)
        XCTAssertEqual(ledger.debt(for: "Payments"), 0)
        XCTAssertEqual(ledger.explainers["Payments"], ["Asha"])
        XCTAssertEqual(ledger.history.last, .explainedBack(module: "Payments", explainer: "Asha", witness: "Ben",
                                                           summary: "why", cleared: 70))
    }

    func testExplainBackClearsOnlyItsModule() throws {
        var ledger = try ComprehensionLedger(rules: [
            ModuleRule(name: "Payments", pathPrefix: "Sources/Payments", tier: .mustStayExplainable(debtBudget: 100)),
            ModuleRule(name: "Auth", pathPrefix: "Sources/Auth", tier: .mustStayExplainable(debtBudget: 100)),
        ])
        _ = ledger.submit(agentChange("p", "Sources/Payments/A.swift", 40, record: fullRecord))
        _ = ledger.submit(agentChange("a", "Sources/Auth/B.swift", 25, record: fullRecord))
        XCTAssertEqual(try ledger.recordExplainBack(
            ExplainBack(module: "Payments", explainer: "Asha", witness: "Ben", summary: "s")), 40)
        XCTAssertEqual(ledger.debt(for: "Payments"), 0)
        XCTAssertEqual(ledger.debt(for: "Auth"), 25)
    }

    func testExplainBackRejectsSelfWitnessBlankFieldsAndUnmeteredModules() throws {
        var ledger = try makeLedger()
        XCTAssertThrowsError(try ledger.recordExplainBack(
            ExplainBack(module: "Payments", explainer: "Asha", witness: " asha", summary: "s"))) {
            XCTAssertEqual($0 as? LedgerError, .witnessIsExplainer)
        }
        for (explainer, witness, summary) in [("Asha", "Ben", " "), (" ", "Ben", "s"), ("Asha", "", "s")] {
            XCTAssertThrowsError(try ledger.recordExplainBack(
                ExplainBack(module: "Payments", explainer: explainer, witness: witness, summary: summary))) {
                XCTAssertEqual($0 as? LedgerError, .blankExplainBackField)
            }
        }
        XCTAssertThrowsError(try ledger.recordExplainBack(
            ExplainBack(module: "Onboarding", explainer: "Asha", witness: "Ben", summary: "s"))) {
            XCTAssertEqual($0 as? LedgerError, .moduleNotMetered("Onboarding"))
        }
        XCTAssertThrowsError(try ledger.recordExplainBack(
            ExplainBack(module: "Billing", explainer: "Asha", witness: "Ben", summary: "s"))) {
            XCTAssertEqual($0 as? LedgerError, .unknownModule("Billing"))
        }
        XCTAssertEqual(ledger.history.count, 6)
        XCTAssertEqual(ledger.history.first, .explainBackRejected(module: "Payments", error: .witnessIsExplainer))
        XCTAssertTrue(ledger.explainers.isEmpty)
    }

    func testTheAgentCannotBeTheExplainerOrTheWitness() throws {
        var ledger = try makeLedger()
        _ = ledger.submit(agentChange("a", "Sources/Payments/A.swift", 40, record: fullRecord))
        XCTAssertThrowsError(try ledger.recordExplainBack(
            ExplainBack(module: "Payments", explainer: "Asha", witness: "claude code", summary: "s"))) {
            XCTAssertEqual($0 as? LedgerError, .agentAsParticipant("claude code"))
        }
        XCTAssertThrowsError(try ledger.recordExplainBack(
            ExplainBack(module: "Payments", explainer: "Claude Code", witness: "Ben", summary: "s"))) {
            XCTAssertEqual($0 as? LedgerError, .agentAsParticipant("Claude Code"))
        }
        XCTAssertEqual(ledger.debt(for: "Payments"), 40)
    }

    func testAnAgentWhoseOnlyChangeWasBlockedStillCannotWitness() throws {
        var ledger = try makeLedger()
        let blocked = ledger.submit(agentChange("a", "Sources/Payments/A.swift", 10))
        XCTAssertFalse(blocked.isAccepted)
        XCTAssertThrowsError(try ledger.recordExplainBack(
            ExplainBack(module: "Payments", explainer: "Asha", witness: "Claude Code", summary: "s"))) {
            XCTAssertEqual($0 as? LedgerError, .agentAsParticipant("Claude Code"))
        }
    }

    // MARK: - Rules

    func testInvalidRulesThrow() {
        func expect(_ rules: [ModuleRule], _ error: LedgerError) {
            XCTAssertThrowsError(try ComprehensionLedger(rules: rules)) { XCTAssertEqual($0 as? LedgerError, error) }
        }
        expect([], .noRules)
        expect([ModuleRule(name: " ", pathPrefix: "A", tier: .open)], .blankModuleName)
        expect([ModuleRule(name: "A", pathPrefix: "A", tier: .open),
                ModuleRule(name: "A", pathPrefix: "B", tier: .open)], .duplicateModuleName("A"))
        expect([ModuleRule(name: "Pay", pathPrefix: "A", tier: .open),
                ModuleRule(name: "pay", pathPrefix: "B", tier: .open)], .duplicateModuleName("pay"))
        expect([ModuleRule(name: "A", pathPrefix: "../A", tier: .open)], .invalidPrefix("../A"))
        expect([ModuleRule(name: "A", pathPrefix: "Src/A", tier: .open),
                ModuleRule(name: "B", pathPrefix: "./Src/A/", tier: .open)], .duplicatePrefix("Src/A"))
        expect([ModuleRule(name: "A", pathPrefix: "Src/A", tier: .open),
                ModuleRule(name: "B", pathPrefix: "src/a", tier: .open)], .duplicatePrefix("src/a"))
        expect([ModuleRule(name: "A", pathPrefix: "A", tier: .mustStayExplainable(debtBudget: 0))],
               .nonPositiveBudget(module: "A"))
    }
}
