# Unified Context Compaction Implementation Plan

Status: plan only. Nothing in this document has been executed.

Scope: this is a validation and design document produced after reading the
current compaction code paths in this fork. It is written against what exists
here, not against upstream fx or any other agent implementation.

---

## 1. Direct answer: would this improve our compaction?

Short answer: **partly, but not for the reason the request assumes.**

I read every compaction path before writing this. The most important finding
contradicts the premise of the request, so it comes first.

### 1.1 The three flows already share one front door

The request says manual compaction, automatic compaction, and overflow recovery
"must all call into this implementation rather than maintaining separate
compaction logic," which implies the three flows have separate implementations
today. They do not.

`compactContextTransaction` in `src/core/agent/runtime/orchestrator.zig:6289` is
the single compaction transaction for all three flows. It has exactly two call
sites in the entire tree:

| Flow | Call site | How it reaches the transaction |
| --- | --- | --- |
| Manual `/compact` | `src/core/app/app_agent_runtime.zig:971` | `processContextCompaction` worker task, `.trigger = .manual` |
| Automatic | `src/core/agent/runtime/orchestrator.zig:7579` | `.trigger = .automatic` |
| Context-overflow recovery | `src/core/agent/runtime/orchestrator.zig:7579` | `.trigger = .manual`, `.activity_origin = .provider_overflow` |

Automatic and overflow recovery are the *same call site*, selected by a state
variable:

```zig
const compaction_trigger: runtime_prompt_context.CompactionTrigger =
    if (context_overflow_recovery == .pending) .manual else .automatic;
```

`context_overflow_recovery` is set to `.pending` when a provider returns a
context-overflow failure (`orchestrator.zig:8337`, gated by
`shouldRecoverContextOverflow` at line 4287), then consumed at 7641. So overflow
recovery re-enters the identical transaction with a forced trigger.

There is no third implementation, and no duplicated summary construction.
There is no second overflow-compaction path either. Requirement 1 as written is
already satisfied by the current architecture.

### 1.2 What is actually duplicated

Real duplication exists, but it sits in the window-preparation and commit
plumbing, not in the compactor itself:

- `src/core/app/app_agent_runtime.zig:947-1004` (manual)
- `src/core/agent/runtime/orchestrator.zig:7487-7653` (automatic and overflow)

Both blocks independently compute `retention_target`, run the
`prepareRetainedCompactionWindow` + `refine_budget` retry loop, resolve
`result_storage`, walk history to compute `compaction_count`, build the
continuation projection, and assemble the post-compaction history array. This is
the seam worth extracting, and it is genuinely worth extracting.

### 1.3 Requirement-by-requirement verdict

| # | Requirement | Current state | Verdict |
| --- | --- | --- | --- |
| 1 | Unified compactor, one front door | `compactContextTransaction` already serves all three flows | **Already met.** Refactor target is window/commit plumbing, not the compactor |
| 2 | Preserve user messages exactly | Already exact. `compaction_policy.prepare:183-186` stores verbatim bytes; only the model-visible copy is prefixed | **Already met.** Needs tests, not code |
| 3 | Preserve newest assistant replies exactly | Already exact. `selectRecentContext` retains newest turns verbatim and appends them after the handoff | **Already met.** Needs tests, not code |
| 4 | Persist every compacted turn and tool call as `M1`/`T1` | Originals *are* persisted (SHA-256-addressed artifacts), but under different labels: `User {n}`, `Source archive {n}`, `compaction-source-<sha256>`. No `M*`/`T*` identifiers exist anywhere | **Real gap** |
| 5 | `read_tool_result` resolves `T*` | `read_tool_result` only resolves real handles. Nothing resolves `M*`/`T*` | **Real gap** |
| 6 | Summary via conversation model at lowest reasoning, one cross-family fallback | Uses conversation model. **No reasoning-level selection and no cross-family fallback.** Retry loop reuses the same model and only retries empty output | **Real gap** |
| 7 | `auto_compact_percent`, 10-80, default 80, `FX_AUTO_COMPACT_PERCENT` | Hardcoded `4/5` at `prompt_context.zig:13-14`. No config key, no env var | **Real gap.** Note: default 80% already matches today's behavior |
| 8 | Old checkpoints still load | `session_codec.parseHistoryTurn:610-661` already has a 4-shape compatibility ladder for `compacted_summary`; `checkpoint.zig` delegates to it | **Largely met.** Must extend the ladder, not build a migrator |
| 9 | Architectural boundary + CI check | No boundary enforcement exists. `scripts/check-public-surface.sh` checks for leaked personal paths only, unrelated to imports | **Real gap** |

So 4 of 9 requirements are already satisfied, 4 are genuine gaps, and 1 is
mostly satisfied.

### 1.4 Expected real-world improvement

Honest assessment of what shipping this changes for a user:

- **`auto_compact_percent`** (real, useful). Today the threshold is a compiled-in
  `4/5`. Users on long-context models who want earlier compaction, or users on
  small models who want later compaction, cannot express that. This is the
  single most user-visible win.
- **`M*`/`T*` identifiers** (real, useful). Today an agent recovering a compacted
  tool result must copy a 64-hex-character SHA handle verbatim. `T7` is shorter,
  stable within a compaction, and easier to reference. Worthwhile, and it is the
  change that most improves post-compaction recoverability.
- **Cross-family summary fallback** (real, useful). Today a summarization failure
  on the conversation model aborts compaction entirely. One retry on another
  family converts a hard failure into a success in most cases.
- **Lowest reasoning level for summaries** (marginal, and slightly risky).
  Summaries are mechanical extraction, so low effort is appropriate. See the
  caveat in section 5.2. "lowest" is not well defined in this codebase today.
- **Window-plumbing extraction** (no user-visible change, real maintenance win).
- **Boundary CI check** (no user-visible change, prevents future regression).

The request's framing, "future compaction behavior can be changed in one place,"
is already roughly true today. The refactor that buys that property more
completely is the window/commit extraction, which the request does not
prioritize.

### 1.5 Recommendation

**Proceed, but re-scope.** I recommend a three-phase change rather than the full
nine-requirement program:

- **Phase A (highest value, lowest risk):** `auto_compact_percent` with config
  and env override. Requirement 7. Small, self-contained, clearly useful.
- **Phase B:** `M*`/`T*` identifiers plus `read_tool_result` resolution.
  Requirements 4 and 5, which are one feature and should land together.
- **Phase C:** summary model selection with lowest-reasoning and one
  cross-family fallback. Requirement 6. Requires answering the
  ordering question in section 5.2 first.

Requirements 1, 2, 3, 8, and 9 are, respectively, already met, already met,
already met, mostly met, and worth a small standalone CI addition. I would add
tests for 2 and 3 to lock in current behavior rather than rewrite it.

If the full scope is wanted anyway, the plan below implements all nine. It is
written to be executed as specified. I am flagging the premise mismatch because
building a "unified compactor" from scratch over working code would replace
well-tested behavior for no functional gain.

---

## 2. Current architecture map

### 2.1 Module layout

```
src/core/agent/runtime/
  context_compaction.zig          compaction engine: planning, chunking, summary calls
  context_compaction_state.zig    semantic projection, handoff rendering, handle resolution
  compaction_policy.zig           assistant-first policy: user retention, artifact persistence
  prompt_context.zig              trigger planning, usable-input math, recent-context selection
  orchestrator.zig                compactContextTransaction (the front door), in-turn auto/overflow
  checkpoint.zig                  FXCP v1 encode/decode
src/core/session/
  result_store.zig                content-addressed artifact store, read/range/search
  session_codec.zig               history turn JSON, compat ladder
  session_compaction.zig          unrelated: session log rewrite (diff-snapshot spill)
src/tools/session/read_tool_result.zig   the read_tool_result tool
```

