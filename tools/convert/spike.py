"""Timestral -> Core ML conversion research. Run with `uv run spike.py`; results land in out/.

1. Reference: run the timestral package on CPU on this Mac's real battery history (`pmset -g log`).
2. Convert: whole `predict_block` first; fall back to the neural core (patch embedding, transformer,
   quantile head) with normalization, masks and positions left to Swift.
3. Parity: Core ML vs PyTorch at fp32 and fp16.
4. Latency: PyTorch CPU and Core ML, across context lengths up to the model's 32,768 steps.
"""

import json
import re
import subprocess
import sys
import time
import traceback
from datetime import datetime, timedelta
from pathlib import Path

import coremltools as ct
import numpy as np
import torch
from timestral import TimestralForecaster
from timestral.masks import (
    build_forecast_positions,
    build_forecast_time_mask,
    build_two_stream_positions,
    build_two_stream_time_mask,
    build_two_stream_variate_mask,
    compute_enc_key_validity,
    group_first_observed_patch,
)
from timestral.model import ROLE_KNOWN_COV, ROLE_TARGET
from timestral.scaler import denormalize_quantiles

OUT = Path(__file__).parent / "out"
MODELS = ["mistralai/Timestral-5M", "mistralai/Timestral-28M"]
STEP = timedelta(minutes=5)  # battery grid
HORIZON = 144  # 12 h
CONTEXT = 4096  # fixed Core ML context for parity (~14 days at 5 min)
SWEEP = [2048, 4096, 8192, 16384, 32768]
LINE = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d [+-]\d{4}) .*Using (AC|Batt)\(Charge: (\d+)\)")


