import Std

/-!
Desktop telemetry policy kernel with shared vectors for the production Zig policy.

These are bounds on an explicitly modeled foreground effect plan, not a proof of
zero CPU overhead, wall-clock latency, OS scheduling, or the correctness of an
FFI/thread implementation. The production caller must refine this policy: all
serialization, networking and allocation belong to the worker, thread creation
to startup, and joining to teardown. A slow/failed worker may lose samples; it
must never turn the single-slot, drop-on-busy publish into a foreground wait.
The finite flag abstracts the production floating-point validity check. Natural
numbers model non-wrapping timestamps and counts, not machine-word arithmetic.
-/
namespace Nano.Telemetry

def bucketBounds : Nat := 22
def histogramCells : Nat := 5 * 4 * 3 * 4
def counterSlots : Nat := histogramCells * (bucketBounds + 1)
/-- One active window and one queued/in-flight snapshot; no growing queue. -/
def bufferedCounterSlots : Nat := 2 * counterSlots
def capacity : Nat := 1000000
def minIntervalMs : Nat := 600000

def record (enabled active finite : Bool) : Bool :=
  enabled && active && finite

def metricUpdates (enabled active finite cadenceValid : Bool) : Nat :=
  if record enabled active finite then 4 + (if cadenceValid then 1 else 0) else 0

/-- Worst-case linear bucket search, per sample; independent of prior samples. -/
def bucketComparisons (enabled active finite cadenceValid : Bool) : Nat :=
  metricUpdates enabled active finite cadenceValid * bucketBounds

def due (enabled active hasSamples workerIdle : Bool) (now lastAttempt : Nat) : Bool :=
  enabled && active && hasSamples && workerIdle &&
    decide (now >= lastAttempt && now - lastAttempt >= minIntervalMs)

/-- Recording clamps even an out-of-range count; valid samples add at most one. -/
def sampleCount (count : Nat) (enabled active finite : Bool) : Nat :=
  if record enabled active finite then min (count + 1) capacity else count

theorem disabled_no_record (active finite : Bool) : record false active finite = false := by
  simp [record]

theorem background_no_record (enabled finite : Bool) : record enabled false finite = false := by
  simp [record]

theorem invalid_no_record (enabled active : Bool) : record enabled active false = false := by
  simp [record]

theorem disabled_no_handoff (active samples idle : Bool) (now last : Nat) :
    due false active samples idle now last = false := by simp [due]

theorem background_no_handoff (enabled samples idle : Bool) (now last : Nat) :
    due enabled false samples idle now last = false := by simp [due]

theorem metric_updates_bounded (enabled active finite cadence : Bool) :
    metricUpdates enabled active finite cadence <= 5 := by
  cases enabled <;> cases active <;> cases finite <;> cases cadence <;>
    decide

theorem bucket_comparisons_bounded (enabled active finite cadence : Bool) :
    bucketComparisons enabled active finite cadence <= 110 := by
  have h := metric_updates_bounded enabled active finite cadence
  unfold bucketComparisons bucketBounds
  omega

/-- Arbitrary warmed history does not appear in either operation-count formula. -/
def costWithHistory (_historySize : Nat) (enabled active finite cadence : Bool) : Nat :=
  bucketComparisons enabled active finite cadence

theorem cost_independent_of_history (historyA historyB : Nat)
    (enabled active finite cadence : Bool) :
    costWithHistory historyA enabled active finite cadence =
      costWithHistory historyB enabled active finite cadence := by rfl

theorem fixed_histogram_cells : histogramCells = 240 := by decide
theorem fixed_counter_slots : counterSlots = 5520 := by decide
theorem fixed_buffered_counter_slots : bufferedCounterSlots = 11040 := by decide

theorem sample_count_saturates (count : Nat) (enabled active finite : Bool)
    (h : count <= capacity) : sampleCount count enabled active finite <= capacity := by
  unfold sampleCount
  split
  · exact Nat.min_le_right _ _
  · exact h

theorem invalid_sample_preserves_count (count : Nat) (enabled active : Bool) :
    sampleCount count enabled active false = count := by simp [sampleCount, record]

theorem sample_count_step_bounded (count : Nat) (enabled active finite : Bool) :
    sampleCount count enabled active finite <= count + 1 := by
  unfold sampleCount
  split
  · exact Nat.min_le_left _ _
  · omega

theorem saturated_count_stays_saturated (enabled active finite : Bool) :
    sampleCount capacity enabled active finite = capacity := by
  unfold sampleCount
  split <;> simp

/-- The invariant survives an arbitrary-length sequence, not just a finite cube. -/
def sampleSequence : Nat → List Bool → Nat
  | count, [] => count
  | count, finite :: rest => sampleSequence (sampleCount count true true finite) rest