Note `src/core/session/session_compaction.zig` is **not** context compaction. It
rewrites the session event log to move inline diff snapshots into the result
store. Its name is a collision hazard; do not confuse the two.

### 2.2 The transaction, step by step

`compactContextTransaction` (`orchestrator.zig:6289`):

1. Emits activity stages via `deps.compaction_activity` (`.preparation`,
   `.summary`, `.validation`, `.publication`).
2. Builds `CompactionPlanInput` and calls `planCompaction` twice: once to decide
   no-op vs compact, once with `protected_tokens` measured to size the handoff
   budget. Returns `null` on no-op, `error.ContextCapacityExceeded` when no
   handoff budget exists.
3. Checks `model_provider.authorizesCredential`.
4. Calls `promoteMessageResults` to give every in-flight tool result a durable
   handle before compaction.
5. Calls `context_compaction.compact`, which either uses `compaction_policy`
   (`assistant_first`) or the legacy `projectSemanticMessages` path. The policy
   is chosen by storage availability: `.assistant_first` when a result store
   exists, `.legacy` when it does not.
6. Validates the produced handoff against `accepted_tokens`.
7. Calls `commitContextCompaction` to persist.

### 2.3 Where each requirement currently lives

Threshold math lives in `prompt_context.zig:47-99`:

```zig
const compaction_high_water_numerator: usize = 4;
const compaction_ratio_denominator: usize = 5;
// ...
const high_water = tokens * 4 / 5;      // 80% of usable input
```

`planCompaction` also computes `session_target` (`/10`), `soft_ceiling` (`/4`),
and `accepted_handoff_tokens`. Only the high-water ratio needs to become
configurable. The other ratios stay compiled-in.

Usable input vs raw context window, in `prompt_context.zig:438-446`:

```zig
pub fn usableInputTokens(capabilities: model_capabilities.Capabilities) ?usize {
    const context_window = capabilities.context_window orelse return null;
    const context_tokens: usize = @intCast(context_window);
    // Reserve exactly what the request asks for; that limit is always below the window.
    const output_tokens: usize = model_capabilities.requestOutputTokens(capabilities)
        orelse return context_tokens;
    return context_tokens - output_tokens;
}
```

This distinction the request warns about already exists and is already correct.
`auto_compact_percent` must multiply **this** value, never `context_window`.
When `usableInputTokens` returns `null` (unknown window), `planCompaction` sets
`high_water = null` and automatic compaction never triggers. That fail-quiet
behavior must be preserved.

User message preservation, in `compaction_policy.zig:183-186`:

```zig
if (message.role == .user and message.context_origin == .user_turn) {
    const text = message.content orelse "";
    try append_user(alloc, &users, &messages, text);        // verbatim
    try original.writer.print("### Original user\n{s}\n", .{text}); // verbatim archive
}
```

Only the summarizer's input copy is annotated, at line 235:

```zig
message.content = try std.fmt.allocPrint(alloc, "{s}\n{s}", .{
    if (user_index < cut) "USER_TO_SUMMARIZE: ..." else "USER_RETAINED: ...",
    message.content orelse "",
});
```

`Stored.users` persists the unprefixed text, so `load_state` restores exact
bytes. Requirement 2 is structurally satisfied. The risk in any rewrite is
introducing a prefix into the persisted copy; the new tests must assert on the
persisted form.

Newest reply preservation: `prompt_context.selectRecentContext` (line 112)
walks history newest-first, measuring complete execution steps and never
shortening a step. `prepareRetainedCompactionWindow`
(`orchestrator.zig:6073`) splits history into `source` (summarized) and
`retained_messages` (kept verbatim). Retained messages are appended after the
handoff in `app_agent_runtime.zig:952-955` and equivalent sites. Requirement 3 is
satisfied by construction.

Artifact persistence: `compaction_policy.store_artifact` (line 61):

```zig
const id = try std.fmt.allocPrint(alloc, "compaction-{s}-{s}", .{ name, digest });
```

with `name` in `{ "arguments", "source", "state", "source-index" }`. Tool results
keep their original `result-*` handle via `receipt` (line 128). Labels are
`User {n}` (line 149) and `Source archive {n}` (line 151). This is where `M*` and
`T*` must be introduced.

read_tool_result lives in `src/tools/session/read_tool_result.zig`. `decode`
parses `handle` plus `start_byte`/`byte_count` or `query`. `validate`
(`classifyHandleNormalization`) appends `.txt` to bare `result-*` handles.
`readOutput` routes to `result_store` (managed), `command_replay_store`
(managed, on `ResultHandleNotFound`), or `result_store` (legacy dir). There is no
alias layer, which is exactly where `T*`/`M*` resolution belongs.

Checkpoint compatibility: `checkpoint.zig` is `FXCP` magic, `version: u16
= 1`, SHA-256 payload digest, delegating history parsing to
`session_codec.parseHistoryTurn`. `session_codec.zig:610-661` accepts four
`compacted_summary` shapes and infers completeness flags when absent:

```zig
.root_user_messages_complete = if (has_completeness)
    try requireBool(object, "root_user_messages_complete")
else
    has_root_user_messages or removed_turn_count == 0,
```

Any new persisted field must be added as another rung on this ladder. Because
`exactObject` rejects unknown keys, a naive field addition **breaks loading of
every existing checkpoint**. This is the main compatibility hazard in the plan.

Reasoning levels: `types.ReasoningEffort` (`types.zig:2364`) is
`auto | named(64-byte name)`. `model_capabilities.reasoningEfforts` is a
`ReasoningEffortOptions` holding up to 16 values in Gateway declaration order.
Helpers: `reasoningEffortAtIndex` (0 means `.auto`), `reasoningEffortIndex`,
`reasoningEffortSupported`, `reasoningEffortOptionCount`,
`resolveProviderOptionsForCapabilities` (line 187).

Model fallback: there is no cross-family model fallback abstraction
anywhere. `provider_set.zig:30` has `fallback_model_capabilities_fn`, but that
only supplies capability defaults for unknown models; it does not select an
alternative model. This must be built.

### 2.4 Test and CI infrastructure

- Unit tests: `test` blocks in the source file under test, aggregated through
  `agent_runtime.zig:48-58` (`test { _ = @import(...) }`). `zig build test` runs
  the root test artifact.
- E2E: Bun, `tests/e2e/`. `compaction-policy.test.ts` already covers automatic
  compaction preserving user text and originals, using a fake Gateway
  (`startDynamicFakeGateway`). `tui-compaction-activity.test.ts` covers manual
  compaction activity.
- PGSO corpus: every `tests/e2e/*.test.ts` needs a classification entry in
  `scripts/pgso/corpus.json`. Existing: `verify-compaction-policy` (verification),
  `e2e-session-recovery` (training), `verify-tui-compaction-activity`.
- CI: `full-ci.yml` runs `zig fmt --check src/` (line 48) and
  `./scripts/check-public-surface.sh` (line 51) in ReleaseSafe jobs. This is the
  insertion point for a boundary check.
- `AGENTS.md` requires: build, focused tests, Full CI on all four runners, and
  driving the built binary before declaring work ready.

