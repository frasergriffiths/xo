# Plan: full-screen TUI mode for fx

A written plan only. Nothing in this document has been executed. Every path, line number,
and count below was measured on commit `main` (`1b1f9af1`) in this checkout on
2026-10-01.

## Goal

Add a full-screen display mode to fx, switched with `/fullscreen`, in which the
full-screen surface is live. The user can compose and send prompts, watch fx stream a
response in place, answer permission prompts, and scroll history without leaving the mode.

`/fullscreen` is a toggle that persists to `~/.fx/settings.json`. Every invocation writes
the new state, so the choice survives restart. Set it once and fx comes up that way from
then on.

The existing alternate-screen render path is the base. It already renders through the right
pipeline and already has a working scroll model. What it does not have is a composer, so
the plan removes that limitation instead of writing a new renderer.

## What the user asked for

These are requirements, not options. The plan is written to satisfy all of them.

1. **Delete Ctrl+O.** Remove the binding, the reader mode, and the key feature action it
   dispatches. Ctrl+O must stop doing anything.
2. **`/fullscreen` is the full-screen takeover.** Entering it should feel like the Ctrl+O
   takeover: the same clean swap into the alternate screen that Ctrl+O performs today, but
   fx stays usable inside it. The binding still goes away with Ctrl+O; only its transition
   is the model.
3. **Stay live inside the mode.** The user composes, sends, watches the response stream,
   and answers permission prompts without leaving full-screen.
4. **No expanded view.** Do not carry over the "more visible information" behavior that
   Ctrl+O offered. This is a full-screen view of the ordinary chat surface, not a detail
   view and not a transcript reader.
5. **Pin the chrome.** The footer line and the input must not move while the transcript
   scrolls. The transcript scrolls under them.

The user showed the exact footer they mean, so it is worth naming here:

```
┃ full access · deepseek-v4.1-flash · 72k/1048k 6%
```

That line and the input row stay fixed at the bottom of the frame during scrolling.

## The verdict up front

fx already contains an alternate-screen TUI. It is hidden behind Ctrl+O, it is a viewer
rather than a live surface, and it is built on exactly the pipeline a permanent
full-screen mode wants. Four findings shape the plan:

1. **Do not build a second renderer.** The alternate transcript already renders through the
   same `PaintPlan` to `FrameSurface` to `Grid.diffBand` path as the inline transcript.
   Full-screen mode reuses that path and changes the band decomposition and the scroll
   model.
2. **The blocker is the composer, not the renderer.** The alternate screen is read-only
   today, and the input layer swallows printable bytes while it is active. That is a
   routing-gate problem, and it is Phase 1.
3. **Streaming into the alternate screen already works.** Content changes bump
   `full_transcript_content_revision`, which invalidates the projection and triggers a
   worker rebuild. Liveness is not the risk. Input is.
4. **Persistence is plumbing, not design.** `/fullscreen` writes through the same
   `attemptUserPreferences` path as `startup_scrollback`, and the one real decision is
   commit-first ordering.

## What fx already has

Measured against this checkout:

| Capability | Status | Evidence |
| --- | --- | --- |
| Alternate-screen enter and leave | Present | `app_lifecycle.zig:45`, `:1337`, `:1351` |
| Exclusive screen ownership arbitration | Present | `shell_runtime.zig:57`, `app_lifecycle.zig:1344` |
| Whole-grid full-screen frame paint | Present, reached today through Ctrl+O | `app_render_runtime.zig:1174`, `:1754` |
| Incremental full-screen content updates | Present | `runtime.zig:11453` and four sibling `mark*Dirty` calls |
| Cell grid with per-cell damage diff | Present | `core/terminal/engine.zig`, `diffBand` |
| Band ownership model with validation | Present | `paint_plan.zig:337`, `.validate` at `:356` |
| Scroll offset state machine with anchor and follow-tail | Present, built and tested | `core/output/transcript_presentation.zig` |
| Off-thread scroll window pre-render | Present | `ui/transcript/full_transcript_worker.zig` |
| Two-phase resize with cursor probe and reflow replay | Present | `ui/resize_runtime.zig` |
| Deterministic no-fd render test harness | Present | `ui/resize_tests.zig` |
| Debug tape record and replay | Present | `fx replay`, `FX_DEBUG_RECORD` |

`alternate_screen_owns_rendering` is already a generic predicate over
`alternate_screen_owner != .none` (`app_render_runtime.zig:1174`). When it is set, the
render loop writes the committed layout to `terminal.alternate_frame_layout` instead of
`shell.committed_frame_layout` (`:1754`) and skips the inline transcript commit machinery
(`:1210`). Any owner inherits correct behavior from this.

### Streaming already reaches the alternate screen

This is the most useful finding, because it is the assumption most likely to send you
building something you do not need.

The projection is rebuilt when `full_transcript_content_revision` changes. Five functions
bump it: `markTranscriptContentDirty` (`runtime.zig:11453`),
`markTranscriptStructureDirty` (`:11466`), `markTranscriptContentDirtyFrom` (`:11479`),
`markTranscriptCommandOutputDirty` (`:11493`), and `markTranscriptCommandOutputDirtyFrom`
(`:11506`). Each also requests a paint.

