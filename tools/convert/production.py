"""Production Timestral model and end-to-end parity vectors for TimestralEngine.

`uv run production.py model`: writes only the model the app loads (`make model` installs it):
    out/Timestral-5M-core-32768-fp32.mlpackage, horizon patches for 144 steps.
`uv run production.py vectors`: raw target series and the expected `TimestralForecaster.forecast`
    quantiles, for the Swift check in ForewarnKit/Tests (TimestralEngineTests).
"""

import json
import math
import sys

import coremltools as ct
import numpy as np
import torch
from timestral import TimestralForecaster

from spike import OUT, Core, battery_history, convert, core_inputs

REPO = "mistralai/Timestral-5M"
CONTEXT = 32768  # the model's trained context
HORIZON = 144  # 12 h on the 5-min grid
MODEL = OUT / f"Timestral-5M-core-{CONTEXT}-fp32.mlpackage"
VECTORS = OUT / "Timestral-5M-e2e.json"


def model() -> None:
    forecaster = TimestralForecaster.from_pretrained(REPO, device="cpu")
    net = forecaster.model.eval()
    h = math.ceil(HORIZON / net.config.patch_size)
    # Tracing only fixes shapes; any series of the right length will do. Rows: series and its mirror.
    x = torch.linspace(100, 20, CONTEXT)[None].repeat(2, 1) * torch.tensor([[1.0], [-1.0]])
    tensors, _, _ = core_inputs(net, x, torch.ones_like(x, dtype=torch.bool), torch.arange(2), h)
    OUT.mkdir(exist_ok=True)
    convert(Core(net, h), tensors, ct.precision.FLOAT32).save(str(MODEL))
    print(MODEL)


def synthetic(steps: int, seed: int) -> np.ndarray:
    """Battery-like sawtooth (discharge, charge to 100) with noise and missing runs."""
    rng = np.random.default_rng(seed)
    level, charging, out = 80.0, False, np.empty(steps)
    for i in range(steps):
        level += rng.uniform(1.5, 3.0) if charging else -rng.uniform(0.0, 0.8)
        if level <= 15 or level >= 100:
            charging = level <= 15
            level = min(level, 100.0)
        out[i] = level + rng.normal(0, 0.3)
    for start in rng.integers(0, steps, size=steps // 400):  # gaps of 5 min to ~8 h
        out[start : start + rng.integers(1, 100)] = np.nan
    return out


def vectors() -> None:
    forecaster = TimestralForecaster.from_pretrained(REPO, device="cpu")
    # Horizons longer than the Core ML block are decoded block by block, 5 patches per shot.
    five = TimestralForecaster(forecaster.model, per_shot_horizon_patches=5)
    t = np.arange(600)
    signed = np.sin(t / 30) * 4 - 1.5  # negative values: no non-negative clipping
    signed[100:180] = np.nan
    cases = [("synthetic_gaps", synthetic(40_000, 0), 144, forecaster),  # longer than the context
             ("signed_short_horizon", signed, 50, forecaster),
             ("synthetic_multi_block", synthetic(3_000, 1), 400, five)]
    try:
        charge, _, _ = battery_history()
        cases = [("battery_pmset", charge.astype(np.float64), 144, forecaster), *cases]
    except (SystemExit, OSError) as e:  # desktop Mac: no battery log
        print("skipping pmset series:", e, file=sys.stderr)
    out = []
    for name, series, horizon, fc in cases:
        q = fc.forecast(series.astype(np.float32), horizon).quantiles[0, 0].T  # (Q, H)
        out.append({
            "name": name,
            "horizon": horizon,
            "target": [None if np.isnan(v) else float(np.float32(v)) for v in series],
            "expected": q.double().tolist(),
        })
        print(name, len(series), "steps, horizon", horizon, flush=True)
    OUT.mkdir(exist_ok=True)
    VECTORS.write_text(json.dumps(out))
    print(VECTORS)


if __name__ == "__main__":
    {"model": model, "vectors": vectors}[sys.argv[1] if len(sys.argv) > 1 else "model"]()