theorem sample_sequence_bounded (samples : List Bool) (count : Nat)
    (h : count <= capacity) : sampleSequence count samples <= capacity := by
  induction samples generalizing count with
  | nil => exact h
  | cons finite rest ih =>
    exact ih _ (sample_count_saturates count true true finite h)

theorem due_implies_elapsed (enabled active samples idle : Bool) (now last : Nat)
    (h : due enabled active samples idle now last = true) :
    last <= now ∧ minIntervalMs <= now - last := by
  simp only [due, Bool.and_eq_true, decide_eq_true_eq] at h
  exact h.2

theorem rollback_not_due (enabled active samples idle : Bool) (now last : Nat)
    (h : now < last) : due enabled active samples idle now last = false := by
  simp [due, show ¬now >= last by omega]

structure WorkerState where
  busy : Bool
  lastAttempt : Nat
  deriving DecidableEq, Repr

/-- Only a successful nonblocking single-slot publish advances the attempt time. -/
def tryHandoff (s : WorkerState) (enabled active samples : Bool) (now : Nat) :
    WorkerState × Bool :=
  if due enabled active samples (!s.busy) now s.lastAttempt then
    ({ busy := true, lastAttempt := now }, true)
  else (s, false)

/-- Success and failure have the same foreground-visible completion transition. -/
def complete (s : WorkerState) (_workerSucceeded : Bool) : WorkerState :=
  { s with busy := false }

theorem successful_handoff_sets_busy_and_time (s : WorkerState)
    (enabled active samples : Bool) (now : Nat)
    (h : (tryHandoff s enabled active samples now).2 = true) :
    (tryHandoff s enabled active samples now).1 = { busy := true, lastAttempt := now } := by
  unfold tryHandoff at *
  split at * <;> simp_all

theorem busy_drops_handoff (last now : Nat) (enabled active samples : Bool) :
    tryHandoff { busy := true, lastAttempt := last } enabled active samples now =
      ({ busy := true, lastAttempt := last }, false) := by
  simp [tryHandoff, due]

theorem completion_only_clears_busy (s : WorkerState) (succeeded : Bool) :
    (complete s succeeded).busy = false ∧
    (complete s succeeded).lastAttempt = s.lastAttempt := by simp [complete]

theorem worker_failure_does_not_change_policy (s : WorkerState) :
    complete s false = complete s true := by rfl

/-- Slot occupancy, including before any worker completion, is at most one. -/
def inFlight (s : WorkerState) : Nat := if s.busy then 1 else 0

theorem at_most_one_in_flight (s : WorkerState) : inFlight s <= 1 := by
  unfold inFlight
  split <;> omega

