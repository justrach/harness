"""Run the native cache/scene regression fixture from an isolated Harness checkout.
Usage: python3 run-harness-integration.py CHECKOUT OUTPUT_DIRECTORY [MODE ...]
Build attachment-eviction-fixture first; see the accompanying issue instructions.
All displayed content is synthetic. No engine or application data is loaded.
"""
from pathlib import Path
import json
import os
import signal
import subprocess
import sys

if len(sys.argv) < 3:
    raise SystemExit(__doc__)
root = Path(sys.argv[1]).resolve()
results = Path(sys.argv[2]).resolve()
binary = root / 'target/debug/examples/attachment-eviction-fixture'
if not binary.is_file():
    raise SystemExit('Build the attachment-eviction-fixture example first.')
results.mkdir(parents=True, exist_ok=True)
cases = sys.argv[3:] or ['control', 'empty', 'reuse', 'partial']
records = []
for mode in cases:
    if mode not in ['control', 'empty', 'reuse', 'partial']:
        raise SystemExit('Unknown fixture mode.')
    out = results / mode
    out.mkdir(exist_ok=True)
    home = out / 'isolated-home'
    home.mkdir(exist_ok=True)
    env = os.environ.copy()
    env.update(HOME=str(home), HARNESS_DATA_DIR=str(out / 'isolated-data'),
               HARNESS_AUTO_UPDATE='0', RUST_BACKTRACE='0')
    with (out / 'process.log').open('w') as log:
        proc = subprocess.Popen([str(binary), str(out), mode], cwd=str(root),
                                env=env, stdout=log, stderr=subprocess.STDOUT,
                                start_new_session=True)
        timed_out = False
        try:
            code = proc.wait(timeout=35)
        except subprocess.TimeoutExpired:
            timed_out = True
            os.killpg(proc.pid, signal.SIGTERM)
            try:
                code = proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
                code = proc.wait()
    text = (out / 'process.log').read_text(errors='replace')
    record = {'mode': mode, 'exit_code': code, 'timed_out': timed_out,
              'baseline_present': 'BASELINE:' in text,
              'real_budget_eviction_logged': 'A_evicted_by_real_budget=true' in text,
              'atlas_none_panic': 'metal_atlas.rs:233' in text and 'None' in text}
    path = out / 'result.json'
    if path.exists():
        record['measurement'] = json.loads(path.read_text())
    records.append(record)
    print(json.dumps(record, indent=2), flush=True)
(results / 'summary.json').write_text(json.dumps(records, indent=2))
# A fixed implementation should pass every regression case. The incident
# release passes the control but aborts/fails the other three cases.
raise SystemExit(1 if any(r['exit_code'] != 0 or r['timed_out'] for r in records) else 0)