---

## 3. Target architecture

```
src/core/compactor/                  <- new package, sole owner of compaction
  compactor.zig                      public interface (the only importable surface)
  threshold.zig                      auto_compact_percent resolution and validation
  identifiers.zig                    M*/T* allocation, parsing, alias index
  summary_model.zig                  lowest-reasoning selection, cross-family fallback
  state.zig                          internal semantic projection (moved from context_compaction_state)
  policy.zig                         internal retention policy (moved from compaction_policy)
  engine.zig                         internal chunking and summary calls (moved from context_compaction)
  compat.zig                         legacy marker reading and migration

src/core/agent/runtime/orchestrator.zig
  - compactContextTransaction becomes a thin adapter over compactor.compact()
src/core/app/app_agent_runtime.zig
  - window/commit plumbing moves into compactor.prepareWindow()
```

### 3.1 Public interface

Kept deliberately small, per the request:

```zig
// src/core/compactor/compactor.zig
const compactor = @import("compactor.zig");

pub const Trigger = enum { manual, automatic, provider_overflow };
pub const Storage = compaction_policy.Storage;   // unavailable | legacy_dir | managed
pub const Threshold = struct { percent: u8 };

pub const Request = struct {
    trigger: Trigger,
    provider: model_provider.ProviderId,
    working_capabilities: model_capabilities.Capabilities,
    request_tokens: usize,
    source_tokens: usize,
    source_messages: []const types.ChatMessage,
    uncertain_source_message_count: usize = 0,
    continuation: Continuation,
    retained_from: types.ContextHistoryCut,
    newest_exchange_tokens: usize = 0,
    storage: Storage,
    credentials: Credentials,
    cancel_flag: *std.atomic.Value(bool),
    trace_ctx: debug_trace.TraceContext,
    removed_turn_count: usize,
    compaction_count: usize,
    threshold: Threshold,
};

/// The single entry point for all three flows.
pub fn compact(alloc: Allocator, deps: *const Deps, request: Request) !?Result;

/// Resolves M*/T* aliases to durable handles for read_tool_result.
pub fn resolveAlias(storage: Storage, alias: []const u8) !?[]u8;

/// Parses and validates a configured percentage.
pub fn parsePercent(raw: []const u8) ?u8;
```

Everything else stays private: turn selection, chunking, summarization,
persistence, retry, restore, alias indexing. Callers get a `Result` containing
the handoff and a handle to the alias index.

### 3.2 Boundary rule

Outside `src/core/compactor`, these are the only permitted interactions with
compaction:

- `compactor.Request`, `compactor.Result`, `compactor.Trigger`,
  `compactor.Storage`, `compactor.compact`, `compactor.resolveAlias`,
  `compactor.parsePercent`
- reading a persisted alias index artifact through `result_store`

No external module may import the internal `engine.zig`, `policy.zig`,
`state.zig`, `identifiers.zig`, `summary_model.zig`, or `compat.zig`. Section 8
specifies the enforcement check.

---

## 4. Phase A: `auto_compact_percent`

### 4.1 Resolution module

New file `src/core/compactor/threshold.zig`, mirroring the shape of
`src/core/config/agent_steps.zig` which this codebase already uses for
`FX_MAX_AGENT_STEPS`:

```zig
pub const default_percent: u8 = 80;
pub const min_percent: u8 = 10;
pub const max_percent: u8 = 80;

pub fn parsePercent(raw: ?[]const u8) ?u8 {
    const trimmed = std.mem.trim(u8, raw orelse return null, " \t\r\n");
    if (trimmed.len == 0) return null;
    const value = std.fmt.parseUnsigned(u16, trimmed, 10) catch return null;
    if (value < min_percent or value > max_percent) return null;
    return @intCast(value);
}

pub fn resolvePercent(configured: ?u8, process_override: ?[]const u8) u8 {
    return parsePercent(process_override) orelse configured orelse default_percent;
}

pub fn highWaterTokens(usable_input_tokens: usize, percent: u8) usize {
    return usable_input_tokens * percent / 100;
}
```

`parsePercent` returning `null` for out-of-range is the validation the request
asks for. A malformed `FX_AUTO_COMPACT_PERCENT` falls back to the configured
value, matching how `resolveMaxAgentStepsWithOverride` treats `"invalid"`. That
is deliberate. A typo in an env var should not make compaction silently stop
happening. It also means the request's "validate invalid values" is satisfied
without ever entering undefined behavior.

### 4.2 Wiring the threshold

In `prompt_context.zig`, replace:

```zig
const compaction_high_water_numerator: usize = 4;
const compaction_ratio_denominator: usize = 5;
```

with a field on `CompactionPlanInput`:

```zig
pub const CompactionPlanInput = struct {
    trigger: CompactionTrigger,
    capabilities: model_capabilities.Capabilities,
    request_tokens: usize,
    source_tokens: usize,
    protected_tokens: usize = 0,
    newest_exchange_tokens: usize = 0,
    compact_percent: u8 = threshold.default_percent,
};
```

and in `planCompaction`:

```zig
const high_water = if (usable) |tokens|
    threshold.highWaterTokens(tokens, input.compact_percent)
else
    null;
```

Using `@intCast` is unnecessary. `percent` is `u8` bounded to 80, `tokens` is
`usize`, and the multiplication widens correctly. Guard the multiplication if
`usable` can be large enough to overflow. At 80% of a `u32` context window this
cannot overflow `usize` on any supported platform, but a saturating helper is
cheap insurance:

```zig
pub fn highWaterTokens(usable_input_tokens: usize, percent: u8) usize {
    return @min(
        usable_input_tokens / 100 * percent +| (usable_input_tokens % 100) * percent / 100,
        usable_input_tokens,
    );
}
```

### 4.3 Configuration plumbing

Add to `Settings` in `settings_store.zig` (near `effort` and `fast_mode`, around
line 97):

```zig
auto_compact_percent: ?u8 = null,
```

Parsing validation, next to the existing `max_agent_steps` check at line 1818
and the boolean-key block at 1846:

```zig
if (object.get("auto_compact_percent")) |value| {
    if (value != .integer or value.integer < 10 or value.integer > 80) {
        return error.InvalidSettingsFormat;
    }
}
```

Add `"auto_compact_percent"` to the project-config allowlist in
`app_lifecycle.zig` or wherever profile-owned keys are stripped before parsing.
Per `AGENTS.md`, project `.fx.json` accepts only `sandbox`, `max_agent_steps`,
`max_tool_result_bytes`, `context`, `provider_order`, `provider_strict`. Adding
`auto_compact_percent` to that set is a product decision; the conservative
choice is to leave it profile-owned and **not** add it, which avoids changing
the documented commit-defaults surface.

Environment override, mirroring `loadAgentStepLimit` (`app_lifecycle.zig:1440`):

```zig
fn loadAutoCompactPercent(configured: ?u8) u8 {
    return threshold.resolvePercent(configured, io_mod.getenv("FX_AUTO_COMPACT_PERCENT"));
}
```

Config precedence per `AGENTS.md`: env → profile workspace → profile global →
project → built-in. `resolvePercent` implements env over configured, and the
call site supplies `configured` already resolved through the normal precedence
chain.

Pass the resolved value into `CompactionPlanInput` at both call sites:
`orchestrator.zig:7445` (automatic/overflow) and `app_agent_runtime.zig` via
`compactContextTransaction`. It must reach `compactContextTransaction` as a
request field so the transaction does not re-read globals.