`full_transcript_page.sameRequest` (`full_transcript_page.zig:41`) compares
`content_revision`, `cols`, and `anchor`, so a revision bump invalidates the cached
projection and forces a rebuild on the worker. Tool lifecycle updates and streamed
assistant chunks call the `mark*Dirty` family, so output written while the alternate screen
is open already reaches it.

There is a second, narrower check worth knowing about. `sameSurface` (`:47`) deliberately
ignores `content_revision`, so a surface-validity check does not treat a content change as
a geometry change. If Phase 2's live work surfaces a stale frame, look here first.

### Dead code that is exactly the seam you want

`tail_viewport_request` is read at `ui/transcript/painter.zig:2049` and written nowhere.
Its doc comment describes "detached alternate-screen views [that] request the ordinary
compact transcript at a stable distance from its tail." The mechanism landed, the caller
never did. `transcript_presentation.State` is a complete, tested scroll model
(`scroll_rows`, `follow_tail`, `anchor_entry_id`, `bookmark_entry_id`, `defer_full_open`,
reflow-stable offset restore).

Someone already built the viewport model for a scrollable compact transcript. Nothing is
attached to it yet.

## What gets deleted: Ctrl+O

Ctrl+O is removed outright, not repurposed. Four pieces go:

1. The byte-15 branch in `controlByteFeatureAction` (`escape_parser.zig:268`) that maps to
   `.toggle_full_transcript`.
2. The `.toggle_full_transcript` escape action and its dispatch branch in
   `app_input_runtime.zig`.
3. The reader-mode input gate in `input_full_transcript_runtime.zig`, the boolean
   `screenOwnsInput` at `:30`, and `routeAction` at `:47`.
4. The reader UX itself: the expanded transcript, the "more visible information" layout,
   and any search that only lived there.

What stays is the machinery underneath. The projection, the off-thread worker, the page
request identity, and the band render path are reused by the new surface. They are
program structure, not user-facing features, and throwing them away would mean rebuilding
a renderer that already works.

One consequence to own: the `full_transcript` name stops describing the surface. Rename the
owner value to `.full_screen` (or keep the value and rename the concept in the docs) so the
enum no longer claims a reader that no longer exists. This is a rename, not a new owner.

## Why the screen is read-only today

`screenOwnsInput` (`input_full_transcript_runtime.zig:30`) returns true whenever the
alternate screen is active. When it does:

- `routeAction` (`:47`) intercepts every decoded action.
- `keyForAction` (`:156`) has no branch that yields a composer action; unmatched input
  falls to `else => null`, `routeAction` returns false, and the byte continues on.
- The composer receives the byte, but it lives in an inline band that the alternate screen
  does not paint.

So keystrokes land in a composer nobody can see. That is not a degraded experience, it is a
missing one. Two fixes are required together, and doing only the first produces a mode that
accepts input and renders nothing.

## The constraint you have to resolve first

`CONTRIBUTING.md:282`:

> Do not add a general alternate-screen (`\x1b[?1049h/l`) render path. fx is inline by
> design except for the three exclusive owner classes represented by
> `AlternateScreenOwner`: interactive tool-approval review, the full-transcript screen,
> and catalog menus.

`AGENTS.md:290` says the same in the rendering section.

This plan resolves the tension rather than working around it. `/fullscreen` does not add a
fourth owner. It replaces the full-transcript reader with the full-screen chat surface. It
changes the documented rule from "the full-transcript screen may take the alternate buffer"
to "the full-screen chat surface may take the alternate buffer, and while it holds it the
composer lives inside it."

Deleting Ctrl+O drops `AlternateScreenOwner` to three entries, since the reader and the
full-screen surface are the same owner slot. That keeps the "only one class may own the
buffer" rule intact and keeps `CONTRIBUTING.md:3`'s CLI-first posture, because inline
remains the default and `/fullscreen` is opt-in.

The docs amendment is small and specific, not a rewrite of the rendering philosophy.

Also resolve this before writing code: `.catalog_menu` is declared at `shell_runtime.zig:57`
but has no production enter path. Its only callers are `app_lifecycle.zig:1901` and `:1902`,
both inside the test block starting at `:1877`. Either a feature was removed mid-migration
or it was never wired. Do not add surface area to an enum that overstates its contents.

## Screen model

A full-screen frame decomposes the grid into non-overlapping `FrameBand` rows with a
`CellOwner` tag, exactly as inline does. `paint_plan.zig:9` currently has
`preserved_shell`, `transcript`, `gap`, `activity`, `footer`, `diagnostic_clear`.

Proposed decomposition, top to bottom:

| Rows | Owner | Content |
| --- | --- | --- |
| 1 | `header` | Session name, workspace, model, permission mode |
| 2 to `t` | `transcript` | Scrolled conversation body |
| `t + 1` | `gutter` | Scrollbar, one column at the right edge |
| `t + 2` to `b` | `composer` | Input, possibly multiline |
| `b + 1` | `footer` | Mode hints, key hints, status |

This is the ordinary inline chrome, not an expanded view. The `header` and `gutter` bands
are new, and they carry the same information the inline footer already shows. Nothing in the
frame shows more than inline does.

