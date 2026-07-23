import XCTest
@testable import GameKitCore
import CoreModels

final class CalculatorTests: XCTestCase {
    func testPlacementBudgetFor5kRoute() {
        XCTAssertEqual(PlacementBudget.slots(forDistanceM: 5_000), 20)
        XCTAssertEqual(PlacementBudget.points(forDistanceM: 5_000), 50)
    }

    func testShortRouteCannotAffordEpic() {
        let budget = PlacementBudget.points(forDistanceM: 1_000)   // 10 points
        XCTAssertLessThan(budget, PlacementBudget.cost(of: .epic)!)
        XCTAssertEqual(budget, PlacementBudget.cost(of: .rare))    // exactly one Rare
    }

    func testLegendaryIsNotCreatorPlaceable() {
        XCTAssertNil(PlacementBudget.cost(of: .legendary))
    }

    func testStreakMultiplierCurve() {
        XCTAssertEqual(StreakRules.multiplier(streakDays: 0), 1.0)
        XCTAssertEqual(StreakRules.multiplier(streakDays: 6), 1.0)
        XCTAssertEqual(StreakRules.multiplier(streakDays: 7), 1.1, accuracy: 0.0001)
        XCTAssertEqual(StreakRules.multiplier(streakDays: 35), 1.5)
        XCTAssertEqual(StreakRules.multiplier(streakDays: 700), 1.5)   // capped
    }

    func testXPBaseValues() {
        XCTAssertEqual(XPRules.base(for: .common), 10)
        XCTAssertEqual(XPRules.base(for: .legendary), 500)
        XCTAssertEqual(XPRules.xpToAdvance(from: 3), 300)
    }
}
