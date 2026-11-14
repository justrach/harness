import Nano.Telemetry

/-- Executable witnesses used by Zig and the proof drift gate. No identifiers,
network, machine timings or user data; deterministic policy inputs only. -/
def main : IO Unit := do
  for line in Nano.Telemetry.vectorLines do
    IO.println line
