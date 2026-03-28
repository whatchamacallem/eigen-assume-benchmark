#!/usr/bin/env bash
# compare-with-assume.sh
# Builds (if needed), runs, and compares baseline vs __builtin_assume benchmarks.
#
# Usage:
#   ./compare-with-assume.sh [BENCH...]
#
# Examples:
#   ./compare-with-assume.sh                          # run all Core benchmarks
#   ./compare-with-assume.sh bench_gemm bench_gemv    # run specific benchmarks
#
# Output: a table comparing baseline vs assume median real_time, with % delta.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

CXX="${CXX:-clang++-18}"
JOBS="${JOBS:-$(nproc)}"
REPS="${REPS:-5}"

BUILD_BASELINE="build/baseline"
BUILD_ASSUME="build/assume"
RESULTS_BASELINE="results/baseline"
RESULTS_ASSUME="results/assume"

ALL_BENCHES=(
  bench_gemm
  bench_gemm_double
  bench_gemv
  bench_vecadd
  bench_reductions
  bench_fixed_size
  bench_fixed_size_double
  bench_trsm
  bench_trmv
  bench_triangular_product
  bench_selfadjoint_product
  bench_dot
  bench_block_ops
)

KEEP_BASELINE=false
SAVED=false
ARGS=()
for arg in "$@"; do
  if [[ "$arg" == "baseline" ]]; then
    KEEP_BASELINE=true
  elif [[ "$arg" == "saved" ]]; then
    SAVED=true
  else
    ARGS+=("$arg")
  fi
done

