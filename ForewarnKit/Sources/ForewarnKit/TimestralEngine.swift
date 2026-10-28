import CoreML
import Foundation

/// Timestral through Core ML: `TimestralForecaster.forecast(context, horizon)` of the
/// reference package (mistralai/timestral@a534bdb), univariate path, with clampsym on.
///
/// Only the neural core (patch embedding, transformer, quantile head) runs in Core ML, fp32 on CPU+GPU.
/// Scaling, masks, positions, denormalization, the refine frame, the block loop, symmetric averaging and
/// clipping are ported below. The model loads on first use and stays resident until `unload()`.
/// Covariates in the request are ignored: the production model is the univariate core.
public actor TimestralEngine: ForecastEngine {
    public enum Failure: Error, Equatable {
        case badModel(String)
        case noObservations
        case nonFinite
    }

    private let modelURL: URL
    private var compiledURL: URL?
    private var core: Core?

    /// `modelURL`: a `.mlpackage` (compiled once, on first use) or a compiled `.mlmodelc`.
    public init(modelURL: URL) {
        self.modelURL = modelURL
    }

    deinit {
        if let compiledURL, compiledURL != modelURL {
            try? FileManager.default.removeItem(at: compiledURL)
        }
    }

    /// The compiled production model `make model` installs, if it is there (weights are not bundled).
    public static func installed() -> TimestralEngine? {
        let url = URL.applicationSupportDirectory
            .appending(path: "Forewarn/Models/Timestral-5M-core-32768-fp32.mlmodelc")
        return FileManager.default.fileExists(atPath: url.path) ? TimestralEngine(modelURL: url) : nil
    }

    /// Drops the model from memory (on AC). The next forecast loads it again.
    public func unload() {
        core = nil
    }

    public func forecast(_ request: ForecastRequest) async throws -> QuantileForecast {
        guard request.horizon >= 1 else { return QuantileForecast(values: Array(repeating: [], count: 21)) }
        let target = request.target.map { Float($0) }
        guard target.contains(where: \.isFinite) else { throw Failure.noObservations }
        let core = try await loaded()
        let context = Timestral.leftPad(target, to: core.context)
        let mirror = Timestral.Row(values: context.values.map { -$0 }, observed: context.observed)
        let raw = try Timestral.decode([context, mirror], horizon: request.horizon, patches: core.patches) {
            try core.predict($0)
        }
        return QuantileForecast(values: Timestral.clampsym(raw[0], raw[1], target: target))
    }

    private func loaded() async throws -> Core {
        if let core {
            return core
        }
        let compiled: URL
        if modelURL.pathExtension == "mlmodelc" {
            compiled = modelURL
        } else if let compiledURL, FileManager.default.fileExists(atPath: compiledURL.path) {
            compiled = compiledURL
        } else {
            compiled = try await MLModel.compileModel(at: modelURL)
            compiledURL = compiled
        }
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndGPU // never the Neural Engine: it runs fp16, which breaks the tails
        let core = try Core(MLModel(contentsOf: compiled, configuration: config))
        self.core = core
        return core
    }

    /// The converted `spike.Core`: fixed context and horizon patches, read from the model's input shapes.
    struct Core {
        let model: MLModel
        let context: Int
        let patches: Int

        init(_ model: MLModel) throws {
            let inputs = model.modelDescription.inputDescriptionsByName
            guard let scaled = inputs["scaled"]?.multiArrayConstraint?.shape.map(\.intValue),
                  let positions = inputs["positions"]?.multiArrayConstraint?.shape.map(\.intValue),
                  scaled.count == 2, scaled[0] == 2, scaled[1] % Timestral.patchSize == 0,
                  positions.count == 2, positions[1] > scaled[1] / Timestral.patchSize
            else { throw Failure.badModel("expected scaled (2, T) and positions (2, T/32 + h)") }
            self.model = model
            context = scaled[1]
            patches = positions[1] - scaled[1] / Timestral.patchSize
        }

        /// Normalized quantiles `(rows, patches * 32, 21)`, flattened per row.
        func predict(_ features: [String: MLFeatureValue]) throws -> [[Float]] {
            let out = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: features))
            guard let quantiles = out.featureValue(for: "quantiles")?.shapedArrayValue(of: Float.self) else {
                throw Failure.badModel("no quantiles output")
            }
            let perRow = quantiles.scalarCount / 2
            let scalars = quantiles.scalars
            return [Array(scalars[..<perRow]), Array(scalars[perRow...])]
        }
    }
}

