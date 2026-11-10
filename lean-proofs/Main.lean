import HarnessProofs.Chat2Sync
import HarnessProofs.RegistryLWW
import HarnessProofs.C2AtomicStore
import HarnessProofs.EngineMemoryAndParity
import HarnessProofs.RustCodebaseParity

open HarnessProofs

def main : IO Unit := do
  IO.println "harness-zig lean-proofs verified report"
  IO.println s!"chat2_catchup_cells    {Chat2Sync.catchUpCellCount}"
  IO.println s!"registry_lww_triples   {RegistryLWW.lwwTriplesCount}  comm={RegistryLWW.lwwPairsCommutative}  assoc={RegistryLWW.lwwTriplesAssociative}"
  IO.println s!"c2_atomic_init         {C2AtomicStore.c2Invariant {}}"
  IO.println s!"engine_rpc_methods     {EngineMemoryAndParity.totalEngineRpcMethods}  o1_probes=1  kernel_cells={EngineMemoryAndParity.verifiedKernelCells}"
  IO.println s!"rust_parity_cells      {RustCodebaseParity.rustParityVerifiedCells}  e2e_login_sync={(RustCodebaseParity.runFullLoginAndSync).isSome}"