if [[ ${#ARGS[@]} -gt 0 ]]; then
  BENCHES=("${ARGS[@]}")
else
  BENCHES=("${ALL_BENCHES[@]}")
fi

# ── build ──────────────────────────────────────────────────────────────────────

build_if_needed() {
  local dir="$1" extra_flags="$2" label="$3"
  if [[ ! -f "$dir/Core/bench_gemm" ]]; then
    echo "==> Configuring $label..."
    cmake -S benchmarks -B "$dir" \
      -DCMAKE_CXX_COMPILER="$CXX" \
      -DCMAKE_BUILD_TYPE=Release \
      ${extra_flags:+-DCMAKE_CXX_FLAGS="$extra_flags"} \
      -DCMAKE_RULE_MESSAGES=OFF \
      -DCMAKE_VERBOSE_MAKEFILE=OFF \
      2>&1 | grep -v "^--"
    echo "==> Building $label..."
    cmake --build "$dir" -j"$JOBS" 2>&1 | grep -v "^\[" | grep -v "^$" || true
    echo "==> $label build done."
  else
    echo "==> $label already built, skipping."
  fi
}

if ! $SAVED; then
  build_if_needed "$BUILD_BASELINE" "" "baseline"
  build_if_needed "$BUILD_ASSUME" "-DEIGEN_ASSERT_USE_BUILTIN_ASSUME" "assume"
  mkdir -p "$RESULTS_BASELINE" "$RESULTS_ASSUME"
fi

# ── run ────────────────────────────────────────────────────────────────────────

run_bench() {
  local variant="$1" build_dir="$2" results_dir="$3"
  for b in "${BENCHES[@]}"; do
    local bin="$build_dir/Core/$b"
    local out="$results_dir/${b}.json"
    if [[ ! -x "$bin" ]]; then
      echo "  [skip] $b not found in $variant build" >&2
      continue
    fi
    echo -n "  $variant/$b ... "
    "$bin" \
      --benchmark_repetitions="$REPS" \
      --benchmark_report_aggregates_only=true \
      --benchmark_format=json \
      --benchmark_out="$out" \
      > /dev/null 2>&1
    echo "done"
  done
}

echo ""
if $SAVED; then
  echo "==> Using saved results (skipping all benchmark runs)."
else
  if $KEEP_BASELINE; then
    echo "==> Keeping existing baseline results (skipping re-run)."
  else
    echo "==> Running baseline benchmarks (${REPS} reps each)..."
    run_bench "baseline" "$BUILD_BASELINE" "$RESULTS_BASELINE"
  fi

  echo ""
  echo "==> Running assume benchmarks (${REPS} reps each)..."
  run_bench "assume" "$BUILD_ASSUME" "$RESULTS_ASSUME"
fi

# ── compare ────────────────────────────────────────────────────────────────────

echo ""
python3 - "$RESULTS_BASELINE" "$RESULTS_ASSUME" "${BENCHES[@]}" <<'PYEOF'
import sys, json
from pathlib import Path

baseline_dir, assume_dir = sys.argv[1], sys.argv[2]
bench_names = sys.argv[3:]

def load_medians(results_dir, bench_name):
    path = Path(results_dir) / f"{bench_name}.json"
    if not path.exists():
        return {}
    with open(path) as f:
        raw = f.read()
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as e:
        print(f"WARNING: {path} is corrupt (truncated run?): {e}", file=sys.stderr)
        print(f"  Re-run: {results_dir.replace('results/', '')}/Core/{bench_name} --benchmark_repetitions=5 --benchmark_report_aggregates_only=true --benchmark_format=json --benchmark_out={path}", file=sys.stderr)
        return {}
    out = {}
    for b in data.get("benchmarks", []):
        if b.get("aggregate_name") == "median":
            out[b["name"].replace("_median", "")] = b["real_time"]
    return out

GREEN  = "\033[32m"
RED    = "\033[31m"
YELLOW = "\033[33m"
RESET  = "\033[0m"
BOLD   = "\033[1m"

def delta_color(pct):
    if pct < -1:  return GREEN
    if pct >  1:  return RED
    return YELLOW

rows = []
for bname in bench_names:
    base = load_medians(baseline_dir, bname)
    assu = load_medians(assume_dir,   bname)
    for k in sorted(set(base) & set(assu)):
        b, a = base[k], assu[k]
        rows.append((bname, k, b, a, (a - b) / b * 100))

if not rows:
    print("No results found.")
    sys.exit(1)

# ── per-case detail table ─────────────────────────────────────────────────────
CW = 30
KW = 55
hdr2 = f"{'benchmark':<{CW}}  {'case':<{KW}}  {'baseline':>12}  {'assume':>12}  {'delta':>9}  "
sep2 = "-" * (len(hdr2) + 2)

print(f"\n{BOLD}{'=' * len(sep2)}{RESET}")
print(f"{BOLD}  All cases — baseline vs __builtin_assume{RESET}")
print(f"{BOLD}{'=' * len(sep2)}{RESET}")
print(hdr2)
print(sep2)

cur_bench = None
for bname, k, b, a, pct in rows:
    if bname != cur_bench:
        if cur_bench is not None:
            print()
        print(f"{BOLD}{bname}{RESET}")
        cur_bench = bname
    color = delta_color(pct)
    if pct < -1:
        ind = "▼"
    elif pct > 1:
        ind = "▲"
    else:
        ind = " "
    print(f"  {'':<{CW-2}}{k:<{KW}}  {b:>12.1f}  {a:>12.1f}  {color}{pct:>+8.2f}%{RESET} {color}{ind}{RESET}")

print(sep2)

# ── per-benchmark summary table ───────────────────────────────────────────────
w = 35
hdr = f"{'benchmark':<{w}}  {'cases':>5}  {'faster>1%':>9}  {'slower>1%':>9}  {'avg delta':>10}"
sep = "-" * len(hdr)

print(f"\n{BOLD}{'=' * len(hdr)}{RESET}")
print(f"{BOLD}  eigen_assert baseline  vs  __builtin_assume{RESET}")
print(f"{BOLD}{'=' * len(hdr)}{RESET}")
print(hdr)
print(sep)

by_bench = {}
for r in rows:
    by_bench.setdefault(r[0], []).append(r)

for bname, brows in by_bench.items():
    faster = sum(1 for r in brows if r[4] < -1)
    slower = sum(1 for r in brows if r[4] >  1)
    avg    = sum(r[4] for r in brows) / len(brows)
    color  = delta_color(avg)
    print(f"{bname:<{w}}  {len(brows):>5}  "
          f"{GREEN}{faster:>9}{RESET}  "
          f"{RED}{slower:>9}{RESET}  "
          f"{color}{avg:>+9.2f}%{RESET}")

print(sep)

total_faster = sum(1 for r in rows if r[4] < -1)
total_slower = sum(1 for r in rows if r[4] >  1)
total_wash   = len(rows) - total_faster - total_slower
total_avg    = sum(r[4] for r in rows) / len(rows)
color        = delta_color(total_avg)

print(f"{BOLD}{'TOTAL':<{w}}  {len(rows):>5}  "
      f"{GREEN}{total_faster:>9}{RESET}{BOLD}  "
      f"{RED}{total_slower:>9}{RESET}{BOLD}  "
      f"{color}{total_avg:>+9.2f}%{RESET}")
print(f"\n  wash (within ±1%): {YELLOW}{total_wash}{RESET}  |  total cases: {len(rows)}")
print()
PYEOF