`PaintPlan.validate` has fifteen pairwise `rejectBandOverlap` calls at `paint_plan.zig:372`
to `:386`. Adding `header` and `gutter` makes it twenty-one, and the `switch` sets in
`frame_surface.zig` (`ownerLegalAt`, `initialOwnerForRow`, `ownerPlannedForRow`,
`anyOwnedBandContains`, `activityOverlayRow`) need new branches. This is mechanical,
compile-checked, and the largest single edit in the plan.

Reuse the existing `footer` owner for the composer in Phase 1 rather than adding a new one.
The composer already paints through a footer band, so widening that band's inputs is
smaller than a new `CellOwner`, and it keeps Phase 1 free of overlap-check churn. Add
`header` and `gutter` later, in Phase 2, when the composer is proven.

Budget for narrow terminals. At 24 rows with a multiline composer and a header, the
transcript body gets roughly ten rows. Decide the floor explicitly and refuse to enter
full-screen below it rather than rendering something unusable. `TerminalTooSmall` and a
refusal are acceptable. A mangled frame is not.

## Pinned chrome: footer and input stay put

The user's requirement is specific and easy to get wrong. While the transcript scrolls, the
footer line and the input row must not move.

In inline mode the whole layout shifts upward as content grows, because inline emits real
newlines and lets the terminal scroll. A fixed frame inverts that. The transcript band
scrolls internally; the composer and footer bands are anchored to the bottom row of the
frame and never move.

Concretely:

1. The composer band has fixed rows at the bottom of the frame, directly above the footer.
2. The footer band occupies the last row or rows and is painted from the same source it uses
   inline, so the text is identical.
3. Scrolling changes the transcript band's logical offset only. It never changes the row
   where the composer or footer starts.
4. The hardware cursor stays in the composer, so the input never appears to jump.

Test this directly. A scroll-only frame must not move the composer or footer rows. Capture
the grid before and after a scroll and assert those rows are byte-identical.

## Composer

This is the phase the whole plan exists for.

1. **Paint the composer inside the frame.** The composer becomes a band in the full-screen
   `PaintPlan`, painted by `FrameSurface` like any other band, with the hardware cursor
   parked in it. Input editing logic, multiline layout, `@` file picking
   (`file_index.SearchResult`, `show_file_query` at `surface_frame.zig:415`), and selection
   movement all stay as they are. Only the row source changes.

2. **Replace the exclusive input gate with a tiered router.** `screenOwnsInput` is a single
   boolean that either takes the byte or does not. Full-screen needs one byte to reach three
   possible consumers: scroll keys to the viewport, control bytes to screen actions
   (interrupt, submit, paste), and printable bytes to the composer. Build a routing table
   keyed on decoded action. `routeComposerAction` (`:54`) is the partial prototype of this
   seam: it handles only `.toggle` and `.close`, then returns false.

3. **Decouple composer height from footer reserved-row math.** Composer rows are derived
   from `footerTopRowForExtra` and `extra_input_rows` today
   (`viewport_runtime.zig:255`). In full-screen the composer has fixed rows inside the
   frame. Any code path that computes composer height from the footer's reserved-base-rows
   arithmetic is a bug waiting to happen. Find them before Phase 1 lands.

4. **Keep editing state valid across mode transitions.** A live toggle means the composer is
   mid-edit when the user runs `/fullscreen`. Preserve the buffer, the cursor offset, and
   any in-progress selection across both directions of the switch, or the toggle silently
   eats the user's draft.

## Scroll model

Inline grows by emitting real newlines and letting the terminal scroll.
`frame_scroll_plan.merge` takes `requested_release_rows` and `inline_advance_rows` and
prefers releasing preserved rows over advancing inline, which is what drives `owned_top_row`
toward 1 over time. Correct for inline, wrong for a fixed frame, where scroll must be a
logical offset with no physical scroll at all.

Attach the existing `transcript_presentation.State` to the live surface. It already provides
`scroll(direction, rows)`, `follow_tail`, and offset selection with priority pending
bookmark, then pending anchor, then follow-tail, then raw offset, clamping to
`max_offset = total_rows -| visible_rows`. All of that is correct.

Then make three specific changes:

1. **Offset-anchored viewport selection.** `viewport_selection.zig::buildViewportSelection`
   always selects the tail via `selectTail`, consuming rows backward from the last line and
   partially including the preceding line on overflow. Full-screen needs an arbitrary
   `start_line` from a visual row offset. The data is present: `TranscriptPreparationSource`
   carries `hard_line_starts`, `transcript_visual_row_offsets`, `line_provenance`, and
   `byteAtVisualOffset`, with the index built lazily in `ensureLineIndexInterruptible`.

2. **Zero newline emission in full-screen.** `consumeFrameScrollCommit` reconciles planned
   scroll against physically committed rows and surfaces `unplanned_terminal_scroll_rows`.
   In full-screen, planned scroll is zero by construction. Add a mode predicate rather than
   special-casing.

3. **Fix the retention ceiling.** The inline paint source is a 256 KiB byte cache
   (`max_transcript_bytes`) backed by a 1 MiB structured store
   (`max_retained_transcript_bytes`). A user scrolling up in a long session will hit the
   tail window and find missing history. Raise the byte cache in full-screen, or serve
   scrollback from the structured store through the same `Projection` machinery the
   existing screen uses.

That third point is the failure mode that would make the mode feel broken, and it is
invisible until someone scrolls up in a long session.