Surface it in `/doctor` alongside `FX_MAX_AGENT_STEPS`
(`doctor_runtime.zig:524`) so the effective value is observable.

### 4.4 Tests for Phase A

`src/core/compactor/threshold.zig`:

```zig
test "auto_compact_percent defaults to 80" {
    try std.testing.expectEqual(@as(u8, 80), resolvePercent(null, null));
}

test "auto_compact_percent accepts the full valid range" {
    for (10..80) |value| {
        const raw = try std.fmt.allocPrint(std.testing.allocator, "{d}", .{value});
        defer std.testing.allocator.free(raw);
        try std.testing.expectEqual(@as(?u8, @intCast(value)), parsePercent(raw));
    }
}

test "auto_compact_percent rejects out of range and malformed values" {
    try std.testing.expect(parsePercent("9") == null);
    try std.testing.expect(parsePercent("81") == null);
    try std.testing.expect(parsePercent("0") == null);
    try std.testing.expect(parsePercent("-1") == null);
    try std.testing.expect(parsePercent("abc") == null);
    try std.testing.expect(parsePercent("") == null);
    try std.testing.expect(parsePercent("  ") == null);
    try std.testing.expect(parsePercent("80.5") == null);
}

test "FX_AUTO_COMPACT_PERCENT overrides configuration" {
    try std.testing.expectEqual(@as(u8, 25), resolvePercent(80, "25"));
    try std.testing.expectEqual(@as(u8, 80), resolvePercent(80, "95"));   // invalid override ignored
    try std.testing.expectEqual(@as(u8, 80), resolvePercent(80, "junk"));
    try std.testing.expectEqual(@as(u8, 60), resolvePercent(null, "60"));
}
```

`prompt_context.zig`, extending the existing threshold test near line 908:

```zig
test "automatic compaction triggers at the configured percentage" {
    const capabilities = model_capabilities.Capabilities{ .context_window = 100_000 };
    // usable = 100_000 - 8_192 = 91_808; 80% = 73_446
    const at_threshold = planCompaction(.{
        .trigger = .automatic,
        .capabilities = capabilities,
        .request_tokens = 73_446,
        .source_tokens = 73_446,
        .compact_percent = 80,
    });
    try std.testing.expectEqual(CompactionDecision.compact, at_threshold.decision);

    const below = planCompaction(.{
        .trigger = .automatic,
        .capabilities = capabilities,
        .request_tokens = 73_445,
        .source_tokens = 73_445,
        .compact_percent = 80,
    });
    try std.testing.expectEqual(CompactionDecision.no_op, below.decision);
}

test "a lower percent triggers compaction earlier without using the raw window" {
    const capabilities = model_capabilities.Capabilities{ .context_window = 100_000 };
    const plan = planCompaction(.{
        .trigger = .automatic,
        .capabilities = capabilities,
        .request_tokens = 40_000,
        .source_tokens = 40_000,
        .compact_percent = 40,
    });
    try std.testing.expectEqual(CompactionDecision.compact, plan.decision);
    // Usable input, not context_window: 40% of 91_808, never 40% of 100_000.
    try std.testing.expectEqual(@as(?usize, 36_723), plan.high_water_tokens);
}

test "an unknown context window never triggers automatic compaction" {
    const plan = planCompaction(.{
        .trigger = .automatic,
        .capabilities = .{},
        .request_tokens = std.math.maxInt(usize) / 2,
        .source_tokens = 1024,
        .compact_percent = 80,
    });
    try std.testing.expectEqual(CompactionDecision.no_op, plan.decision);
}
```

Settings parsing test in `settings_store.zig`, following the existing
`max_agent_steps` validation test.

---

## 5. Phase C: summary model selection and fallback

### 5.1 Lowest reasoning level

The compactor already receives `provider_options:
model_capabilities.ResolvedProviderOptions` (`context_compaction.zig:45`) and
forwards it to `streamModelCompletion` at line 415. Summary calls therefore
already carry whatever reasoning the conversation was configured with.

Selecting the lowest supported level is a new decision. Two candidate policies:

**Policy 1, first declared option.** `reasoning_efforts.values[0]`. The array
is in Gateway declaration order and providers conventionally order
low-to-high. Simple and deterministic.

**Policy 2, `.auto` (index 0).** Do not pin a level; let the provider choose.

Policy 1 is what the request asks for. Implement:

```zig
pub fn lowestReasoning(capabilities: model_capabilities.Capabilities) types.ReasoningEffort {
    if (capabilities.reasoning_efforts.len == 0) return .auto;
    return capabilities.reasoning_efforts.values[0];
}
```

### 5.2 Caveat: "lowest" is not well defined today

`ReasoningEffortOptions` has **no ordering contract**. `values` is raw Gateway
declaration order and `Name` is an opaque string. Nothing in this codebase
asserts that index 0 is the cheapest level. For Anthropic the catalog order
happens to be ascending, but that is provider convention, not an invariant fx
enforces.

This matters because the request states the fallback must be deterministic and
testable. A hidden dependency on provider declaration order makes the resulting
behavior provider-dependent. I will implement Policy 1, because it is the
literal request and is deterministic *given* a capability set, but I will:

- document the assumption in the function's doc comment,
- add a test asserting index-0 selection for a known ordering,
- flag this in the final summary as a known assumption rather than a guarantee.

If a hard guarantee is wanted later, the clean fix is adding an explicit `order`
field to `ReasoningEffortOptions` populated from provider metadata, which is a
larger change than this task warrants.

`resolveProviderOptionsForCapabilities` already fails closed. An effort the
model does not declare is dropped rather than sent. So the worst case is that
the low-effort pin is silently ignored, which is acceptable.

### 5.3 Cross-family fallback

No fallback abstraction exists, so this must be built. Design:

```zig
pub const FallbackAttempt = struct {
    model: []const u8,
    provider: model_provider.ProviderId,
    family: Family,
    effort: types.ReasoningEffort,
};

/// Deterministic: same request yields the same ordered attempt list.
pub fn planSummaryAttempts(
    alloc: Allocator,
    primary: FallbackAttempt,
    available: []const FallbackAttempt,   // from the Gateway model catalog
) ![]FallbackAttempt
```

Rules:

1. First attempt is always the conversation's current model at lowest reasoning.
2. If the catalog exposes a model from a **different family** than the primary,
   append exactly one: the first different-family model in catalog order.
3. Never more than two attempts total.
4. If no different-family model exists, the list has one entry and a primary
   failure is terminal.

`Family` is derived from the model ID prefix before `/`
(`openai/...` → `openai`), matching how `capabilitiesForModel` and
`model_provider` already parse IDs. Do not hard-code a provider list.

### 5.4 Integration into runSummaryCall

Current signature takes a single `Request` with `request.model`. Restructure to
take the ordered attempts and loop:

```zig
fn runSummaryCall(alloc: Allocator, request: Request, attempts: []const FallbackAttempt, source_text: []const u8, max_bytes: usize) !SummaryCall {
    var last_err: ?anyerror = null;
    for (attempts, 0..) |attempt, index| {
        const outcome = try runSummaryAttempt(alloc, request, attempt, source_text, max_bytes);
        switch (outcome) {
            .ok => |call| return call,
            .retryable => |err| {
                last_err = err;
                diagnostics.traceCompactionFailure(request.trace_ctx, .summary_transport_failed,
                    "model={s} attempt={d} err={s}", .{ attempt.model, index, @errorName(err) });
                continue;
            },
            // Empty output and non-stop finish reasons are terminal for the
            // attempt and for the whole compaction.
            .fatal => |err| return err,
        }
    }
    return last_err orelse error.InvalidCompactionHandoff;
}
```