def battery_history() -> tuple[np.ndarray, np.ndarray, datetime]:
    """5-min grid of battery % (NaN where no sample) and on-AC (carried forward) from `pmset -g log`."""
    log = subprocess.run(["pmset", "-g", "log"], capture_output=True, text=True, check=True).stdout
    events = [
        (datetime.strptime(m[1], "%Y-%m-%d %H:%M:%S %z"), m[2] == "AC", float(m[3]))
        for m in map(LINE.match, log.splitlines())
        if m
    ]
    if not events:
        sys.exit("no battery samples in pmset log (desktop Mac?)")
    start = events[0][0].replace(second=0, minute=events[0][0].minute // 5 * 5)
    n = int((events[-1][0] - start) / STEP) + 1
    charge = np.full(n, np.nan, dtype=np.float32)
    on_ac = np.full(n, np.nan, dtype=np.float32)
    for ts, ac, pct in events:
        i = int((ts - start) / STEP)
        charge[i], on_ac[i] = pct, float(ac)  # last sample in a bin wins
    for i in range(1, n):  # the AC state holds until the next event
        if np.isnan(on_ac[i]):
            on_ac[i] = on_ac[i - 1]
    return charge, on_ac, start


def left_pad(x: np.ndarray, length: int) -> np.ndarray:
    """Fit to `length` steps: keep the most recent ones, pad the front with NaN (missing)."""
    x = x[-length:]
    return np.concatenate([np.full(length - len(x), np.nan, dtype=np.float32), x])


def timed(fn, runs: int = 5) -> tuple[float, object]:
    """Median wall time in ms over `runs`, after one warm-up call."""
    result = fn()
    times = []
    for _ in range(runs):
        t0 = time.perf_counter()
        fn()
        times.append((time.perf_counter() - t0) * 1000)
    return float(np.median(times)), result


class Core(torch.nn.Module):
    """Neural part of `predict_block`: everything between normalization and denormalization.

    `dec_patches` decoder tokens follow the encoder (the horizon without covariates, the whole
    window with them); only the last `horizon_patches` are returned.
    """

    def __init__(self, model, horizon_patches: int, dec_patches: int | None = None) -> None:
        super().__init__()
        self.model = model
        self.dec = dec_patches or horizon_patches
        self.keep = horizon_patches * model.config.patch_size

    def forward(self, scaled, observed, time_mask, variate_mask, positions):
        observed = observed > 0.5
        x_enc = self.model.representation(scaled, observed)
        x_dec = self.model.representation.forecast_tokens(scaled.shape[0], self.dec)
        out = self.model._run_two_stream(x_enc, x_dec, time_mask > 0.5, variate_mask > 0.5, positions)
        return out[:, -self.keep :]


class WholeBlock(torch.nn.Module):
    def __init__(self, model, horizon_patches: int) -> None:
        super().__init__()
        self.model = model
        self.h = horizon_patches
        self.register_buffer("group_ids", torch.arange(2))

    def forward(self, inputs, observed):
        return self.model.predict_block(inputs, observed > 0.5, self.group_ids, self.h)


def core_inputs(model, inputs: torch.Tensor, observed: torch.Tensor, group_ids: torch.Tensor, h: int):
    """The tensors `_predict_context_only` builds before the transformer (Swift computes these)."""
    c = model.config
    ps = c.patch_size
    ll = inputs.shape[1] // ps
    scaled, loc, scale = model.scale(inputs, observed)
    obs_per_patch = observed.unflatten(-1, (ll, ps)).any(dim=-1)
    key_valid = compute_enc_key_validity(obs_per_patch, c.attend_missing_patches)
    time_mask = build_forecast_time_mask(ll, h, key_valid, inputs.device)
    variate_mask = build_two_stream_variate_mask(group_ids, key_valid, h)
    unique_ids, inverse = torch.unique(group_ids, return_inverse=True)
    first_obs = group_first_observed_patch(obs_per_patch, inverse, unique_ids.numel())[inverse]
    positions = build_forecast_positions(ll, h, first_obs)
    anchor_loc = loc.unflatten(-1, (ll, ps))[..., 0][:, ll - 1 : ll].unsqueeze(-1)
    anchor_scale = scale.unflatten(-1, (ll, ps))[..., 0][:, ll - 1 : ll].unsqueeze(-1)
    tensors = {
        "scaled": scaled.float(),
        "observed": observed.float(),
        "time_mask": time_mask.float(),
        "variate_mask": variate_mask.float(),
        "positions": positions.int(),
    }
    return tensors, anchor_loc, anchor_scale


def window_inputs(model, rows: torch.Tensor, observed: torch.Tensor, group_ids, role_ids, kf, kfm, h: int):
    """The tensors `_predict_window` (known-future covariates) builds before the transformer."""
    c = model.config
    ps = c.patch_size
    full = torch.cat([rows, kf], dim=-1)
    full_obs = torch.cat([observed, kfm], dim=-1)
    n = full.shape[1] // ps
    ll = n - h
    target_rows, known_rows = role_ids == ROLE_TARGET, role_ids == ROLE_KNOWN_COV
    scaled, loc, scale = model.scale(full, full_obs)
    scaled, loc, scale = model._known_cov_scaling(full, full_obs, scaled, loc, scale, known_rows)
    obs_per_patch = full_obs.unflatten(-1, (n, ps)).any(dim=-1)
    key_valid = compute_enc_key_validity(obs_per_patch, c.attend_missing_patches)
    s_rows = torch.full((full.shape[0],), ll, dtype=torch.long)
    time_mask = build_two_stream_time_mask(s_rows, n, c.block_size, key_valid, bidirectional_rows=known_rows)
    variate_mask = build_two_stream_variate_mask(
        group_ids, key_valid, n, target_rows=target_rows, bidirectional_rows=known_rows
    )
    unique_ids, inverse = torch.unique(group_ids, return_inverse=True)
    first_obs = group_first_observed_patch(obs_per_patch, inverse, unique_ids.numel())[inverse]
    positions = build_two_stream_positions(n, first_obs)
    anchor_loc = loc.unflatten(-1, (n, ps))[..., 0][:, ll - 1 : ll].unsqueeze(-1)
    anchor_scale = scale.unflatten(-1, (n, ps))[..., 0][:, ll - 1 : ll].unsqueeze(-1)
    tensors = {
        "scaled": scaled.float(),
        "observed": full_obs.float(),
        "time_mask": time_mask.float(),
        "variate_mask": variate_mask.float(),
        "positions": positions.int(),
    }
    return tensors, anchor_loc, anchor_scale, n


def failure(stage: str, e: Exception) -> dict:
    """What failed and where, for the report; the traceback goes to the console."""
    traceback.print_exc(limit=3)
    return {"failed_stage": stage, "error": f"{type(e).__name__}: {str(e).splitlines()[0][:300] if str(e) else ''}"}


def convert(module, example: dict[str, torch.Tensor], precision) -> ct.models.MLModel:
    traced = torch.jit.trace(module.eval(), tuple(example.values()), check_trace=False)
    return ct.convert(
        traced,
        inputs=[ct.TensorType(name=k, shape=v.shape, dtype=np.int32 if v.dtype == torch.int32 else np.float32)
                for k, v in example.items()],
        outputs=[ct.TensorType(name="quantiles", dtype=np.float32)],
        convert_to="mlprogram",
        compute_precision=precision,
        minimum_deployment_target=ct.target.macOS15,
    )


def spike(repo: str, charge: np.ndarray, on_ac: np.ndarray, start: datetime) -> dict:
    name = repo.split("/")[1]
    report: dict = {"model": name}
    forecaster = TimestralForecaster.from_pretrained(repo, device="cpu")
    model = forecaster.model.eval()
    ps = model.config.patch_size
    h = -(-HORIZON // ps)

    # 1. Reference on real data, univariate and with known-future covariates .
    context = left_pad(charge, CONTEXT)
    report["reference_ms"], ref = timed(lambda: forecaster.forecast(context, HORIZON))
    steps = [start + STEP * i for i in range(len(charge) - CONTEXT, len(charge) + HORIZON)]
    future_ac = np.full(HORIZON, on_ac[-1], dtype=np.float32)  # assume the current power state holds
    known = np.stack([
        [t.hour / 23 for t in steps],
        [t.weekday() / 6 for t in steps],
        np.concatenate([left_pad(on_ac, CONTEXT), future_ac]),
    ]).astype(np.float32)[None]
    report["reference_covariates_ms"], ref_cov = timed(
        lambda: forecaster.forecast(context, HORIZON, known_covariates=known)
    )
    report["median_next_12h"] = {
        "univariate": ref.median[0, 0, ::12].numpy().round(1).tolist(),
        "with_covariates": ref_cov.median[0, 0, ::12].numpy().round(1).tolist(),
    }

    # The packed rows `predict_block` sees for both passes of symmetric averaging, as one R=2 batch.
    x, mask = forecaster._as_context(context, None)
    rows, rows_mask, *_ = forecaster._assemble_rows(torch.cat([x, -x]), torch.cat([mask, mask]), HORIZON, None, None)
    rows, rows_mask = rows[:, 0], rows_mask[:, 0]
    group_ids = torch.arange(2)
    with torch.inference_mode():
        expected = model.predict_block(rows, rows_mask, group_ids, h)

    # 2a. Whole predict_block.
    try:
        convert(WholeBlock(model, h), {"inputs": rows, "observed": rows_mask.float()}, ct.precision.FLOAT32)
        report["whole_block"] = "converted"
    except Exception as e:  # noqa: BLE001 - the failure is the finding
        report["whole_block"] = f"failed: {type(e).__name__}: {str(e).splitlines()[0][:300]}"
        traceback.print_exc(limit=3)

    # 2b. Neural core; prove the split reproduces predict_block before converting it.
    tensors, anchor_loc, anchor_scale = core_inputs(model, rows, rows_mask, group_ids, h)
    core = Core(model, h).eval()
    with torch.inference_mode():
        normalized = core(*tensors.values())
        split = denormalize_quantiles(normalized, anchor_loc, anchor_scale, model.config.use_asinh)
    report["split_matches_predict_block_max_abs"] = float((split - expected).abs().max())

    report["coreml"] = {}
    for label, precision in [("fp32", ct.precision.FLOAT32), ("fp16", ct.precision.FLOAT16)]:
        # Each stage can fail on its own (a model that converts may not compile or run): record which, carry on.
        stage = "convert"
        try:
            mlmodel = convert(core, tensors, precision)
            stage = "save"
            mlmodel.save(str(OUT / f"{name}-core-{CONTEXT}-{label}.mlpackage"))
            stage = "predict"
            feed = {k: v.numpy() for k, v in tensors.items()}
            ms, out = timed(lambda: mlmodel.predict(feed))
            got = torch.from_numpy(out["quantiles"]).double()
            denorm = denormalize_quantiles(got, anchor_loc, anchor_scale, model.config.use_asinh)
            report["coreml"][label] = {
                "predict_ms": ms,
                "normalized_max_abs": float((got - normalized.double()).abs().max()),
                "battery_pct_max_abs": float((denorm - expected.double()).abs().max()),
                "median_battery_pct_max_abs": float((denorm - expected.double())[..., 10].abs().max()),
            }
        except Exception as e:  # noqa: BLE001 - the failure is the finding
            report["coreml"][label] = failure(stage, e)

    # 2c. Known-future covariates (hour, weekday, on-AC): same core, two-stream window masks.
    kc = torch.as_tensor(known)
    x, mask = forecaster._as_context(context, None)
    rows_c, mask_c, role_ids, kf, kfm, _ = forecaster._assemble_rows(
        torch.cat([x, -x]), torch.cat([mask, mask]), HORIZON, None, torch.cat([kc, -kc])
    )
    b, v, t_len = rows_c.shape
    rows_c, mask_c = rows_c.reshape(b * v, t_len), mask_c.reshape(b * v, t_len)
    groups_c = torch.arange(b).repeat_interleave(v)
    kf, kfm = kf[:, : h * ps], kfm[:, : h * ps]
    with torch.inference_mode():
        expected_c = model.predict_block(rows_c, mask_c, groups_c, h, role_ids, kf, kfm)
        tensors_c, loc_c, scale_c, n = window_inputs(model, rows_c, mask_c, groups_c, role_ids, kf, kfm, h)
        core_c = Core(model, h, dec_patches=n).eval()
        normalized_c = core_c(*tensors_c.values())
        split_c = denormalize_quantiles(normalized_c, loc_c, scale_c, model.config.use_asinh)
    report["covariates_split_matches_predict_block_max_abs"] = float((split_c - expected_c).abs().max())
    report["coreml_covariates"] = {}
    targets = role_ids == ROLE_TARGET  # only target rows are forecasts
    for label, precision in [("fp32", ct.precision.FLOAT32), ("fp16", ct.precision.FLOAT16)]:
        stage = "convert"
        try:
            ml = convert(core_c, tensors_c, precision)
            stage = "save"
            ml.save(str(OUT / f"{name}-core-cov-{CONTEXT}-{label}.mlpackage"))
            stage = "predict"
            feed = {k: v.numpy() for k, v in tensors_c.items()}
            ms, out = timed(lambda: ml.predict(feed))
            got = torch.from_numpy(out["quantiles"]).double()
            denorm = denormalize_quantiles(got, loc_c, scale_c, model.config.use_asinh)
            diff = (denorm - expected_c.double())[targets]
            report["coreml_covariates"][label] = {
                "predict_ms": ms,
                "battery_pct_max_abs": float(diff.abs().max()),
                "median_battery_pct_max_abs": float(diff[..., 10].abs().max()),
            }
        except Exception as e:  # noqa: BLE001
            report["coreml_covariates"][label] = failure(stage, e)
    (OUT / f"{name}-parity-cov-{CONTEXT}.json").write_text(json.dumps({
        **{k: v.flatten().tolist() for k, v in tensors_c.items()},
        "shapes": {k: list(v.shape) for k, v in tensors_c.items()},
        "expected": normalized_c.flatten().tolist(),
        "expected_shape": list(normalized_c.shape),
    }))

    # 3. Parity vectors for Parity.swift: core inputs and the PyTorch output.
    vectors = {k: v.flatten().tolist() for k, v in tensors.items()}
    vectors["shapes"] = {k: list(v.shape) for k, v in tensors.items()}
    vectors["expected"] = normalized.flatten().tolist()
    vectors["expected_shape"] = list(normalized.shape)
    (OUT / f"{name}-parity-{CONTEXT}.json").write_text(json.dumps(vectors))

    # 4. Context-length sweep: PyTorch reference vs Core ML core (fp16), same real series left-padded.
    report["sweep"] = []
    for length in SWEEP:
        ctx = left_pad(charge, length)
        torch_ms, _ = timed(lambda: forecaster.forecast(ctx, HORIZON), runs=3)
        x, mask = forecaster._as_context(ctx, None)
        r, rm, *_ = forecaster._assemble_rows(torch.cat([x, -x]), torch.cat([mask, mask]), HORIZON, None, None)
        t, _, _ = core_inputs(model, r[:, 0], rm[:, 0], group_ids, h)
        entry = {"context": length, "days": round(length * 5 / 1440, 1), "torch_ms": torch_ms}
        try:
            ml = convert(core, t, ct.precision.FLOAT16)
            path = OUT / f"{name}-core-{length}-fp16.mlpackage"
            ml.save(str(path))
            entry["coreml_fp16_ms"], _ = timed(lambda: ml.predict({k: v.numpy() for k, v in t.items()}), runs=3)
        except Exception as e:  # noqa: BLE001
            entry["coreml_fp16"] = f"failed: {type(e).__name__}"
        report["sweep"].append(entry)
        print(name, entry, flush=True)
    return report


def main() -> None:
    OUT.mkdir(exist_ok=True)
    torch.manual_seed(0)
    charge, on_ac, start = battery_history()
    data = {
        "source": "pmset -g log",
        "first": start.isoformat(),
        "steps": len(charge),
        "days": round(len(charge) * 5 / 1440, 1),
        "observed_steps": int(np.isfinite(charge).sum()),
    }
    print(data, flush=True)
    results = {"data": data, "torch": torch.__version__, "coremltools": ct.__version__, "models": []}
    for repo in MODELS:
        results["models"].append(spike(repo, charge, on_ac, start))
        (OUT / "results.json").write_text(json.dumps(results, indent=2))
    print(json.dumps(results, indent=2))


if __name__ == "__main__":
    main()
