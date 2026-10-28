import CoreML
import Darwin
@testable import ForewarnKit
import Foundation
import Testing

/// Pure-Swift parts of the port run everywhere. The end-to-end checks need the converted model and the vectors
/// from `cd tools/convert && uv run production.py model && uv run production.py vectors` (weights are not
/// committed); without them they are skipped.
struct TimestralEngineTests {
    static let out = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appending(path: "../../../tools/convert/out").standardizedFileURL
    static let model = out.appending(path: "Timestral-5M-core-32768-fp32.mlpackage")
    static let vectors = out.appending(path: "Timestral-5M-e2e.json")
    static let haveModel = FileManager.default.fileExists(atPath: model.path)
        && FileManager.default.fileExists(atPath: vectors.path)

    @Test func leftPadKeepsTheMostRecentStepsAndMarksPaddingAndNaNMissing() {
        let row = Timestral.leftPad([1, .nan, 3], to: 5)
        #expect(row.values == [0, 0, 1, 0, 3])
        #expect(row.observed == [false, false, true, false, true])
        #expect(Timestral.leftPad([1, 2, 3, 4], to: 2).values == [3, 4])
    }

    @Test func patchLocScaleIsTheCausalMeanAndStdOfObservedValues() {
        // Patch 0: 1…32 observed. Patch 1: missing except one 100, which joins the running statistics.
        var observed = Array(repeating: true, count: 32) + Array(repeating: false, count: 32)
        observed[63] = true
        let values = (1 ... 32).map(Float.init) + Array(repeating: 0, count: 31) + [100]
        let (loc, scale) = Timestral.patchLocScale(Timestral.Row(values: values, observed: observed))
        let first = (1 ... 32).map(Double.init), all = first + [100]
        #expect(abs(Double(loc[0]) - 16.5) < 1e-5)
        #expect(abs(Double(scale[0]) - std(first)) < 1e-5)
        #expect(abs(Double(loc[1]) - all.reduce(0, +) / 33) < 1e-5)
        #expect(abs(Double(scale[1]) - std(all)) < 1e-4)
    }

    @Test func coreInputsMaskLeadingPaddingAndAnchorPositionsAtTheFirstObservedPatch() throws {
        // Three context patches, the first all missing; two horizon patches.
        let observed = Array(repeating: false, count: 32) + Array(repeating: true, count: 64)
        let row = Timestral.Row(values: observed.map { $0 ? 50 : 0 }, observed: observed)
        let frame = Timestral.patchLocScale(row)
        let features = try Timestral.features([row, row], frames: [frame, frame], patches: 2)
        let n = 5
        let time = try #require(features["time_mask"]?.shapedArrayValue(of: Float.self))
        #expect(time.shape == [2, 1, n, n])
        let mask = Array(time.scalars.prefix(n * n))
        let expected: [Float] = [
            1, 0, 0, 0, 0, // padding patch reads only itself
            0, 1, 0, 0, 0, // causal over valid keys
            0, 1, 1, 0, 0,
            0, 1, 1, 1, 0, // decoder: whole valid context, causal decoder chain
            0, 1, 1, 1, 1,
        ]
        #expect(mask == expected)
        let positions = try #require(features["positions"]?.shapedArrayValue(of: Int32.self))
        #expect(positions.scalars == [-1, 0, 1, 2, 3, -1, 0, 1, 2, 3])
        let variate = try #require(features["variate_mask"]?.shapedArrayValue(of: Float.self))
        #expect(variate.shape == [n, 1, 2, 2])
        #expect(variate.scalars.prefix(4) == [1, 0, 0, 1])
        let scaled = try #require(features["scaled"]?.shapedArrayValue(of: Float.self))
        #expect(scaled.scalars.prefix(32).allSatisfy { $0 == 0 })
    }

    @Test func refineKeepsTheFirstHorizonPatchAndMovesLaterOnes() {
        let row = Timestral.Row(values: Array(repeating: 50, count: 64), observed: Array(repeating: true, count: 64))
        // A falling median: later patches move to a frame that follows it.
        var q = (0 ..< 64).flatMap { step in (0 ..< 21).map { Float(40 - step) + Float($0 - 10) * 0.1 } }
        let original = q
        Timestral.refine(&q, row: row, loc: 50, scale: 1, patches: 2)
        #expect(zip(q.prefix(32 * 21), original).allSatisfy { abs($0 - $1) < 1e-4 })
        #expect(q.suffix(32 * 21) != original.suffix(32 * 21))
        var single = original
        Timestral.refine(&single, row: row, loc: 50, scale: 1, patches: 1)
        #expect(single == original)
    }

