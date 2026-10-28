@testable import ForewarnKit
import Testing

struct QuantileForecastTests {
    @Test func levelsAreTwentyOneAscendingFromP1ToP99() {
        let levels = QuantileForecast.levels
        #expect(levels.count == 21)
        #expect(levels.first == 0.01)
        #expect(levels.last == 0.99)
        #expect(levels == levels.sorted())
    }

    @Test func medianAndQuantileLookupReturnMatchingRows() {
        // Row i holds the value i at every step, so a row's content identifies its level.
        let forecast = QuantileForecast(values: (0 ..< 21).map { Array(repeating: Double($0), count: 3) })
        #expect(forecast.horizon == 3)
        #expect(forecast.median == [10, 10, 10])
        #expect(forecast.quantile(0.5) == forecast.median)
        #expect(forecast.quantile(0.1) == [2, 2, 2])
        #expect(forecast.quantile(0.99) == [20, 20, 20])
        #expect(forecast.quantile(0.42) == nil)
    }
}
