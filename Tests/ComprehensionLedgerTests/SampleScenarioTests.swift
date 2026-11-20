import XCTest
@testable import ComprehensionLedger

/// Pins every outcome of the scripted week that the demo app shows and the
/// article walks through.
final class SampleScenarioTests: XCTestCase {
    func testEveryStepOfTheScriptedWeek() throws {
        let (ledger, outcomes) = try SampleScenario.play()
        XCTAssertEqual(outcomes.count, 7)
        guard outcomes.count == 7 else { return }

        XCTAssertEqual(outcomes[0].verdict, .accepted(debtAdded: ["Payments": 180]))
        XCTAssertEqual(outcomes[0].paymentsDebtAfter, 180)

        XCTAssertEqual(outcomes[1].verdict, .blocked([.missingRecord(module: "Onboarding")]))
        XCTAssertEqual(outcomes[1].paymentsDebtAfter, 180)

        XCTAssertEqual(outcomes[2].verdict, .accepted(debtAdded: ["Payments": 150]))
        XCTAssertEqual(outcomes[2].paymentsDebtAfter, 330)

        XCTAssertEqual(outcomes[3].verdict,
                       .blocked([.explainBackRequired(module: "Payments", debt: 330, incoming: 120, budget: 400)]))
        XCTAssertEqual(outcomes[3].paymentsDebtAfter, 330)

        XCTAssertNil(outcomes[4].verdict)
        XCTAssertNil(outcomes[4].error)
        XCTAssertEqual(outcomes[4].cleared, 330)
        XCTAssertEqual(outcomes[4].paymentsDebtAfter, 0)

        XCTAssertEqual(outcomes[5].verdict, .accepted(debtAdded: ["Payments": 120]))
        XCTAssertEqual(outcomes[5].paymentsDebtAfter, 120)

        XCTAssertEqual(outcomes[6].verdict, .blocked([.missingRecord(module: "Payments")]))
        XCTAssertEqual(outcomes[6].paymentsDebtAfter, 120)

        XCTAssertEqual(ledger.debt(for: "Payments"), 120)
        XCTAssertEqual(ledger.explainers["Payments"], ["Asha"])
        XCTAssertEqual(ledger.history.count, 7)
        guard ledger.history.count == 7 else { return }
        XCTAssertEqual(ledger.history[0], .accepted(changeID: "PR-101", debtAdded: ["Payments": 180]))
        XCTAssertEqual(ledger.history[1], .blocked(changeID: "PR-102", reasons: [.missingRecord(module: "Onboarding")]))
        XCTAssertEqual(ledger.history[2], .accepted(changeID: "PR-103", debtAdded: ["Payments": 150]))
        if case .explainedBack(let module, let explainer, let witness, _, let cleared) = ledger.history[4] {
            XCTAssertEqual([module, explainer, witness], ["Payments", "Asha", "Ben"])
            XCTAssertEqual(cleared, 330)
        } else {
            XCTFail("step 5 should be an explain-back")
        }
        XCTAssertEqual(ledger.history[5], .accepted(changeID: "PR-104", debtAdded: ["Payments": 120]))
        XCTAssertEqual(SampleScenario.paymentsBudget, 400)
    }

    func testScenarioCountsMatchTheArticle() throws {
        let (_, outcomes) = try SampleScenario.play()
        let changes = outcomes.compactMap(\.verdict)
        XCTAssertEqual(changes.count, 6)
        XCTAssertEqual(changes.filter(\.isAccepted).count, 3)
        XCTAssertEqual(changes.filter { !$0.isAccepted }.count, 3)
    }
}