/// Port of the reference package around the neural core. Names follow the Python functions they port.
enum Timestral {
    static let patchSize = 32
    static let quantiles = 21
    static let medianIndex = 10
    static let minimumScale = 1e-6
    static let capK: Float = 1e4 // TimestralForecaster.quantile_real_cap_k
    static let extremeValue: Float = 1e30 // TimestralForecaster.extreme_value_threshold

    /// One packed row: values (0 where missing, like `_as_context`) and its observation mask.
    struct Row {
        var values: [Float]
        var observed: [Bool]
    }

    /// Keeps the most recent `length` steps and pads the front as missing. Leading missing patches are never
    /// attention keys, carry no statistics and shift no position, so padding to the fixed context is exact.
    static func leftPad(_ target: [Float], to length: Int) -> Row {
        let recent = target.suffix(length)
        let padded = Array(repeating: Float.nan, count: length - recent.count) + recent
        return Row(values: padded.map { $0.isFinite ? $0 : 0 }, observed: padded.map(\.isFinite))
    }

    /// `scaler.causal_patch_loc_scale`: per patch, the float64 running mean and Bessel std of every observed
    /// value up to the end of the patch (std floored at `minimum_scale`), rounded to Float as PyTorch does.
    static func patchLocScale(_ row: Row) -> (loc: [Float], scale: [Float]) {
        var loc: [Float] = [], scale: [Float] = []
        var count = 0.0, sum = 0.0, m2 = 0.0, previousMean = 0.0
        for (t, value) in row.values.enumerated() {
            let weight = row.observed[t] ? 1.0 : 0.0, x = Double(value)
            count += weight
            sum += weight * x
            let denominator = max(count, 1)
            let mean = sum / denominator
            m2 += (x - previousMean) * (x - mean) * weight
            previousMean = mean
            if t % patchSize == patchSize - 1 {
                loc.append(Float(mean))
                scale.append(Float(max((m2 / max(denominator - 1, 1)).squareRoot(), minimumScale)))
            }
        }
        return (loc, scale)
    }

    /// `TimestralForecaster._block_ar_decode` plus `_cap_quantiles`: `(steps, 21)` raw quantiles per row.
    /// Every block runs the core's full `patches` and keeps the first `block`: decoder tokens and refine
    /// frames are causal, so the kept patches equal a shorter decode.
    static func decode(
        _ rows: [Row], horizon: Int, patches: Int, predict: ([String: MLFeatureValue]) throws -> [[Float]]
    ) throws -> [[Float]] {
        let caps = rows.map(cap)
        var rows = rows, out = Array(repeating: [Float](), count: rows.count)
        var remaining = (horizon + patchSize - 1) / patchSize
        while remaining > 0 {
            let block = min(patches, remaining), steps = block * patchSize
            let frames = rows.map(patchLocScale)
            let normalized = try predict(features(rows, frames: frames, patches: patches))
            for r in rows.indices {
                let (loc, scale) = (frames[r].loc.last!, frames[r].scale.last!)
                var q = normalized[r].map { sinh($0) * scale + loc } // scaler.invert_affine_asinh
                clampNonfinite(&q)
                refine(&q, row: rows[r], loc: loc, scale: scale, patches: patches)
                let kept = q.prefix(steps * quantiles)
                out[r] += kept
                let median = stride(from: medianIndex, to: kept.count, by: quantiles).map { kept[$0] }
                rows[r].values = Array(rows[r].values.dropFirst(steps))
                    + median.map { $0.isFinite && abs($0) < extremeValue ? $0 : 0 } // replace_extreme_values
                rows[r].observed = Array(rows[r].observed.dropFirst(steps)) + Array(repeating: true, count: steps)
            }
            remaining -= block
        }
        return try zip(out, caps).map { q, cap in
            let q = q.prefix(horizon * quantiles)
            guard !q.contains(where: \.isNaN) else { throw TimestralEngine.Failure.nonFinite }
            return q.map { min(max($0, cap.lower), cap.upper) }
        }
    }