### Scrollback anchoring under pruning

`enforceStructuredRetentionWithTrims` (`store.zig:944`) prunes oldest-first, and
`compactEntriesToRetainedSet` (`:313`) mutates the entry array in place, so entry ids are
not stable across a retention event. `RetentionRebase` in `source_preparation.zig` maps old
offsets forward. Any bookmark that survives pruning must go through the same rebase or it
drifts silently. At a 1 MiB cap this is routine, not exceptional.

The existing screen already handles this correctly through `refresh_bookmark`, which
recomputes the anchor from `item_rows` rather than caching an absolute row. Reuse that. Do
not store absolute visual rows in a persistent offset.

### Live streaming and follow-tail

While a turn streams into the full screen, decide explicitly whether new output follows the
tail when the user has scrolled up. Inline has a precedent: `nativeHistoryActive()`
(`runtime.zig:11444`) is true when `history_visual_offset > 0`, and `streamAssistantChunk`
consults it to suppress partial-token repaints so streaming text does not yank the view. It
has exactly one caller.

Recommended behavior for the live surface: stream into the frame regardless of scroll
position, and show an unobtrusive "jumped to latest" affordance when the user is scrolled
away. Suppressing output is the wrong trade in a mode where the response is the point.

### Steady-state cursor

Every current `cursor_target` producer parks the hardware cursor at the composer input row.
In full-screen the user can be scrolled deep into history while the composer still has
focus. Recommended default: the cursor stays in the composer, always visible, the transcript
scrolls under it, and follow-tail resumes when the user returns to the tail.

### Native scrollback interaction

Inline detects terminal scrolling with the native clear probe: on each printable byte it
withholds the byte, issues a synchronized CPR sandwich at columns 1 and 2, and compares the
observed row against the footer row. A mismatch means the terminal scrolled, so fx calls
`resetVisualEpoch` and re-renders.

Two eligibility conditions matter. It rejects `TMUX != null`, and it rejects any active
`alternate_screen_owner`, with the comment that any response from the alternate screen is a
guaranteed false mismatch. The probe is already blind in full-screen mode, which is correct,
and it also means mouse wheel events must be routed to the viewport model, not to the
terminal.

## Permission prompts and subagents

A full-screen agent that cannot show a permission prompt is not usable, because
permission-first is fx's security model.

The approval screen is a separate alternate-screen owner. Today
`handoffFullTranscriptToApproval` (`app_lifecycle.zig:1288`) hands the buffer from one owner
to the other, and `transitionFullTranscriptForApproval` (`:1184`) drives it. In a permanent
full-screen mode this becomes a routine recurring event rather than a rare edge case, which
means:

- The handoff must restore the full-screen frame exactly, including scroll position,
  follow-tail state, composer buffer, and cursor.
- On decline or cancel, the turn resumes in full-screen with no visible flicker.
- Question prompts (`question_prompt.zig`) and subagent delegation panels currently render
  inline. Decide per surface whether they move into the frame or still require leaving it.
  Subagent panels are the most likely to justify a second pane.

Phase 1 cannot ship without this. It is the difference between a demo and a tool.

## `/fullscreen` command

Follow the established spec shape (`command_specs.zig:144`):

```zig
pub const SlashSpec = struct {
    kind: SlashKind,
    command: []const u8,
    aliases: []const []const u8 = &.{},
    show_aliases_in_completion: bool = true,
    help_entry: ?[]const u8 = null,
    completion_description: ?[]const u8 = null,
    presentation_category: ?SlashPresentationCategory = null,
    show_in_welcome: bool = false,
    has_args: bool = false,
    accepts_payload: bool = false,
    requires_prompt_credential: bool = false,
};
```

Use `/fullscreen` as a toggle, with an explicit argument for the initial state:

```zig
.{ .kind = .fullscreen, .command = "/fullscreen", .help_entry = "/fullscreen [on|off]",
   .completion_description = "toggle the full-screen display", .presentation_category = .appearance }
```

Notes on the fields that bite:

- `presentation_category = .appearance` puts it in the right tab of the `/` catalog.
  `SlashPresentationCategory` is at `command_specs.zig:114`.
- `accepts_payload = true` means any trailing text routes to your handler. Validate the
  argument explicitly and fall through to `commandUnknown` (`app_commands.zig:1105`) on bad
  input.
- Bare `/fullscreen` with no argument toggles. `/fullscreen on` and `/fullscreen off` set
  the mode and apply immediately.
- Array position is asserted by a test. `builtins/commands.zig:472` is a "built-in slash
  commands register exact active order" test over an `expected_commands` list. Insert the
  literal and update that list in the same change.

### Every change persists

`/fullscreen` always writes to `~/.fx/settings.json`. Toggling with no argument persists the
new state just as `/fullscreen on` and `/fullscreen off` do. There is no session-only mode.
The user's choice survives restart, which is the point of having the command at all.

The persistence path already exists and is used by comparable preferences.
`startup_scrollback` is the closest precedent: `saveStartupScrollbackSetting`
(`session_commands.zig:592`) calls `config_runtime.attemptUserPreferences(.{ ... })`, which
routes to `settings_store.applyUserPatchToRoot`. `statusline_item` follows the same path
through `applyStatuslineItem`. Neither has a `persist: bool` field on `SlashSpec`.
Persistence is decided by which code the handler calls.