    @Test func clampNonfiniteMapsInfinitiesToTheNearestFiniteQuantile() {
        var q: [Float] = [-.infinity] + (1 ... 19).map(Float.init) + [.infinity]
        q += Array(repeating: .infinity, count: 21)
        Timestral.clampNonfinite(&q)
        #expect(q[0] == 1 && q[20] == 19)
        #expect(q[21...].allSatisfy { $0 == 0 })
    }

    @Test func clampsymAveragesTheReflectedMirrorAndClipsNonNegativeSeries() {
        let q = (0 ..< 21).map { Float($0) - 2 } // one step
        let mirrored = q.reversed().map { -$0 + 2 } // the mirror forecast of the same series, offset by 2
        let clipped = Timestral.clampsym(q, mirrored, target: [1, .nan, 3])
        #expect(clipped.map(\.[0]) == (0 ..< 21).map { max(0, Double($0) - 3) })
        let signed = Timestral.clampsym(q, mirrored, target: [-1, 3])
        #expect(signed.map(\.[0]) == (0 ..< 21).map { Double($0) - 3 })
    }

    @Test func missingModelThrowsSoTheCallerCanFallBack() async {
        let engine = TimestralEngine(modelURL: URL(fileURLWithPath: "/nonexistent/Timestral.mlpackage"))
        await #expect(throws: (any Error).self) {
            _ = try await engine.forecast(ForecastRequest(target: [50, 49, 48], horizon: 144))
        }
        await #expect(throws: TimestralEngine.Failure.noObservations) {
            _ = try await engine.forecast(ForecastRequest(target: [.nan], horizon: 144))
        }
    }

    /// Within 1e-3 percentage points of the reference on every quantile.
    @Test(.enabled(if: haveModel, "needs tools/convert/out from production.py model and vectors"))
    func matchesTheReferenceForecasterEndToEnd() async throws {
        let engine = TimestralEngine(modelURL: Self.model)
        for testCase in try Self.cases() {
            let forecast = try await engine.forecast(ForecastRequest(
                target: testCase.series,
                horizon: testCase.horizon
            ))
            #expect(forecast.horizon == testCase.horizon)
            let diff = zip(forecast.values.joined(), testCase.expected.joined()).map { abs($0 - $1) }.max() ?? .nan
            print("TimestralEngine parity \(testCase.name): max abs \(diff)")
            #expect(diff <= 1e-3, "\(testCase.name)")
        }
    }

    /// Load and run cost of the whole engine. Prints; asserts nothing about speed.
    @Test(.enabled(if: haveModel, "needs tools/convert/out from production.py model and vectors"))
    func measureLoadAndRunCost() async throws {
        let request = try ForecastRequest(target: #require(Self.cases().first).series, horizon: 144)
        let compiled = try await MLModel.compileModel(at: Self.model)
        defer { try? FileManager.default.removeItem(at: compiled) }
        for (label, url) in [("mlpackage, compile + load + run", Self.model), ("mlmodelc, load + run", compiled)] {
            let (ms, mJ) = try await cost { _ = try await TimestralEngine(modelURL: url).forecast(request) }
            print("TimestralEngine first forecast, \(label): \(ms) ms, \(mJ) mJ")
        }
        let engine = TimestralEngine(modelURL: compiled)
        _ = try await engine.forecast(request)
        var runs: [(Double, Double)] = []
        for _ in 0 ..< 10 {
            try await runs.append(cost { _ = try await engine.forecast(request) })
        }
        let ms = runs.map(\.0).sorted()[5], mJ = runs.map(\.1).sorted()[5]
        print("TimestralEngine resident forecast, median of 10: \(ms) ms, \(mJ) mJ")
    }

    struct Case: Decodable {
        let name: String
        let horizon: Int
        let target: [Double?]
        let expected: [[Double]]

        var series: [Double] { target.map { $0 ?? .nan } }
    }

    static func cases() throws -> [Case] {
        try JSONDecoder().decode([Case].self, from: Data(contentsOf: vectors))
    }
}

private func std(_ xs: [Double]) -> Double {
    let mean = xs.reduce(0, +) / Double(xs.count)
    return (xs.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(xs.count - 1)).squareRoot()
}

/// Wall time (ms) and this process's energy (mJ, `rusage_info_v6.ri_energy_nj`) of one call.
private func cost(_ body: () async throws -> Void) async rethrows -> (Double, Double) {
    let start = ContinuousClock.now, energy = energyNJ()
    try await body()
    return ((ContinuousClock.now - start) / .milliseconds(1), Double(energyNJ() - energy) / 1e6)
}

private func energyNJ() -> UInt64 {
    var info = rusage_info_v6()
    let rc = withUnsafeMutablePointer(to: &info) { ptr in
        ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V6, $0) }
    }
    return rc == 0 ? info.ri_energy_nj : 0
}