    /// The tensors `_predict_context_only` builds before the transformer (`spike.core_inputs`).
    /// Both rows share one observation mask (a series and its mirror), so the masks are built once.
    static func features(_ rows: [Row], frames: [(loc: [Float], scale: [Float])], patches h: Int) throws
        -> [String: MLFeatureValue]
    {
        let length = rows[0].values.count, l = length / patchSize, n = l + h
        var scaled: [Float] = []
        for (row, frame) in zip(rows, frames) { // scaler.apply_affine_asinh_masked, in Float
            scaled += row.values.indices.map { t in
                let p = t / patchSize
                return row.observed[t] ? asinh((row.values[t] - frame.loc[p]) / max(frame.scale[p], .ulpOfOne)) : 0
            }
        }
        let observedPatch = (0 ..< l)
            .map { p in rows[0].observed[p * patchSize ..< (p + 1) * patchSize].contains(true) }
        let firstObserved = observedPatch.firstIndex(of: true) ?? 0 // group_first_observed_patch
        // compute_enc_key_validity with attend_missing_patches: valid once the series has started.
        let keyValid = observedPatch.indices.map { $0 >= firstObserved && observedPatch[firstObserved] }
        var timeMask = [Float](repeating: 0, count: n * n) // build_forecast_time_mask
        for i in 0 ..< l {
            for j in 0 ... i where keyValid[j] || j == i {
                timeMask[i * n + j] = 1
            }
        }
        for d in 0 ..< h {
            for j in 0 ..< l where keyValid[j] {
                timeMask[(l + d) * n + j] = 1
            }
            for j in l ... l + d {
                timeMask[(l + d) * n + j] = 1
            }
        }
        let r = rows.count
        // Each row is its own series: the variate mask is the identity on every slot.
        let eye = (0 ..< r * r).map { $0 % (r + 1) == 0 ? Float(1) : 0 }
        let positions = (0 ..< n).map { Int32($0 - firstObserved) } // build_forecast_positions
        return try [
            "scaled": multiArray(scaled, shape: [r, length]),
            "observed": multiArray(rows.flatMap { $0.observed.map { $0 ? Float(1) : 0 } }, shape: [r, length]),
            "time_mask": multiArray(timeMask, repeated: r, shape: [r, 1, n, n]),
            "variate_mask": multiArray(eye, repeated: n, shape: [n, 1, r, r]),
            "positions": multiArray(positions, repeated: r, shape: [r, n]),
        ]
    }

    /// `chunk` repeated `repeated` times in a contiguous array. A plain copy: `MLMultiArray(MLShapedArray)`
    /// took 100 ms for the 8 MB time mask.
    static func multiArray<T: MLShapedArrayScalar>(_ chunk: [T], repeated: Int = 1, shape: [Int]) throws
        -> MLFeatureValue
    {
        let bytes = chunk.count * MemoryLayout<T>.stride
        let data = UnsafeMutableRawPointer.allocate(byteCount: bytes * repeated, alignment: 64)
        chunk.withUnsafeBytes { source in
            for i in 0 ..< repeated {
                (data + i * bytes).copyMemory(from: source.baseAddress!, byteCount: bytes)
            }
        }
        let strides = shape.indices.map { shape[($0 + 1)...].reduce(1, *) }
        let array = try MLMultiArray(
            dataPointer: data, shape: shape.map { NSNumber(value: $0) },
            dataType: T.self == Int32.self ? .int32 : .float32,
            strides: strides.map { NSNumber(value: $0) }
        ) { $0.deallocate() }
        return MLFeatureValue(multiArray: array)
    }