Four properties the implementation must have, since a display mode that silently fails to
write is worse than one that does not exist:

1. **Report the write, do not assume it.** `attemptUserPreferences` returns a `CommitAttempt`
   carrying an `.outcome` and a `.failure`. On failure, call `reportUserSettingsFailure`
   rather than telling the user the mode is saved. The existing handlers use
   `persistUserPreferences` and `persistUserPreferencesSilently` (`app_commands.zig:2962`).
2. **An invalid stored value must not brick startup.** `parseProfileOnlyFields` rejects a
   non-bool with a typed error, and that error path has to resolve to "fall back to inline"
   rather than refusing to launch. A display preference is not worth a failed startup.
3. **The stored value is a launch default, and the toggle wins.** If `/fullscreen off` writes
   `false`, the next launch starts inline. A mid-session toggle already reconciled terminal
   state, so it needs no second write.
4. **Commit-first, not runtime-first.** `SettingsMutation.mutationMode` (`settings_store.zig:283`)
   currently chooses `"commit_first"` only for `prompt_history_enabled` and a few other
   cases, otherwise `"runtime_first"`. For a preference that takes over the terminal buffer,
   write first and apply second. If the process dies after applying but before persisting,
   the next launch silently reverses a choice the user believes they made.

Add one focused test at this level: toggle, restart, assert the mode survived. It is the
only test that catches the failure mode where the handler renders correctly and the write is
quietly dropped.

Full wiring checklist:

| # | Site | Change |
| --- | --- | --- |
| 1 | `command_specs.zig:31` | Add `SlashKind.fullscreen` |
| 2 | `builtins/commands.zig:394` | Add the `SlashSpec` literal, in the position the order-lock test at `:472` expects |
| 3 | `command_router.zig:7`, `:74`, `:119` | Three exhaustive switches: union member, parse case, route case |
| 4 | `app_commands.zig:268` | Handler table entry inside `Handlers(comptime App)` |
| 5 | `app_commands.zig` | The handler itself: toggle, or persist on/off, then report through `app.writeDomainNotice` |
| 6 | `config_runtime.zig:39` | `fullscreen: ?bool = null` on `Settings` |
| 7 | `config_runtime.zig:746` | Add the key to `isProfileOnlySettingKey`, or it is silently ignored in `.fx.json` |
| 8 | `config_runtime.zig:1519` | Parse in `parseProfileOnlyFields` with `error.InvalidFullscreenType`, or add to `parseProjectSafeFields` at `:1762`. Pick one, not both |
| 9 | `config_runtime.zig:1819` | Merge line in `mergeSettings` |
| 9b | `settings_store.zig` | Commit before applying: `mutationMode` (`:283`) must return `"commit_first"` for this patch |
| 10 | `settings_store.zig:208` | `UserPreferenceField` is `enum(u4)` with 12 members. A 13th fits, using 3 of 4 spare slots |
| 11 | `settings_store.zig:1770` | Add to `validateKnownSettingsObject`. Without it, bad values are written unvalidated |
| 12 | `settings_catalog.zig:25` | `SettingId.fullscreen` plus a `Snapshot` field and a `value(id)` case, if it should appear in `/settings` |
| 13 | `app_lifecycle.zig:729` | Resolve the launch default in `bootstrapInteractiveApp`, after `:820`, before `:843` |

Step 7 is the one people miss. `isProfileOnlySettingKey` produces only a warning diagnostic,
and `parseProjectSafeFields` accepts a six-key allowlist. A key outside both lists is
silently ignored in project config with no error at all.

Step 10 is tight. If more preferences land soon, widen `UserPreferenceField` to `enum(u5)`
now rather than hitting the ceiling later.

### The live switch

The toggle is the hard part of the command, and it is a separate concern from persisting the
preference.

A runtime switch must reconcile, atomically: the alternate buffer, the shadow VT state
(`enableShadowVt` runs at `app_lifecycle.zig:775`), the committed layout destination
(`shell.committed_frame_layout` versus `terminal.alternate_frame_layout`), the viewport
anchor, `owned_top_row`, composer height, and the terminal mode sequence. Any ordering
mistake leaves a desynced frame.

Two ordering constraints are hard requirements:

- **Resolve before `enableInteractiveTerminalModes` (`app_lifecycle.zig:843`).** That writes
  `interactive_mode_enable_sequence` (`terminal.zig:4`), which ends in `\x1b[?7l`, disabling
  autowrap. That is correct for the inline composer and wrong for a grid that relies on
  wrapping. Full-screen needs autowrap on, and the sequence must differ by mode.
- **Full-screen must own `owned_top_row == 1` explicitly on enter.** `enterAlternateScreen`
  does not reset it, and no production code sets it to 1 on that path. This is an open
  runtime question; see the questions section. Do not assume the existing screen gets this
  right by accident.

## Keybinding

Deleting Ctrl+O leaves `controlByteFeatureAction` (`escape_parser.zig:268`) mapping only byte
16 (`open_model_catalog`). Bind `/fullscreen` to a bare control byte as well, using byte 20
(Ctrl+T, currently unmapped):

```zig
pub fn controlByteFeatureAction(byte: u8) ?InputEscapeAction {
    return switch (byte) {
        16 => .open_model_catalog,
        20 => .toggle_fullscreen,
        else => null,
    };
}
```