Which errors stay retryable:

| Error | Class | Rationale |
| --- | --- | --- |
| `ContextCompactionUnavailable` (transport) | retryable | A different model may succeed |
| `IncompleteCompactionHandoff` (finish reason) | fatal | The model responded; retrying the same transcript will not help |
| `CompactionToolCallRejected` | fatal | Instructions are wrong, not the model |
| `InvalidCompactionHandoff` (empty/UTF-8) | fatal | Retry risks a second invalid handoff |
| `CompactionHandoffTooLarge` (truncated) | fatal | Handled by the existing capacity retry loop above this one |
| `Cancelled` | fatal | Never retry a cancelled operation |
| `error.OutOfMemory` | fatal | Propagate |

Note this replaces the existing two-attempt empty-output retry
(`context_compaction.zig:394-506`). The existing loop retries an empty summary
once with the same model. Under the new model that retry should be the
fallback-model attempt. If the fallback is unavailable and the primary returned
empty, the new code returns `InvalidCompactionHandoff` where the old code
retried once. To preserve today's behavior exactly, keep the empty-output retry
*inside* `runSummaryAttempt` and let `planSummaryAttempts` add the
cross-family attempt on top. That yields up to 4 calls worst case
(primary-empty, primary-empty, fallback-empty, fallback-empty). That is more
than the request's "exactly once" and needs a decision; I recommend capping at
one retry per model, so worst case 2 calls, and accepting the small behavior
change.

### 5.5 Tests for Phase C

```zig
test "summary uses the conversation model at the lowest reasoning level" {
    const efforts = [_]types.ReasoningEffort{
        types.ReasoningEffort.literal("low"),
        types.ReasoningEffort.literal("high"),
    };
    const capabilities = model_capabilities.Capabilities{
        .reasoning_efforts = .fromSlice(&efforts),
    };
    const resolved = model_capabilities.resolveProviderOptionsForCapabilities(
        capabilities, lowestReasoning(capabilities), false,
    );
    try std.testing.expectEqualStrings("low", resolved.reasoning.?.label());
}

test "summary falls back to exactly one model from another family" {
    const available = [_]FallbackAttempt{
        .{ .model = "openai/a", .provider = .openrouter, .family = .openai, .effort = .auto },
        .{ .model = "anthropic/b", .provider = .openrouter, .family = .anthropic, .effort = .auto },
        .{ .model = "anthropic/c", .provider = .openrouter, .family = .anthropic, .effort = .auto },
    };
    const attempts = try planSummaryAttempts(alloc, available[0], &available);
    defer alloc.free(attempts);
    try std.testing.expectEqual(@as(usize, 2), attempts.len);
    try std.testing.expectEqualStrings("openai/a", attempts[0].model);
    try std.testing.expectEqualStrings("anthropic/b", attempts[1].model);
}

test "no cross-family model leaves a single attempt" {
    const available = [_]FallbackAttempt{
        .{ .model = "openai/a", .provider = .openrouter, .family = .openai, .effort = .auto },
        .{ .model = "openai/b", .provider = .openrouter, .family = .openai, .effort = .auto },
    };
    const attempts = try planSummaryAttempts(alloc, available[0], &available);
    defer alloc.free(attempts);
    try std.testing.expectEqual(@as(usize, 1), attempts.len);
}

test "a failing primary summary retries once and never more" {
    var provider: FakeProvider = .{ .fail_all = true };
    ... expect error.ContextCompactionUnavailable
    try std.testing.expectEqual(@as(usize, 2), provider.request_count);
    try std.testing.expectEqualStrings("openai/a", provider.observed_models[0]);
    try std.testing.expectEqualStrings("anthropic/b", provider.observed_models[1]);
}
```

`FakeProvider` (`context_compaction.zig:555`) needs a `fail_all` flag and an
`observed_models: [N][]const u8` array. It already records `observed_model` for
a single call; extending it to a list is a small change.

---

## 6. Phase B: `M*`/`T*` identifiers and `read_tool_result`

### 6.1 Identifier design

`M{n}` for compacted messages/turns, `T{n}` for tool calls and tool results,
numbered from 1 in chronological order within one compaction.

Two constraints from the existing store:

- `result_store.validateHandle` (line 740) requires every byte to be
  alphanumeric, `_`, `-`, or `.`, and caps length at 160. `M1` and `T12` both
  pass.
- Handles are content-addressed via `makeHandle` (line 677):
  `result-{tool}-{call_digest}-{content_digest}.txt`. Aliases must not collide
  with real handles. `M*`/`T*` do not, since real handles always start with
  `result-`, `image-`, `diff-`, or `compaction-`.

An alias is therefore never stored as a real artifact. It resolves through an
index.

### 6.2 Persisted index

Extend the existing `Stored` struct (`compaction_policy.zig:26`) rather than
creating a parallel artifact:

```zig
const Stored = struct {
    version: u8 = 1,
    summary: []const u8,
    users: []const []const u8,
    archives: []const Artifact,

    // Added in format v2. Absent in v1 checkpoints and v1 state artifacts,
    // which stay readable with an empty alias table.
    messages: []const MessageRecord = &.{},
    tools: []const ToolRecord = &.{},

    pub const MessageRecord = struct {
        alias: []const u8,      // "M1"
        kind: []const u8,       // "user" | "assistant" | "handoff" | "permission_feedback"
        text: []const u8,       // original bytes, verbatim
        artifact: ?Artifact = null,
    };

    pub const ToolRecord = struct {
        alias: []const u8,      // "T1"
        call_id: []const u8,
        name: []const u8,
        status: ?[]const u8 = null,
        arguments: ?Artifact = null,
        result: ?Artifact = null,
    };
};
```

Using `= &.{}` defaults keeps every existing construction site compiling and
makes v1 artifacts load with empty tables. `finish`
(`compaction_policy.zig:241`) writes v2; `load_state` (line 103) accepts v1 and
v2.

Originals already exist as artifacts: user text is stored in `users` verbatim,
tool call arguments via `store_artifact(..., "arguments", ...)`, tool results via
their original `result-*` handle. The new records index into those rather than
duplicating bytes.

### 6.3 Allocation and rendering

In `prepare` (`compaction_policy.zig:165`), allocate aliases in iteration order:

```zig
var message_index: usize = 0;
var tool_index: usize = 0;
for (source) |message| {
    // ... existing branches ...
    if (message.role == .user and message.context_origin == .user_turn) {
        const alias = try std.fmt.allocPrint(alloc, "M{d}", .{@as(usize, @intCast(message_index + 1))});
        try records.messages.append(alloc, .{ .alias = alias, .kind = "user", .text = text });
        message_index += 1;
    }
    for (message.tool_calls) |call| {
        const alias = try std.fmt.allocPrint(alloc, "T{d}", .{@as(usize, @intCast(tool_index + 1))});
        const argument = try store_artifact(alloc, storage, "arguments", call.arguments_json);
        try records.tools.append(alloc, .{
            .alias = alias, .call_id = call.id, .name = call.name, .arguments = argument,
        });
        tool_index += 1;
    }
}
```

Update `render` (line 138) so the handoff names the aliases. Replace:

```zig
try text.writer.print("User {d}, UTF-8 bytes={d}:\n{s}\n", .{ i + 1, user.len, user });
...
try text.writer.print("Source archive {d}: {s}\n", .{ i + 1, archive.handle });
```

with alias-bearing output that also teaches the model how to use the aliases:

```zig
if (users.len > 0)
    try text.writer.writeAll("\nOriginal user messages, unchanged and chronological. Each M<n> is exact original text; read_tool_result accepts it as a handle.\n");
for (users, 0..) |user, i|
    try text.writer.print("M{d}, UTF-8 bytes={d}:\n{s}\n", .{ i + 1, user.len, user });
```

Tool receipts (`receipt`, line 128) gain the alias:

```zig
return std.fmt.allocPrint(alloc,
    "Original result handle: {s} (alias {s})\nOriginal bytes: {d}; ...",
    .{ handle, alias, memory.output_bytes, ... });
```

### 6.4 read_tool_result integration

The request asks to integrate into the existing abstraction rather than create a
parallel one. The integration point is `classifyHandleNormalization` plus
`readOutput`.

Add to `compactor.zig`:

```zig
/// Resolves an M*/T* alias against a persisted index for this session.
/// Returns null when the alias is unknown or the index is unavailable.
pub fn resolveAlias(storage: Storage, alias: []const u8) !?[]u8 {
    if (alias.len == 0 or (alias[0] != 'M' and alias[0] != 'T')) return null;
    for (alias[1..]) |byte| if (!std.ascii.isDigit(byte)) return null;
    // Load the state artifact for this session, then look up the alias.
}
```

This needs the **session's current compaction state handle**. That handle lives
in the `fx-compaction-state-v1` marker line inside the handoff text, not in a
side index, which means resolution requires locating the active handoff. The
practical approach: the worker already knows the active compaction state
handle when it builds the tool dispatch context, so expose it there.

In `read_tool_result.zig`, extend `classifyHandleNormalization` to leave
`M1`/`T1` untouched (they already pass through, since no `.txt` is appended and
the string equals its trimmed form), then in `readOutput`, before the existing
routes, try alias resolution:

```zig
fn readOutput(ctx: tool_dispatch.DispatchContext, input: *Input) ![]u8 {
    if (compactor.isAlias(input.handle)) {
        const resolved = try compactor.resolveAlias(ctx.compactor_storage(), input.handle)
            orelse return error.ResultHandleNotFound;
        const handle = try ctx.allocator.dupe(u8, resolved);
        defer ctx.allocator.free(handle);
        // Fall through to the normal result_store path with the real handle.
        return switch (input.selector) {
            .query => |query| result_store.searchByQueryManaged(ctx.allocator, ctx.session_child_capability.?, handle, query),
            .range => |range| result_store.readByRangeManaged(ctx.allocator, ctx.session_child_capability.?, handle, range.start_byte, range.byte_count),
        };
    }
    // ... existing routes unchanged
}
```

Because the alias resolves to a real handle and then goes through
`result_store.readByRangeManaged` / `searchByQueryManaged`, range reads and
query search come for free with existing bounds, chunking, and the
`read_max_bytes` cap. No parallel read mechanism is created.

### 6.5 Tests for Phase B

```zig
test "compaction persists user messages as M1, M2, ..." {
    // Prepare with three user turns; assert Stored.messages aliases are M1..M3
    // and that each record's text equals the source bytes exactly.
    try std.testing.expectEqualStrings("original one", records.messages[0].text);
    try std.testing.expectEqualStrings("original two", records.messages[1].text);
    try std.testing.expectEqualStrings("original three", records.messages[2].text);
}

test "compaction persists tool calls and results as T1, T2, ..." {
    // Two assistant tool calls plus their results.
    try std.testing.expectEqualStrings("T1", records.tools[0].alias);
    try std.testing.expectEqualStrings("T2", records.tools[1].alias);
    // The persisted arguments artifact holds the original JSON, not the summary.
    const original = try load_artifact(alloc, storage, records.tools[0].arguments.?);
    try std.testing.expectEqualStrings(original_arguments_json, original);
}

test "read_tool_result reads a persisted T* result by alias" {
    // Store, compact, resolve T1, read the range, compare against the original bytes.
}

test "read_tool_result searches a persisted T* result by alias" {
    // Query for a literal present only in the original output, not the summary.
}

test "an unknown alias reports ResultHandleNotFound rather than the original handle" {
    try std.testing.expectError(error.ResultHandleNotFound, compactor.resolveAlias(storage, "T99"));
}

test "aliases cannot escape the result store" {
    for ([_][]const u8{ "M", "T", "M0", "M-1", "Mx", "M../T1", "" }) |alias| {
        try std.testing.expect(compactor.resolveAlias(storage, alias) catch null == null);
    }
}
```

The alias-validation test matters: `resolveAlias` must reject anything that is
not `[MT][0-9]+` before touching the filesystem, and must never construct a
path from user input.

---

## 7. Requirement 8: checkpoint compatibility

### 7.1 The mechanism that already exists

`session_codec.parseHistoryTurn` (`session_codec.zig:610-661`) accepts four
`compacted_summary` shapes via `exactObject`. `exactObject` rejects unknown
keys, so **any added key must be added to every accepted shape list or old
files stop loading.**

The current ladder, in newest-to-oldest order:

```zig
.{ "kind", "summary", "removed_turn_count", "compaction_count", "root_user_messages", "root_user_messages_complete", "permission_feedback", "permission_feedback_complete" }
.{ "kind", "summary", "removed_turn_count", "compaction_count", "root_user_messages", "root_user_messages_complete" }
.{ "kind", "summary", "removed_turn_count", "compaction_count", "root_user_messages" }
.{ "kind", "summary", "removed_turn_count", "compaction_count" }
```

If `M*`/`T*` records are persisted **inside** the handoff summary text (the
state artifact), then `compacted_summary` gains no new JSON keys and the ladder
needs no change. That is the lowest-risk design and the one I recommend: aliases
live in the `fx-compaction-state-v1` artifact, which already round-trips through
the handle and digest recorded in the handoff marker.

If aliases are instead added as a `compacted_summary` field (for example
`compacted_aliases`), then:

```zig
// Newest rung.
.{ "kind", "summary", "removed_turn_count", "compaction_count", "root_user_messages", "root_user_messages_complete", "permission_feedback", "permission_feedback_complete", "compacted_aliases" }
```

and every older rung stays as-is, with the new field defaulting to empty when
absent, mirroring how `root_user_messages_complete` infers itself. `FXCP`
version stays `1`; the format is additive.

`Stored.version` in `compaction_policy.zig` moves `1` → `2`, and `load_state`
(line 103) accepts both:

```zig
if (parsed.value.version != 1 and parsed.value.version != 2) return error.InvalidCompactionState;
// v1 artifacts carry no alias tables; empty tables are correct, not missing.
```

### 7.2 Required compatibility test

The request asks for at least one representative previous-format checkpoint.
The existing tests at `session_codec.zig:4264-4328` already encode v1 JSON
literals. Add a checkpoint-level test using the **oldest** shape, which is the
hardest case:

```zig
test "a checkpoint written before alias tables still loads" {
    const alloc = std.testing.allocator;
    // Oldest supported shape: no root_user_messages, no completeness flags.
    const legacy = [_]types.HistoryTurn{.{ .compacted_summary = .{
        .summary = try alloc.dupe(u8,
            "fx-compaction-state-v1 legacy-summary-0000000000000000 42 " ++
            ("0" ** 64) ++ "\nolder handoff text\n"),
        .removed_turn_count = 2,
        .compaction_count = 1,
    } }};

    const bytes = try encode(alloc, &legacy, .{});
    defer alloc.free(bytes);

    var decoded = try decode(alloc, bytes);
    defer decoded.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), decoded.history.len);
    const summary = decoded.history[0].compacted_summary;
    try std.testing.expectEqualStrings("fx-compaction-state-v1 legacy-summary-0000000000000000 42 " ++ ("0" ** 64) ++ "\nolder handoff text\n", summary.summary);
    // Inferred, matching the pre-existing inference rules.
    try std.testing.expect(!summary.root_user_messages_complete);
    try std.testing.expect(!summary.permission_feedback_complete);
    try std.testing.expectEqual(@as(usize, 0), summary.root_user_messages.len);
}

test "a v1 compaction state artifact loads with empty alias tables" {
    const v1 = "{\"version\":1,\"summary\":\"prior memory\",\"users\":[\"kept\"],\"archives\":[]}";
    const stored = try parseStored(alloc, v1);
    try std.testing.expectEqual(@as(usize, 0), stored.messages.len);
    try std.testing.expectEqual(@as(usize, 0), stored.tools.len);
    try std.testing.expectEqualStrings("kept", stored.users[0]);
}

test "an unknown state version is rejected rather than silently misread" {
    try std.testing.expectError(error.InvalidCompactionState,
        parseStored(alloc, "{\"version\":99,\"summary\":\"x\",\"users\":[],\"archives\":[]}"));
}
```

Do not require users to delete or regenerate checkpoints. This design reads them
unchanged.

---

## 8. Requirement 9: boundary enforcement

### 8.1 New CI check

New script `scripts/check-compactor-boundary.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

internal='engine|policy|state|identifiers|summary_model|threshold|compat'
violations="$({
  git grep -nE "@import\(\"[^\"]*compactor/($internal)\.zig\"\)" -- 'src/**/*.zig' ':(exclude)src/core/compactor/**' || true
} | grep -v '^src/core/compactor/' || true)"

if [[ -n "$violations" ]]; then
  printf 'Compactor internals imported outside src/core/compactor:\n%s\n' "$violations" >&2
  exit 1
fi
```

Wire into `full-ci.yml` next to `zig fmt --check src/` (line 48) and
`./scripts/check-public-surface.sh` (line 51):

```yaml
      - name: Check compactor boundary
        run: ./scripts/check-compactor-boundary.sh
```

### 8.2 Boundary unit test

A shell check alone can be bypassed. Add a Zig test that makes the boundary a
compile-time property:

```zig
// tests in compactor.zig
test "the public surface is exactly the intended set" {
    const decls = @typeInfo(compactor).@"struct".decls;
    var public_names: std.ArrayList([]const u8) = .empty;
    defer public_names.deinit(std.testing.allocator);
    for (decls) |decl| {
        if (decl.is_pub()) try public_names.append(std.testing.allocator, decl.name);
    }
    std.mem.sort([]const u8, public_names.items, {}, lessThanStr);
    try std.testing.expectEqualSlices([]const u8, &.{
        "Request", "Result", "Storage", "Trigger", "Threshold",
        "compact", "parsePercent", "resolveAlias",
    }, public_names.items);
}
```

This catches accidental `pub` widening on internals, which is the realistic
regression. It does not prove nobody imports an internal, so it complements
rather than replaces the shell check.

Avoid a test that merely greps filenames. The shell check enforces a real
dependency rule; the Zig test enforces the exported surface. Together they
constrain actual coupling.

### 8.3 Refactoring callers

`orchestrator.zig` currently reaches into `runtime_context_compaction` for
`promoteMessageResults` (6373), `compact` (6382), and `ResultStorage` (6266,
7527). After the move, `compactContextTransaction` becomes a thin adapter:

```zig
pub fn compactContextTransaction(
    alloc: Allocator,
    deps: *const AgentRuntimeDeps,
    request: ContextCompactionTransactionRequest,
) !?ContextCompactionTransactionResult {
    const outcome = try compactor.compact(alloc, &.{
        .cancel_flag = deps.ctx,
        .trace_ctx = request.trace_ctx,
        .activity = deps.compaction_activity,
    }, .{
        .trigger = switch (request.activity_origin orelse
            (if (request.trigger == .manual) .manual else .automatic)) {
            .provider_overflow => .provider_overflow,
            .manual => .manual,
            else => .automatic,
        },
        // ... map every field
    }) catch |err| {
        // Existing activity-settlement and provenance logic unchanged.
        return err;
    };
    const result = outcome orelse return null;
    try commitContextCompaction(deps, .{ .summary = result.handoff, ... });
    return .{ .compacted = result, .accepted_tokens = result.accepted_tokens };
}
```

`app_agent_runtime.zig:901` stops importing
`../agent/runtime/context_compaction.zig` and imports
`../../core/compactor/compactor.zig` for `Storage` instead.

`execution_memory.zig:1707` and `1790` import `context_compaction` only inside
test blocks for `promoteMessageResults`. Those tests move to the compactor
package or call the public surface instead.

`agent_runtime.zig:50` updates its test aggregation to import the new package.

---

## 9. Requirement 9, tests for existing behavior

Requirements 2 and 3 are already implemented. They need regression tests that
lock in current behavior, so a future refactor cannot quietly break them. These
are assertions about what exists, not new code.

```zig
test "user messages survive compaction byte for byte" {
    // Source users with multibyte text, embedded newlines, and handoff markers.
    const users = [_][]const u8{
        "Keep café and the original constraint.\n<context_handoff>literal</context_handoff>",
        "第二行\n第三行",
        "trailing spaces   ",
    };
    // After prepare + finish, reload Stored and compare byte for byte.
    for (users, 0..) |original, i| {
        try std.testing.expectEqualStrings(original, reloaded.users[i]);
        try std.testing.expectEqual(original.len, reloaded.messages[i].text.len);
    }
}

test "the summarizer view is annotated but the persisted user text is not" {
    // prepare() prefixes the model-visible copy with USER_RETAINED / USER_TO_SUMMARIZE
    // while Stored.users keeps raw bytes. Assert both, so the two never get conflated.
    try std.testing.expect(std.mem.startsWith(u8, prepared.messages[i].content.?, "USER_"));
    try std.testing.expect(!std.mem.startsWith(u8, prepared.users[i], "USER_"));
}

test "the newest assistant reply is preserved exactly after compaction" {
    // Three assistant turns, only the first compacted.
    const reply = "The newest final reply, exactly as produced. ✓ 🦊";
    const window = try prepareRetainedCompactionWindow(arena, &history, null, caps, tokens, provider, sel, .{});
    // Retained messages must contain the reply byte for byte.
    var found = false;
    for (window.retained_messages) |message| {
        if (message.content) |content| {
            if (std.mem.indexOf(u8, content, reply) != null) found = true;
        }
    }
    try std.testing.expect(found);
    // And it must not appear in the compaction source, i.e. it was not summarized.
    for (window.source) |message| {
        if (message.content) |content| {
            try std.testing.expect(std.mem.indexOf(u8, content, reply) == null);
        }
    }
}

test "historical assistant work is summarized while the newest reply is retained" {
    // Assert source contains older content and retained contains the newest reply,
    // with no overlap. This is the exact property the request describes.
}

test "tool call arguments are persisted unchanged, not summarized" {
    const arguments_json = "{\"command\":\"echo exact\",\"unexpected\":\"<context_handoff>\"}";
    // Store the artifact, reload it, assert byte equality with the original.
}
```

