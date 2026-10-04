# Phase 0 decisions: full-screen TUI mode for fx

The Phase 0 record for `docs/plans/full-screen-tui-mode.md`. The plan required
these decisions to be made and recorded before any feature code lands. Nothing
here changes behavior; it fixes the choices the plan left open and corrects one
of its assumptions.

## Resolved

**1. Does `owned_top_row` need to be set to 1 explicitly on enter?**

Unresolved by the plan, and deliberately left unresolved. It needs a runtime
observation against the real alternate buffer, not a static answer. Phase 1
must observe it before any code depends on it. Do not assume the existing
reader got this right by accident.

**2. Does `/fullscreen` reuse the Ctrl+O enter path exactly?**

Yes. It reuses the same owner slot and the same alternate-screen enter that the
reader used. That reuses `enterAlternateScreen` directly, which is why it is a
rename of an existing owner and not a fourth owner class. It sidesteps the
`openFullTranscript` guard at `app_lifecycle.zig` that refuses to open while
another owner is active.

**3. Should a live mid-session `/fullscreen` toggle exist in the first release?**

No. `/fullscreen` ships next-launch-only first, following the
`startup_scrollback` precedent. The reason is the plan's own risk table: the
atomic switch reconciles the alternate buffer, shadow VT state, committed
layout destination, viewport anchor, `owned_top_row`, composer height, and the
terminal mode sequence, and any ordering mistake leaves a desynced frame. A
display mode is not worth that risk in its first release. A live toggle is
reachable later once the surface is proven.

Because the first release is next-launch-only, the autowrap question is
resolved for Phase 1: `enableInteractiveTerminalModes` ends in `\x1b[?7l`, which
is correct for the inline composer. The full-screen grid needs autowrap on, so
the mode sequence must become conditional before the surface can enter it.

**4. Does full-screen work under tmux?**

The alternate buffer does. Kitty keyboard bindings do not, so anything
modifier-dependent needs a legacy CSI mirror or an explicit exclusion. Phase 1
binds Ctrl+T, a bare control byte, because raw control bytes work under tmux.

**5. Sidebar or no sidebar.**

No sidebar. A two-column layout means a second viewport over a different
projection plus a focus model, and Phase 1 needs a working live composer before
any of that is worth building.

**6. Where do subagent panels live?**

Deferred. They render inline for now. In full-screen they remain inline until
the core surface is proven, because a second pane is not justified before the
first pane is live.

**`.catalog_menu` dead-owner question.** The plan asked whether this owner was
mid-migration or never wired. It is never wired: `enterCatalogMenuScreen` has no
production caller. Its only exit paths are in `app_render_runtime.zig`, which
call `leaveCatalogMenuScreen` defensively. Do not add surface area to an enum
that overstates its contents, and do not wire it speculatively. It is out of
scope for this plan.

**Malformed stored value.** The plan required an invalid `fullscreen` value to
resolve to "fall back to inline." fx does not do that for any preference. With
`{"startup_scrollback": "nonsense"}`, `{"fast_mode": 1}`, or
`{"slash_menu_categories": "x"}` in `~/.fx/settings.json`, fx exits 0 and writes
`fx: config user: malformed_settings` to stderr. `/fullscreen` matches that. A
diagnostic naming the file beats a silently reverted preference, and a second
inconsistent rule for one key would be worse than either.

## Corrections to the plan

**The plan's verification tier does not exist.** It designates
`src/ui/resize_tests.zig` as tier-one coverage and writes all six Phase 1 exit
criteria against that file. That file held 5,356 lines of test helpers with zero
`test` blocks and was imported by nothing, so none of it ever compiled or ran.
It was removed in `6f50d1ee`. The plan's confidence in its own coverage was
built on a suite that could not have executed.

Replacement tier lives in `tests/vt_engine.zig`, imported from `tests.zig`, and
is verified to fail when a test in it fails. Two of its tests are the substrate
the full-screen exit criteria need: alternate-buffer isolation across
`?1049h`/`?1049l`, and a scroll leaving untouched rows byte-identical.

**Doc commands and CI test shape.** The plan's testing strategy references
`tests/e2e/*.test.ts`, `tmux-helpers.ts`, and a per-file classification in
`scripts/pgso/corpus.json`. There is no JavaScript or TypeScript in this tree
and no `tests/e2e/` directory. There are no E2E workflows. Any E2E work is
Zig-based or tmux-driven, not a TypeScript harness.

## Where the first release stops

Phase 1 through Phase 5 land. Phase 6 (opencode parity: leader key, command
palette, persistent theme, scroll speed, cursor style, mouse toggle,
attention notifications, `@` and `!` in the composer) is not part of this plan.

One conflict to settle if Phase 6 happens: opencode binds `ctrl+p` to its
command palette, and fx binds byte 16 to the model catalog. Do not silently
break either.