Byte 20 is Ctrl+T and is currently unmapped. A bare control byte is the right choice because
it works under tmux.

Do not add it to `src/ui/input/shortcuts.zig`. That table is the composer editing table and
its test at `:107` explicitly asserts app-level controls are absent.

Dispatch needs a non-`unreachable` branch in the switch at `app_input_runtime.zig:989` and,
if it must run before menu routing, an entry in the early-intercept predicate at `:758`.

A leader key like opencode's `ctrl+x` is deliberately out of scope here. fx has
`escape_meta_mask: u8 = 0x80` as a per-sequence decode stage bit, not a leader-key state
machine, so a prefix with a timeout is genuinely new machinery.

## What breaks if full-screen becomes permanent

Verified call sites that assume the alternate screen is transient:

- **`openFullTranscript` guard, `app_lifecycle.zig:1250`.**
  `if (terminal.alternate_screen_owner != .none and !terminal.fullTranscriptScreenActive())
  return error.AlternateScreenAlreadyOwned`. Reusing the same owner sidesteps this guard
  entirely, which is a second reason to reuse rather than add a fourth owner.
- **`leaveAlternateScreens`, `:1061`.** An exhaustive `switch` releasing every owner on
  shutdown.
- **`handoffFullTranscriptToApproval`, `:1288` and `transitionFullTranscriptForApproval`,
  `:1184`.** Must become routine paths, per the permission section above.
- **`suspendToJobControl`, `:1048` and `normal_exit_restore_prefix`, `:42`.** Ctrl+Z must
  restore the terminal correctly with full-screen active.
- **`requestNormalViewportRecovery`, `app_render_runtime.zig:1943`.** Refuses while any owner
  is active, so it will never fire for the full-screen surface. Fine, but confirm the
  full-screen path has its own recovery.
- **Session scrollback handoff**, `app_session_runtime.zig:1843`, refuses while any owner is
  active.
- **tmux clear, `app_render_runtime.zig:1686`.** Already guarded by
  `alternate_screen_owner == .none`, which is correct. Leave it alone.

## Phases

Each phase is a separate PR that passes Full CI on its own. The order is critical-path order,
not preference.

### Phase 0: the decision

No code. Amend `AGENTS.md:290` and `CONTRIBUTING.md:282` to record that the full-screen chat
surface is toggleable, that it replaces the Ctrl+O reader rather than adding a fourth owner,
and that Ctrl+O is deleted. Resolve the `.catalog_menu` dead-owner question. Confirm that
`/fullscreen` always persists, and record the startup fallback for an invalid stored value.

### Phase 1: live composer

The critical path, and the phase that makes this a product.

- Delete Ctrl+O: the binding, the `.toggle_full_transcript` action, and the reader input gate.
- Tiered input router replacing the boolean `screenOwnsInput` gate.
- Composer painted as a frame band with a cursor in it.
- Composer and footer bands anchored to the bottom of the frame so they do not move during
  scrolling.
- Composer height decoupled from footer reserved-row math.
- Editing state preserved across a toggle.
- Approval handoff treated as a normal path, with exact frame restore on decline.

Exit criteria, testable without a TTY through `resize_tests.zig`:

- Typing in full-screen modifies visible composer rows.
- Submitting a turn renders the user message, streams the response, and renders tool
  activity, all inside the alternate screen with no main-buffer writes.
- The composer row and the footer row do not move during a scroll-only update.
- A permission prompt round-trips in and out with no flicker and no lost composer buffer.
- Toggling mid-edit preserves the draft.
- The toggle writes `~/.fx/settings.json`, and a fresh launch restores the mode.

**Gate: do not start Phase 2 until all six pass.** Without a live composer there is nothing
to put chrome around.

### Phase 2: chrome

Header band, scrollbar gutter, mode indicator, layout math, minimum size floor. Add the
`header` and `gutter` cell owners and fix the twenty-one pairwise overlap checks. Rebuild the
menu mutual-exclusion chain at `surface_frame.zig:404` with a full-screen branch.

### Phase 3: scroll model

Offset-anchored viewport selection, zero newline emission in full-screen, retention ceiling
fix, bookmark survival across pruning. Exit criteria:

- Scrolling lands on stable rows across repeated reflows at several widths.
- A bookmark survives a retention event and lands on the same entry, not the same row.
- Follow-tail resumes at the tail and holds there while new output streams in.
- No physical newline is emitted while scrolled, asserted by comparing bytes written before
  and after a scroll-only frame.
- The composer and footer rows are byte-identical before and after each scroll-only frame.

### Phase 4: the toggle itself

Make `/fullscreen` work at runtime, atomically reconciling buffer, shadow VT, committed
layout, viewport anchor, `owned_top_row`, and composer height. Make Ctrl+T consistent with
the new model. This is the highest-risk phase for the least user-visible gain, because most
users will set the mode once and never toggle it mid-session. If the atomic switch proves too
fragile, ship `/fullscreen` as next-launch-only and say so in the command's help text,
following the `startup_scrollback` precedent. Do not ship a toggle that can desync the shadow
VT.

### Phase 5: remove the reader