theorem no_second_handoff_before_completion (s : WorkerState)
    (enabled active samples enabled' active' samples' : Bool) (now later : Nat)
    (h : (tryHandoff s enabled active samples now).2 = true) :
    (tryHandoff (tryHandoff s enabled active samples now).1
      enabled' active' samples' later).2 = false := by
  rw [successful_handoff_sets_busy_and_time s enabled active samples now h]
  simp [busy_drops_handoff]

/-- Consecutive successful publishes, after either kind of completion, are spaced
by at least ten minutes. The completion time itself need not be bounded. -/
theorem repeated_handoffs_spaced (s : WorkerState)
    (enabled active samples enabled' active' samples' succeeded : Bool) (first second : Nat)
    (hfirst : (tryHandoff s enabled active samples first).2 = true)
    (hsecond : (tryHandoff (complete (tryHandoff s enabled active samples first).1 succeeded)
      enabled' active' samples' second).2 = true) :
    first <= second ∧ 600000 <= second - first := by
  rw [successful_handoff_sets_busy_and_time s enabled active samples first hfirst] at hsecond
  have hdue : due enabled' active' samples' true second first = true := by
    unfold tryHandoff at hsecond
    split at hsecond
    · simpa [complete] using ‹due enabled' active' samples'
        (!(complete { busy := true, lastAttempt := first } succeeded).busy)
        second (complete { busy := true, lastAttempt := first } succeeded).lastAttempt = true›
    · simp at hsecond
  exact due_implies_elapsed enabled' active' samples' true second first hdue

inductive Effect where
  | histogramAdd | publishSlot
  | serialize | network | allocate | threadSpawn | threadJoin | wait | timerWakeUI
  deriving DecidableEq, Repr

/-- Precisely the effects permitted in the foreground policy; other effects are
listed explicitly so the exclusion theorem is not a claim about their runtime cost. -/
def hotPathPlan (s : WorkerState) (enabled active finite cadence samples : Bool)
    (now : Nat) : List Effect :=
  List.replicate (metricUpdates enabled active finite cadence) .histogramAdd ++
    (if due enabled active samples (!s.busy) now s.lastAttempt then [.publishSlot] else [])

def forbiddenOnUI : Effect → Bool
  | .histogramAdd | .publishSlot => false
  | .serialize | .network | .allocate | .threadSpawn | .threadJoin | .wait | .timerWakeUI => true

theorem hot_path_only_bounded_adds_or_publish (s : WorkerState)
    (enabled active finite cadence samples : Bool) (now : Nat) (effect : Effect)
    (h : effect ∈ hotPathPlan s enabled active finite cadence samples now) :
    effect = .histogramAdd ∨ effect = .publishSlot := by
  simp only [hotPathPlan, List.mem_append, List.mem_replicate] at h
  rcases h with h | h
  · exact Or.inl h.2
  · split at h <;> simp_all

theorem no_ui_effects_in_plan (s : WorkerState)
    (enabled active finite cadence samples : Bool) (now : Nat) (effect : Effect)
    (h : effect ∈ hotPathPlan s enabled active finite cadence samples now) :
    forbiddenOnUI effect = false := by
  rcases hot_path_only_bounded_adds_or_publish s enabled active finite cadence samples now effect h
    with h | h <;> subst effect <;> rfl

theorem hot_path_plan_length_bounded (s : WorkerState)
    (enabled active finite cadence samples : Bool) (now : Nat) :
    (hotPathPlan s enabled active finite cadence samples now).length <= 6 := by
  have h := metric_updates_bounded enabled active finite cadence
  unfold hotPathPlan
  split <;> simp_all <;> omega

theorem hot_path_publish_count_bounded (s : WorkerState)
    (enabled active finite cadence samples : Bool) (now : Nat) :
    (hotPathPlan s enabled active finite cadence samples now).count .publishSlot <= 1 := by
  have hc : (List.replicate (metricUpdates enabled active finite cadence)
      Effect.histogramAdd).count .publishSlot = 0 :=
    List.count_eq_zero_of_not_mem (by simp)
  unfold hotPathPlan
  split <;> simp [hc]

theorem busy_plan_drops_publish (last now : Nat)
    (enabled active finite cadence samples : Bool) :
    hotPathPlan { busy := true, lastAttempt := last } enabled active finite cadence samples now =
      List.replicate (metricUpdates enabled active finite cadence) .histogramAdd := by
  simp [hotPathPlan, due]

theorem disabled_plan_empty (s : WorkerState) (active finite cadence samples : Bool) (now : Nat) :
    hotPathPlan s false active finite cadence samples now = [] := by
  simp [hotPathPlan, metricUpdates, record, due]

theorem background_plan_empty (s : WorkerState) (enabled finite cadence samples : Bool) (now : Nat) :
    hotPathPlan s enabled false finite cadence samples now = [] := by
  simp [hotPathPlan, metricUpdates, record, due]

/- Shared executable CSV vectors. No header; booleans are decimal 0/1.
Columns: enabled,active,finite,cadence,hasSamples,idle,now,lastAttempt,
         expectedRecord,expectedUpdates,expectedDue.
All 64 boolean combinations occur at every time pair, including rollback and
one millisecond below/exactly at the next interval after a nonzero attempt. -/
def bools : List Bool := [false, true]
def boundaryTimes : List Nat := [0, 599999, 600000, 600001, 1200000]
def vectorTimes : List (Nat × Nat) :=
  boundaryTimes.map (fun now => (now, 0)) ++
    [(0, 600001), (599999, 600001), (600000, 600001),
     (600001, 600001), (1200000, 600001), (1200001, 600001)]

def boolDigit (b : Bool) : String := if b then "1" else "0"

def vectorLine (enabled active finite cadence samples idle : Bool) (now last : Nat) : String :=
  String.intercalate ","
    [boolDigit enabled, boolDigit active, boolDigit finite, boolDigit cadence,
     boolDigit samples, boolDigit idle, toString now, toString last,
     boolDigit (record enabled active finite),
     toString (metricUpdates enabled active finite cadence),
     boolDigit (due enabled active samples idle now last)]

def vectorLines : List String :=
  bools.flatMap fun enabled =>
  bools.flatMap fun active =>
  bools.flatMap fun finite =>
  bools.flatMap fun cadence =>
  bools.flatMap fun samples =>
  bools.flatMap fun idle =>
  vectorTimes.map fun (now, last) =>
    vectorLine enabled active finite cadence samples idle now last

theorem conformance_vector_count : vectorLines.length = 704 := by native_decide

end Nano.Telemetry