    /// `scaler.clamp_nonfinite` over each step's quantiles: ±inf (a sinh overflow) to the nearest finite value.
    static func clampNonfinite(_ q: inout [Float]) {
        for start in stride(from: 0, to: q.count, by: quantiles) {
            let step = start ..< start + quantiles
            guard q[step].contains(where: \.isInfinite) else { continue }
            let finite = q[step].filter(\.isFinite)
            for i in step where q[i].isInfinite {
                q[i] = (q[i] > 0 ? finite.max() : finite.min()) ?? 0
            }
        }
    }

    /// `TimestralForecaster._refine_block`: moves horizon patches 1… from the anchor frame of the last
    /// context patch to the advancing refine frame (`scaler.advancing_block_frames`).
    static func refine(_ q: inout [Float], row: Row, loc: Float, scale: Float, patches: Int) {
        guard patches > 1 else { return }
        // Welford state (count, mean, m2) of the observed context, per patch then folded in order.
        // Sequential fold, not the reference's Hillis-Steele scan; differs only in float64 rounding.
        var state = Welford(count: 0, mean: 0, m2: 0)
        for p in 0 ..< row.values.count / patchSize {
            let xs = (p * patchSize ..< (p + 1) * patchSize).filter { row.observed[$0] }.map { Double(row.values[$0]) }
            guard !xs.isEmpty else { continue }
            let mean = xs.reduce(0, +) / Double(xs.count)
            state = state.combined(with: Welford(
                count: Double(xs.count), mean: mean, m2: xs.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
            ))
        }
        let offset = state.mean // medians are clamped relative to the context mean
        let clip = Double(Float.greatestFiniteMagnitude).squareRoot() / 1e3
        var locs = [loc], scales = [scale]
        for j in 0 ..< patches - 1 {
            let frameScale = max(max(state.m2 / max(state.count - 1, 1), 0).squareRoot(), minimumScale)
            let folded = (0 ..< patchSize).map { k in
                let sinhMedian = (Double(q[(j * patchSize + k) * quantiles + medianIndex]) - Double(loc)) /
                    Double(scale)
                return min(max(sinhMedian * frameScale + state.mean - offset, -clip), clip) + offset
            }
            let mean = folded.reduce(0, +) / Double(patchSize)
            let m2 = folded.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
            state = state.combined(with: Welford(count: Double(patchSize), mean: mean, m2: m2))
            let nextScale = max(max(state.m2 / max(state.count - 1, 1), 0).squareRoot(), minimumScale)
            locs.append(Float(state.mean))
            scales.append(Float(nextScale))
        }
        for i in q.indices {
            let p = i / quantiles / patchSize
            q[i] = (q[i] - loc) / scale * scales[p] + locs[p]
        }
        clampNonfinite(&q)
    }

    /// A float64 Welford state of observed values.
    struct Welford {
        var count: Double
        var mean: Double
        var m2: Double

        /// `scaler.welford_combine`, same operation order.
        func combined(with other: Welford) -> Welford {
            let total = count + other.count
            guard total != 0 else { return Welford(count: 0, mean: 0, m2: 0) }
            let delta = other.mean - mean
            return Welford(
                count: total,
                mean: mean + delta * other.count / total,
                m2: m2 + other.m2 + delta * delta * count * other.count / total
            )
        }
    }

    /// `_cap_quantiles` bounds: `[min - k s, max + k s]` of the observed context, `s` the last patch's scale.
    static func cap(_ row: Row) -> (lower: Float, upper: Float) {
        let seen = row.values.indices.filter { row.observed[$0] }.map { row.values[$0] }
        let bound = patchLocScale(row).scale.last! * capK
        return ((seen.min() ?? 0) - bound, (seen.max() ?? 0) + bound)
    }

    /// `TimestralForecaster.forecast` clampsym: average with the reflected mirror forecast, then clamp at 0
    /// when every observed context value is non-negative. Returns `values[level][step]`.
    static func clampsym(_ q: [Float], _ mirrored: [Float], target: [Float]) -> [[Double]] {
        let clip = !target.contains { $0.isFinite && $0 < 0 }
        return (0 ..< quantiles).map { level in
            stride(from: 0, to: q.count, by: quantiles).map { step in
                let value = 0.5 * (q[step + level] + -mirrored[step + quantiles - 1 - level])
                return Double(clip ? max(value, 0) : value)
            }
        }
    }
}