Confirm the Ctrl+O deletion is complete. No lingering `.toggle_full_transcript` reference, no
reader-mode input gate, no expanded-view paint path, no help text that mentions it. This is
cleanup and a changelog entry, not a feature.

### Phase 6: opencode parity

Leader key and command palette, persistent theme, scroll speed, cursor style, mouse toggle,
attention notifications, `@` and `!` in the composer.

Note one conflict to settle: opencode binds `ctrl+p` to its command palette, while fx already
binds byte 16 to `.open_model_catalog` ([opencode.ai/docs/tui](https://opencode.ai/docs/tui/)).
Do not silently break either.

## Testing strategy

Every new root `tests/e2e/*.test.ts` file needs exactly one classification in
`scripts/pgso/corpus.json`, and normal PR CI rejects missing, duplicate, stale, or
unclassified files before it runs the expensive PGSO qualification.

Three tiers, in the order AGENTS.md requires:

1. **`src/ui/resize_tests.zig`, using `core/terminal/engine.zig`.** Where resize and render
   regressions belong. Sub-second, no fd, no timing dependence. A tmux or tape repro that
   exposes a bug becomes a Zig unit test here before the fix lands. Phases 1 and 3 should be
   mostly proven at this tier.
2. **tmux E2E.** Real interaction for Phases 2, 4, and 5. Use `resizeWindow(cols, rows)` and
   `capturePaneGrid()` from `tmux-helpers.ts`.
3. **Recorded tape replay.** `FX_DEBUG_RECORD=1` then `fx replay /tmp/bug.fxtape`, with
   `FX_RECORD` for a fixed destination. A golden file can be checked in as a regression test
   and replayed by any reviewer without a TTY.

Phase 1 needs three specific new test classes that do not exist today:

- **Assert no main-buffer bytes are written while full-screen is active.** The existing suites
  cover alternate-screen lifecycle, but nothing asserts the negative case, which is precisely
  the property that makes full-screen safe.
- **Assert the chrome is pinned.** Capture the composer and footer rows, scroll, capture
  again, assert the rows are unchanged.
- **Assert the preference round-trips.** Toggle, tear down, rebuild from the same profile
  directory, assert the mode is restored. `startup_scrollback` is the precedent to copy, and
  the test belongs in the same place its round-trip test lives. This is the check that
  catches a handler that renders correctly and drops the write.

Keep inline working in CI. Inline stays the default, so an inline-only suite would let it rot
silently. Every existing TUI test must pass unchanged, and add a parallel full-screen pass
for behavior that must hold in both modes.

## Risks

| Risk | Why it matters | Mitigation |
| --- | --- | --- |
| Composer routing regression | Tiered routing touches every input path | Phase 1 exit criteria in `resize_tests.zig`; keep the inline router untouched behind a mode flag |
| Preference write silently dropped | A display mode that renders but does not persist is worse than none | Commit-first via `mutationMode`; check `CommitAttempt.failure`; round-trip test in Phase 1 |
| Corrupt stored value blocks startup | A display preference must never prevent launch | Resolve the parse error to "fall back to inline" rather than failing bootstrap |
| Chrome moves during scroll | The user called this out explicitly | Anchor composer and footer bands; assert byte-identical rows across a scroll |
| Shadow VT desync on toggle | It is the only diff baseline | Atomic switch in Phase 4, or ship next-launch-only |
| Approval handoff flicker | Becomes routine rather than rare | Restore scroll, follow-tail, and composer buffer together; add a no-flicker test |
| Retention ceiling surfaces as missing history | Invisible until someone scrolls in a long session | Test scrollback in a long session, not a fresh one |
| Bookmark drift after pruning | Entry ids are not stable across retention | Recompute from items via `refresh_bookmark`, never cache absolute rows |
| Autowrap left disabled | `\x1b[?7l` in the startup sequence is wrong for a grid | Make the mode sequence conditional; resolve before `app_lifecycle.zig:843` |
| Leftover Ctrl+O references | A half-deleted binding is a hidden bug | Phase 5 residue check; `git grep` for `toggle_full_transcript` and `full_transcript` in help text |
| tmux coverage gaps | Kitty-only bindings cannot be tested | Bare control byte for Ctrl+T; raw bytes work under tmux |
| Binary size | PGSO gate is a 7.800 MiB ceiling on macOS arm64 | Each phase is separately measurable via the size workflow |
| `UserPreferenceField` enum ceiling | `enum(u4)` with 12 members leaves 4 slots | Widen to `enum(u5)` when this lands |

## Open questions

1. **Does `owned_top_row` need to be set to 1 explicitly on entering full-screen?**
   `enterAlternateScreen` does not reset it, and no production code sets it to 1 on that
   path. In practice the fresh alternate buffer plus `FrameSurface.initFromShadow` may make
   it moot, and by the time a user opened Ctrl+O it may already have been 1. Needs a runtime
   check, not an assumption. Do not build on it until checked.
2. **Does `/fullscreen` reuse the Ctrl+O enter path exactly?** The Ctrl+O takeover is the
   alternate-screen enter (`enterAlternateScreen`, `src/core/app/app_lifecycle.zig:45`),
   which escalates `alternate_screen_owner` and swaps in the alternate buffer. The
   requirement is read here as reusing that same swap while keeping the session live.
   Confirm before Phase 4 whether the toggle shares the existing owner or adds its own
   variant, so the transition matches Ctrl+O exactly.
3. **Should a live `/fullscreen` toggle exist at all in the first release?** It is the
   riskiest phase for the least gain. Next-launch-only is a legitimate ship.
4. **Does full-screen work under tmux?** The alternate buffer does. Kitty keyboard bindings
   do not, so any modifier-dependent feature needs a legacy CSI mirror or an exclusion.
5. **Sidebar or no sidebar.** opencode has a session list. A two-column layout means a second
   viewport over a different projection plus a focus model. Recommend deferring.
6. **Where do subagent panels live?** They currently render inline. This decides whether
   full-screen needs a second pane.

## Evidence index

Every claim above traces to one of these. All paths are relative to the repository root.

| Claim | Location |
| --- | --- |
| `AlternateScreenOwner` has four variants, one with no production enter path | `src/ui/shell_runtime.zig:57`, `src/core/app/app_lifecycle.zig:1901` |
| Alternate-screen enter sequence | `src/core/app/app_lifecycle.zig:45` |
| Exclusive ownership gate | `src/core/app/app_lifecycle.zig:1337`, `:1351` |
| Ctrl+O guard that reuse sidesteps | `src/core/app/app_lifecycle.zig:1250` |
| Approval handoff between owners | `src/core/app/app_lifecycle.zig:1184`, `:1288` |
| Shutdown owner release, job control, restore prefix | `src/core/app/app_lifecycle.zig:1061`, `:1048`, `:42` |
| Alternate-screen rendering is already generic | `src/core/app/app_render_runtime.zig:1174`, `:1210`, `:1754` |
| tmux clear correctly skipped under an owner | `src/core/app/app_render_runtime.zig:1686` |
| Normal viewport recovery refuses under an owner | `src/core/app/app_render_runtime.zig:1943` |
| Read-only gate that swallows composer input | `src/core/app/input_full_transcript_runtime.zig:30`, `:47`, `:156` |
| Partial composer-routing seam | `src/core/app/input_full_transcript_runtime.zig:54` |
| `PaintPlan` shape and pairwise overlap validation | `src/ui/render_engine/paint_plan.zig:337`, `:356`, `:372` |
| Inline preserved band construction | `src/ui/footer/paint_plan.zig:419` |
| `owned_top_row` anchors viewport init and reanchor | `src/ui/transcript/viewport_runtime.zig:47`, `:106` |
| Composer height derived from footer reserved rows | `src/ui/transcript/viewport_runtime.zig:255` |
| Viewport selection always selects the tail | `src/ui/render_engine/viewport_selection.zig` (`selectTail`) |
| Unused tail viewport seam | `src/ui/transcript/painter.zig:2049` |
| Scroll state machine with anchor and bookmark | `src/core/output/transcript_presentation.zig` |
| Content revision bumps drive full-screen rebuild | `src/ui/transcript/runtime.zig:11453`, `:11466`, `:11479`, `:11493`, `:11506` |
| Request identity ignores revision for surface validity | `src/core/output/full_transcript_page.zig:41`, `:47` |
| Retention pruning is in place and mutates entry ids | `src/ui/transcript/store.zig:944`, `:313` |
| Suppress streaming repaints while scrolled away | `src/ui/transcript/runtime.zig:11444` (`nativeHistoryActive`) |
| Autowrap disabled on startup | `src/ui/terminal/terminal.zig:4`, written at `src/core/app/app_lifecycle.zig:843` |
| Kitty keyboard protocol omitted under tmux | `src/ui/terminal/terminal.zig:5`, `:122` |
| Global key byte mapping, including the byte-15 Ctrl+O branch to delete | `src/ui/input/escape_parser.zig:268` |
| Global action dispatch and early intercept | `src/core/app/app_input_runtime.zig:989`, `:758` |
| Composer-only shortcut table and its exclusion test | `src/ui/input/shortcuts.zig:107` |
| Footer menu mutual exclusion | `src/ui/footer/surface_frame.zig:404` |
| Project config allowlist and profile key filter | `src/core/config/config_runtime.zig:746`, `:1519`, `:1762` |
| Settings merge | `src/core/config/config_runtime.zig:1819` |
| Settings write validation and preference enum | `src/core/config/settings_store.zig:1770`, `:208` |
| Enumerated settings precedent | `src/core/config/settings_catalog.zig:25`, `:270`, `:362` |
| Slash spec shape and kind enum | `src/core/slash_commands/command_specs.zig:144`, `:31`, `:114` |
| Slash registration and order-lock test | `src/builtins/commands.zig:394`, `:472` |
| Persistence precedent: check `CommitAttempt.failure`, report it | `src/core/session/session_commands.zig:592` |
| Commit-first versus runtime-first patch ordering | `src/core/config/settings_store.zig:283` |
| Slash router exhaustive switches | `src/core/slash_commands/command_router.zig:7`, `:74`, `:119` |
| Handler table and settings catalog apply switch | `src/core/app/app_commands.zig:268`, `:2982` |
| Startup composition order | `src/core/app/app_lifecycle.zig:729` |
| Documented inline-only constraint | `AGENTS.md:290`, `CONTRIBUTING.md:282` |
| E2E corpus classification requirement | `scripts/pgso/corpus.json`, `AGENTS.md` |