A Zig-level test for each flow reaching the unified entry:

```zig
test "manual compaction reaches the unified compactor" { /* trigger = .manual */ }
test "automatic compaction reaches the unified compactor" { /* trigger = .automatic */ }
test "overflow recovery reaches the unified compactor" {
    // shouldRecoverContextOverflow(overflow_failure, ...) == true,
    // then assert the trigger passed to the compactor is .provider_overflow.
}
```

The overflow one is the interesting case, because it is the one place the
trigger must be *promoted* from `.automatic` to forced. Test that promotion
directly.

E2E coverage belongs in the existing classified files rather than new ones:

- `tests/e2e/compaction-policy.test.ts` (already `verify-compaction-policy`):
  add a case driving `FX_AUTO_COMPACT_PERCENT=25` against a fixed-size fixture
  and asserting compaction fires earlier, plus a case with
  `FX_AUTO_COMPACT_PERCENT=95` asserting it is ignored as invalid.
- New `tests/e2e/read-tool-result-alias.test.ts` exercising `T1` through the real
  binary. **This needs a new entry in `scripts/pgso/corpus.json`** with a
  concrete classification. Recommended: `verification_scenarios` as
  `verify-read-tool-result-alias` with `requires_tmux: false`, since it is
  deterministic post-compaction recovery and must not become PGSO-hot.

---

## 10. Execution order and risk

| Step | Change | Risk | Gate |
| --- | --- | --- | --- |
| 1 | `src/core/compactor/threshold.zig` + tests | Low | `zig build test` |
| 2 | `CompactionPlanInput.compact_percent`, settings parse, env override | Low | focused tests |
| 3 | Boundary script + CI wiring | Low | run script locally |
| 4 | Regression tests for requirements 2 and 3 | Low | tests pass on unmodified logic |
| 5 | `Stored` v2 with alias tables, compat loader + tests | Medium | compat tests |
| 6 | `M*`/`T*` allocation and handoff rendering | Medium | `compaction-policy.test.ts` |
| 7 | `resolveAlias` + `read_tool_result` integration | Medium | new e2e + unit tests |
| 8 | `summary_model.zig` attempts planner + tests | Medium | unit tests |
| 9 | `runSummaryCall` restructure with bounded retry | Higher | full compaction test set |
| 10 | Extract window/commit plumbing | Higher | full suite, then exercise binary |

Steps 1-4 are independent of 5-9 and can land separately. Step 10 is optional
maintenance and carries the most regression risk for the least user-visible
gain; I would defer it.

### Risk notes

**Step 9 is the riskiest.** `runSummaryCall` sits in the middle of the compaction
transaction. Its retry semantics interact with two existing loops: the
capacity-attempt loop around `compact` (`context_compaction.zig:134`) and the
`refine_budget` loop in both call sites. Changing retry counts can change how
many provider calls a single `/compact` makes, which `compaction-policy.test.ts`
asserts on. That test is the regression detector for this step.

**Steps 5-7 touch persistence.** `result_store` handles are content-addressed
and immutable. Aliases must never overwrite or shadow a real handle. The
`resolveAlias` validation test in 6.5 is the guard.

**Step 2 changes a config surface.** Adding `auto_compact_percent` to
`settings.json` requires deciding whether it is project-committable. Per
`AGENTS.md` the project allowlist is explicit; leaving it profile-only avoids
expanding that surface.

### Verification before declaring done

Per `AGENTS.md`, "ready" requires more than green tests:

1. `zig build` succeeds.
2. `zig fmt --check src/` passes.
3. Focused tests for the changed paths pass.
4. Full CI passes on all four runners for the exact commit.
5. Drive the built binary: run a real session long enough to compact, then use
   `read_tool_result` with a `T*` alias and confirm original bytes come back.
6. Confirm clean stderr and no abort.

Only then report ready. Per `AGENTS.md`, if the binary cannot be run in this
environment, say so and ask for verification rather than declaring success.

---

## 11. Files changed

Added:

- `src/core/compactor/compactor.zig`: public interface
- `src/core/compactor/threshold.zig`: percent resolution and validation
- `src/core/compactor/identifiers.zig`: `M*`/`T*` allocation and parsing
- `src/core/compactor/summary_model.zig`: attempts planner and fallback
- `src/core/compactor/engine.zig`: chunking and summary calls (moved)
- `src/core/compactor/policy.zig`: retention policy (moved)
- `src/core/compactor/state.zig`: semantic projection (moved)
- `src/core/compactor/compat.zig`: legacy marker reading and migration
- `scripts/check-compactor-boundary.sh`
- `tests/e2e/read-tool-result-alias.test.ts`

Modified:

- `src/core/agent/runtime/orchestrator.zig`: delegate to `compactor.compact`
- `src/core/agent/runtime/prompt_context.zig`: configurable high-water ratio
- `src/core/agent/runtime/execution_memory.zig`: update test imports
- `src/core/agent/agent_runtime.zig`: test aggregation, re-exports
- `src/core/config/settings_store.zig`: parse `auto_compact_percent`
- `src/core/app/app_lifecycle.zig`: `FX_AUTO_COMPACT_PERCENT` resolution
- `src/core/app/app_agent_runtime.zig`: use `compactor.Storage`
- `src/core/cli/doctor_runtime.zig`: report the effective percent
- `src/core/session/session_codec.zig`: extend the compat ladder if needed
- `src/tools/session/read_tool_result.zig`: alias resolution
- `.github/workflows/full-ci.yml`: boundary check step
- `scripts/pgso/corpus.json`: classify the new e2e file
- `README.md`, `AGENTS.md`: document `auto_compact_percent`

Deleted (moved):

- `src/core/agent/runtime/context_compaction.zig`
- `src/core/agent/runtime/context_compaction_state.zig`
- `src/core/agent/runtime/compaction_policy.zig`

---

## 12. Remaining differences from the request

Stated plainly, so nothing is implied that is not delivered:

1. **The compactor is not built from scratch.** All three flows already shared
   `compactContextTransaction`. The refactor relocates and hardens the existing
   implementation rather than consolidating three divergent ones.

2. **"Lowest reasoning level" relies on an unverified ordering.**
   `ReasoningEffortOptions` declares no ordering contract. Selecting index 0
   assumes providers declare ascending. Deterministic for a given capability
   set, not guaranteed correct across providers. See 5.2.

3. **Cross-family fallback needs a model catalog plumbed in.** No such
   abstraction exists today. The plan requires threading the Gateway model list
   into the compactor. That is the largest new dependency in this work.

4. **`read_tool_result` alias resolution needs session state.** The alias index
   is reachable only via the handoff marker. The active handle must be exposed
   on the tool dispatch context, a small but real plumbing change.

5. **Empty-output retry semantics change.** Keeping today's empty-output retry
   *and* adding one cross-family retry would allow four provider calls. The plan
   caps at one retry per model (two calls total), which slightly changes
   behavior when the primary returns empty and no fallback exists.

6. **Window/commit plumbing extraction is optional.** It is the true
   deduplication, but it carries the most regression risk and no user-visible
   benefit. I would defer it.

7. **PGSO classification of the new e2e file needs a maintainer decision.** The
   recommendation is verification-only, but `AGENTS.md` treats corpus
   classification as a deliberate act, not a mechanical one.
