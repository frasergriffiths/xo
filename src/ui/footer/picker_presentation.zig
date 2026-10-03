const std = @import("std");
const auth_runtime = @import("../../core/auth/auth_runtime.zig");
const credentials = @import("../../core/auth/credentials.zig");
const picker_state = @import("../../core/input/picker_state.zig");
const command_specs = @import("../../core/slash_commands/command_specs.zig");
const display_width = @import("../../core/shared/display_width.zig");
const list_window = @import("../../core/shared/list_window.zig");
const skill_runtime = @import("../../core/skills/skill_runtime.zig");
const file_index = @import("../../core/workspace/file_index.zig");
const ui_render = @import("../render.zig");
const input_presentation = @import("input_presentation.zig");
const menu_style = @import("menu_style.zig");
const row_text = @import("row_text.zig");
const vt_emulator = @import("../../core/terminal/engine.zig");

const Allocator = std.mem.Allocator;
pub const inline_picker_column_gap_width: usize = 4;

/// The picker has no text query, so the cursor always sits in the composer.
pub fn authPickerQueryCursorColumn(_: auth_runtime.PickerView, _: u16) ?u16 {
    return null;
}

pub fn authPickerRowCount(view: auth_runtime.PickerView) u16 {
    if (view.stage == .api_key) return 4;
    if (view.stage == .base_url) return 3;
    if (view.stage == .root and view.include_skip) return 6;
    if (isSetupListStage(view.stage)) return @intCast(2 + @max(view.choiceCount(), 1));
    return @intCast(1 + @max(view.choiceCount(), 1));
}

fn isSetupListStage(stage: auth_runtime.PickerStage) bool {
    return switch (stage) {
        .root, .connections, .provider, .switch_credential => true,
        .base_url, .api_key => false,
    };
}

fn setupChoiceLabel(view: auth_runtime.PickerView, choice: auth_runtime.Choice) []const u8 {
    return switch (view.stage) {
        .root => switch (choice) {
            .action => |action| switch (action) {
                .setup => "OpenRouter API key",
                .connections => "OpenRouter",
                .switch_credential => "Credential source",
                .switch_provider, .automatic => "",
            },
            .provider, .source => "",
        },
        .connections => switch (choice) {
            .action => |action| switch (action) {
                .setup => "OpenRouter API key",
                .connections, .switch_credential, .switch_provider, .automatic => "",
            },
            .provider, .source => "",
        },
        .provider, .switch_credential => view.choiceLabel(choice),
        .base_url, .api_key => "",
    };
}

fn setupChoiceValue(view: auth_runtime.PickerView, choice: auth_runtime.Choice) []const u8 {
    return switch (view.stage) {
        .root => switch (choice) {
            .action => |action| switch (action) {
                .setup => if (view.active_source != null) view.activeSourceLabel() else "not configured",
                .connections => if (view.available_sources.count() > 0) "connected" else "not connected",
                .switch_credential => if (view.active_source != null)
                    view.activeSourceLabel()
                else
                    "not connected",
                .switch_provider, .automatic => "",
            },
            .provider, .source => "",
        },
        .connections => switch (choice) {
            .action => |action| switch (action) {
                .setup => if (view.available_sources.contains(.stored_key))
                    "stored"
                else if (view.available_sources.contains(.openrouter_api_key))
                    "environment"
                else
                    "not configured",
                .connections, .switch_credential, .switch_provider, .automatic => "",
            },
            .provider, .source => "",
        },
        .provider, .switch_credential => view.choiceDescription(choice),
        .base_url, .api_key => "",
    };
}

fn detailValueColumn(width: u16) usize {
    const width_usize: usize = width;
    const minimum = display_width.visibleWidth("  OpenRouter API key") + 2;
    return @min(width_usize, @max(width_usize * 2 / 3, minimum));
}

fn composeSetupChoiceRow(
    alloc: Allocator,
    view: auth_runtime.PickerView,
    choice: auth_runtime.Choice,
    width: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    if (width == 0) return row;

    const selected = view.choiceIsSelected(choice);
    const enabled = view.choiceEnabled(choice);
    const style = if (selected and enabled) ui_render.selected_completion_style else ui_render.dim_style;
    try row.appendSlice(alloc, style);
    try row.appendSlice(alloc, if (selected and enabled) "› " else "  ");

    const value_col = detailValueColumn(width);
    const label_width = value_col -| 2;
    try row_text.appendSingleLineEllipsized(
        alloc,
        &row,
        setupChoiceLabel(view, choice),
        label_width,
    );
    try row.appendSlice(alloc, ui_render.reset_style);

    if (value_col < width) {
        try row_text.appendSpacesToColumn(alloc, &row, value_col);
        try row.appendSlice(alloc, style);
        try row_text.appendSingleLineEllipsized(
            alloc,
            &row,
            setupChoiceValue(view, choice),
            @as(usize, width) - value_col,
        );
        try row.appendSlice(alloc, ui_render.reset_style);
    }
    return row;
}

fn composeSetupHeaderRow(
    alloc: Allocator,
    view: auth_runtime.PickerView,
    width: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    try row.appendSlice(alloc, ui_render.dim_style);
    const heading = switch (view.stage) {
        .root => "Setup",
        .connections => "OpenRouter",
        .provider => "Model provider",
        .switch_credential => "Credential source",
        .base_url => "Base URL",
        .api_key => unreachable,
    };
    try row_text.appendClipped(alloc, &row, heading, width);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn composeSetupEmptyRow(
    alloc: Allocator,
    view: auth_runtime.PickerView,
    width: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    try row.appendSlice(alloc, ui_render.dim_style);
    try row_text.appendClipped(alloc, &row, switch (view.stage) {
        .provider => "  No providers available",
        .switch_credential => "  No credentials available",
        .root, .connections, .base_url, .api_key => "",
    }, width);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn composeSetupPickerRow(
    alloc: Allocator,
    view: auth_runtime.PickerView,
    row_index: u16,
    row_count: u16,
    width: u16,
) !std.ArrayList(u8) {
    if (width == 0 or row_index >= row_count) return .empty;
    if (row_count == 1) {
        const selected = view.selected_choice orelse return composeSetupEmptyRow(alloc, view, width);
        return composeSetupChoiceRow(alloc, view, selected, width);
    }
    if (row_index == 0) return composeSetupHeaderRow(alloc, view, width);

    const choice_start: u16 = if (row_count >= 3) 2 else 1;
    if (row_index < choice_start) return .empty;
    if (view.choiceCount() == 0) return composeSetupEmptyRow(alloc, view, width);

    const window = pickerWindow(
        view.choiceCount(),
        view.selectedIndex(),
        row_count - choice_start,
    );
    const choice_index = window.start + row_index - choice_start;
    if (choice_index >= window.end) return .empty;
    const choice = view.choiceAt(choice_index) orelse return .empty;
    return composeSetupChoiceRow(alloc, view, choice, width);
}

pub noinline fn composeAuthPickerRow(
    alloc: Allocator,
    view: auth_runtime.PickerView,
    row_index: u16,
    row_count: u16,
    width: u16,
) !std.ArrayList(u8) {
    if (view.stage == .api_key) {
        return composeApiKeyPickerRow(alloc, view.api_key_mask_count, view.api_key_provider_label, row_index, width);
    }
    if (view.stage == .base_url) {
        return composeBaseUrlPickerRow(alloc, view, row_index, width);
    }
    if (isSetupListStage(view.stage)) {
        return composeSetupPickerRow(alloc, view, row_index, row_count, width);
    }
    unreachable;
}

fn composeBaseUrlPickerRow(
    alloc: Allocator,
    view: auth_runtime.PickerView,
    row_index: u16,
    width: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    if (width == 0) return row;
    try row.appendSlice(alloc, if (row_index == 1)
        ui_render.selected_completion_style
    else
        ui_render.dim_style);
    switch (row_index) {
        0 => {
            var title_buf: [96]u8 = undefined;
            const title = std.fmt.bufPrint(&title_buf, "   {s} endpoint", .{view.api_key_provider_label}) catch "   Endpoint";
            try row_text.appendClipped(alloc, &row, title, width);
        },
        1 => {
            try row_text.appendClipped(alloc, &row, "   ┃ ", width);
            if (view.base_url_text.len == 0) {
                try row.appendSlice(alloc, ui_render.dim_style);
                try row_text.appendClipped(alloc, &row, "Enter the base URL, for example https://api.openai.com/v1", width -| 5);
            } else {
                try row_text.appendClipped(alloc, &row, view.base_url_text, width -| 5);
            }
        },
        2 => try row_text.appendClipped(alloc, &row, "   enter accepts · esc cancels", width),
        else => {},
    }
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

const onboarding_note = "   ⚠︎ Note: fx runs in full access. Every tool action is unprompted.";
const onboarding_note_link = onboarding_note ++ " \x1b]8;id=fx-onboarding;https://docs.openrouter.ai/quickstart\x1b\\\x1b[4mLearn more\x1b[24m\x1b]8;;\x1b\\";

fn composeApiKeyPickerRow(
    alloc: Allocator,
    mask_count: usize,
    provider_label: []const u8,
    row_index: u16,
    width: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    if (width == 0) return row;

    try row.appendSlice(alloc, if (row_index == 1)
        ui_render.selected_completion_style
    else
        ui_render.dim_style);
    switch (row_index) {
        0 => {
            var title_buf: [96]u8 = undefined;
            const title = std.fmt.bufPrint(&title_buf, "   Paste your {s} API key", .{provider_label}) catch "   Paste your API key";
            try row_text.appendClipped(alloc, &row, title, width);
        },
        1 => {
            try row_text.appendClipped(alloc, &row, "   ┃ ", width);
            if (mask_count == 0) {
                try row.appendSlice(alloc, ui_render.dim_style);
                var prompt_buf: [96]u8 = undefined;
                const prompt = std.fmt.bufPrint(&prompt_buf, "Paste or type your {s} key", .{provider_label}) catch "Paste or type your key";
                try row_text.appendClipped(alloc, &row, prompt, width -| 5);
            } else {
                for (0..@min(mask_count, width -| 5)) |_| try row.appendSlice(alloc, "•");
            }
        },
        2 => try row_text.appendClipped(alloc, &row, "   enter saves · esc cancels", width),
        3 => {
            var label_buf: [128]u8 = undefined;
            const label = std.fmt.bufPrint(
                &label_buf,
                "   Saves to {s}",
                .{credentials.stored_key_backend_label},
            ) catch "   Saves to configured credential store";
            try row_text.appendClipped(alloc, &row, label, width);
        },
        else => {},
    }
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

pub fn activeListPickerReservedRows(terminal_rows: u16, input_extra: u16, banner_rows: u16) u16 {
    const fixed_rows: u16 = 5 +| input_extra +| banner_rows;
    const available_rows = terminal_rows -| fixed_rows;
    if (available_rows == 0) return 1;
    return @min(input_presentation.max_model_picker_rows, available_rows);
}

pub fn authPickerReservedRows(view: auth_runtime.PickerView, terminal_rows: u16, input_extra: u16, banner_rows: u16) u16 {
    return @min(authPickerRowCount(view), activeListPickerReservedRows(terminal_rows, input_extra, banner_rows));
}

pub const PickerWindow = list_window.Window;

pub fn pickerWindow(count: usize, selected: usize, max_rows: u16) PickerWindow {
    return list_window.centered(count, selected, max_rows);
}

pub fn edgeScrollPickerWindow(count: usize, selected: usize, max_rows: u16) PickerWindow {
    return list_window.edgeFromSelection(count, selected, max_rows);
}

pub fn edgeScrollPickerWindowFromStart(count: usize, start: usize, max_rows: u16) PickerWindow {
    return list_window.edgeFromStart(count, start, max_rows);
}

pub fn updateEdgeScrollPickerWindowStart(current_start: usize, count: usize, selected: usize, max_rows: u16) usize {
    return list_window.updateEdgeStart(current_start, count, selected, max_rows);
}

pub const SlashMenuLayout = struct {
    row_count: u16,
    selectable_rows: u16,
    show_header: bool,
    selected: usize,
    command_count: usize,
    result_count: usize,
    window: PickerWindow,
};

pub fn slashMenuLayout(
    registry: command_specs.SlashRegistry,
    prefix: []const u8,
    skills: []const skill_runtime.Skill,
    selection_index: usize,
    current_window_start: usize,
    terminal_rows: u16,
    input_extra: u16,
    banner_rows: u16,
) ?SlashMenuLayout {
    if (command_specs.argCompletionAnchor(prefix) != 0) return null;
    const command_count = command_specs.slashCompletionCount(registry, prefix);
    const result_count = mixedSlashCompletionCount(registry, prefix, skills);
    return slashMenuLayoutForCounts(
        command_count,
        result_count,
        selection_index,
        current_window_start,
        terminal_rows,
        input_extra,
        banner_rows,
    );
}

pub fn preparedSlashMenuLayout(
    prepared: *const PreparedSlashMenu,
    selection_index: usize,
    current_window_start: usize,
    terminal_rows: u16,
    input_extra: u16,
    banner_rows: u16,
) ?SlashMenuLayout {
    if (command_specs.argCompletionAnchor(prepared.prefix) != 0) return null;
    return slashMenuLayoutForCounts(
        prepared.commandCount(),
        prepared.resultCount(),
        selection_index,
        current_window_start,
        terminal_rows,
        input_extra,
        banner_rows,
    );
}

fn slashMenuLayoutForCounts(
    command_count: usize,
    result_count: usize,
    selection_index: usize,
    current_window_start: usize,
    terminal_rows: u16,
    input_extra: u16,
    banner_rows: u16,
) ?SlashMenuLayout {
    if (result_count == 0) return null;

    const row_budget = inlinePickerRowBudget(terminal_rows, input_extra, banner_rows);
    const show_header = row_budget > 2;
    const header_rows: u16 = if (show_header) 2 else 0;
    const selectable_rows = row_budget - header_rows;
    const selected = selection_index % result_count;
    const window_start = updateEdgeScrollPickerWindowStart(current_window_start, result_count, selected, selectable_rows);
    const window = edgeScrollPickerWindowFromStart(result_count, window_start, selectable_rows);

    return .{
        .row_count = selectable_rows + header_rows,
        .selectable_rows = selectable_rows,
        .show_header = show_header,
        .selected = selected,
        .command_count = command_count,
        .result_count = result_count,
        .window = window,
    };
}

pub fn inlinePickerRowBudget(terminal_rows: u16, input_extra: u16, banner_rows: u16) u16 {
    return inlinePickerRowBudgetCapped(
        terminal_rows,
        input_extra,
        banner_rows,
        input_presentation.max_model_picker_rows + 2,
    );
}

pub fn inlinePickerRowBudgetCapped(
    terminal_rows: u16,
    input_extra: u16,
    banner_rows: u16,
    max_picker_rows: u16,
) u16 {
    const fixed_rows: u16 = 5 +| input_extra +| banner_rows;
    const minimum_transcript_rows: u16 = 5;
    const available_picker_rows = (terminal_rows -| fixed_rows) -| minimum_transcript_rows;
    return @min(max_picker_rows, @max(available_picker_rows, 1));
}

pub noinline fn composePickerOptionRow(
    alloc: Allocator,
    kind: input_presentation.PickerKind,
    start_col: u16,
    item: []const u8,
    selected: bool,
    width: u16,
) !std.ArrayList(u8) {
    return composePickerOptionRowAnnotated(alloc, kind, start_col, item, "", selected, width);
}

const picker_annotation_separator = " · ";

pub noinline fn composePickerOptionRowAnnotated(
    alloc: Allocator,
    kind: input_presentation.PickerKind,
    start_col: u16,
    item: []const u8,
    annotation: []const u8,
    selected: bool,
    width: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    const width_usize: usize = width;
    if (width_usize == 0 or start_col == 0 or start_col > width) return row;

    if (start_col > 1) try row_text.appendAbsoluteColumn(alloc, &row, start_col);
    // Model and model-catalog pickers signal selection by brightness alone,
    // like the question panel; other pickers keep the filled row.
    const selected_style = switch (kind) {
        .model_stage, .provider_stage, .models => ui_render.selected_completion_style,
        .file, .slash, .skills, .help, .settings, .sessions, .workspace, .auth => ui_render.approval_button_inactive_style,
    };
    const base_style = if (selected) selected_style else ui_render.dim_style;
    const available = width_usize - @as(usize, start_col - 1);
    const annotation_width = if (annotation.len == 0)
        0
    else
        display_width.visibleWidth(picker_annotation_separator) + display_width.visibleWidth(annotation);
    const show_annotation = annotation_width > 0 and
        available >= display_width.visibleWidth(item) + annotation_width;
    const label_width = if (show_annotation) available - annotation_width else available;

    try row.appendSlice(alloc, base_style);
    try row_text.appendClipped(alloc, &row, item, @intCast(label_width));
    if (show_annotation) {
        try row.appendSlice(alloc, ui_render.reset_style);
        try row.appendSlice(alloc, ui_render.dim_style);
        try row.appendSlice(alloc, picker_annotation_separator);
        try row.appendSlice(alloc, annotation);
    }
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

pub fn composeFilePickerOptionRow(
    alloc: Allocator,
    start_col: u16,
    item: file_index.SearchResult,
    selected: bool,
    width: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    const width_usize: usize = width;
    if (width_usize == 0 or start_col == 0 or start_col > width) return row;

    if (start_col > 1) try row_text.appendAbsoluteColumn(alloc, &row, start_col);
    const base_style = if (selected) ui_render.approval_button_inactive_style else ui_render.dim_style;
    try row.appendSlice(alloc, base_style);
    try appendFilePickerLabel(
        alloc,
        &row,
        item,
        @intCast(width_usize - @as(usize, start_col - 1)),
        base_style,
    );
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

pub fn composePickerStatusRow(
    alloc: Allocator,
    kind: input_presentation.PickerKind,
    model_stage: picker_state.ModelPickerStage,
    loading: bool,
    failed: bool,
    start_col: u16,
    width: u16,
) !std.ArrayList(u8) {
    return composePickerStatusRowWithProvider(alloc, kind, model_stage, .provider, loading, failed, start_col, width);
}

/// Header row for the provider picker. It uses the same title-plus-tab shape as
/// the skills menu so all catalogs read as one family: a `Providers <count>`
/// title followed by bracketed tabs naming every selectable provider. The
/// header is identical at every stage, with the provider currently being
/// configured bracketed, so Groq stays visible and switchable exactly like
/// OpenRouter instead of the later columns collapsing to one provider and
/// hiding the others. The stage's own rows below say what is being chosen.
pub fn composeProviderPickerTitleRow(
    alloc: Allocator,
    count: usize,
    tabs: []const []const u8,
    active_tab: usize,
    width: u16,
) !std.ArrayList(u8) {
    if (width == 0) return .empty;

    const noun = "Providers";

    var wide: std.ArrayList(u8) = .empty;
    defer wide.deinit(alloc);
    try menu_style.appendTitle(alloc, &wide, noun, count);
    for (tabs, 0..) |label, i| {
        if (label.len == 0) continue;
        try wide.appendSlice(alloc, "  ");
        try menu_style.appendTab(alloc, &wide, label, i == active_tab);
    }
    if (display_width.visibleWidthIgnoringAnsi(wide.items) <= width) {
        return cloneProviderHeaderRow(alloc, wide.items, width);
    }

    // Compact: keep the title plus only the active provider tab.
    var compact: std.ArrayList(u8) = .empty;
    defer compact.deinit(alloc);
    try menu_style.appendTitle(alloc, &compact, noun, count);
    if (active_tab < tabs.len and tabs[active_tab].len != 0) {
        try compact.appendSlice(alloc, "  ");
        try menu_style.appendTab(alloc, &compact, tabs[active_tab], true);
    }
    if (display_width.visibleWidthIgnoringAnsi(compact.items) <= width) {
        return cloneProviderHeaderRow(alloc, compact.items, width);
    }

    compact.clearRetainingCapacity();
    try menu_style.appendTitle(alloc, &compact, noun, count);
    return cloneProviderHeaderRow(alloc, compact.items, width);
}

fn cloneProviderHeaderRow(alloc: Allocator, text: []const u8, width: u16) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    try row_text.appendClipped(alloc, &row, text, width);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

/// Widest option label in `[start, end)`, so the detail column lines up
/// vertically across the visible window exactly like the skills menu's scope
/// column.
pub fn providerCatalogNameColumnWidth(items: []const []const u8, start: usize, end: usize) usize {
    var col: usize = 0;
    const clamped_end = @min(end, items.len);
    var i: usize = @min(start, clamped_end);
    while (i < clamped_end) : (i += 1) {
        col = @max(col, display_width.visibleWidth(items[i]));
    }
    return col;
}

/// One provider picker row, composed exactly like a skills menu row: a `›`
/// selection marker from the shared menu style, the option label, and the
/// human-readable detail snug after one column gap. Rows always start at the
/// left edge, never under the composer token.
pub fn composeProviderCatalogRow(
    alloc: Allocator,
    label: []const u8,
    detail: []const u8,
    selected: bool,
    name_col: usize,
    width: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    if (width == 0) return row;

    const gutter = try menu_style.appendItemPrefix(alloc, &row, selected, width);
    const prefix_width: usize = gutter;
    const content_width: usize = @as(usize, width) -| 1;
    const detail_width = display_width.visibleWidth(detail);
    const show_detail = detail_width > 0 and
        content_width >= prefix_width + name_col + menu_style.column_gap + detail_width;
    const name_budget = if (show_detail)
        name_col
    else
        @as(usize, width) -| prefix_width;

    try row_text.appendSingleLineEllipsized(alloc, &row, label, name_budget);

    if (show_detail) {
        const detail_start = prefix_width + name_col + menu_style.column_gap;
        try row_text.appendSpacesToColumn(alloc, &row, detail_start);
        try row.appendSlice(alloc, detail);
    }
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

pub fn composePickerStatusRowWithProvider(
    alloc: Allocator,
    kind: input_presentation.PickerKind,
    model_stage: picker_state.ModelPickerStage,
    provider_stage: picker_state.ProviderPickerStage,
    loading: bool,
    failed: bool,
    start_col: u16,
    width: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    const width_usize: usize = width;
    if (width_usize == 0 or start_col == 0 or start_col > width) return row;

    if (start_col > 1) try row_text.appendAbsoluteColumn(alloc, &row, start_col);
    try row.appendSlice(alloc, ui_render.dim_style);

    const label = switch (kind) {
        .model_stage => switch (model_stage) {
            .model => if (loading)
                "loading models..."
            else if (failed)
                "unable to load models"
            else
                "no matching models",
            .effort => "no matching effort",
            .fast => "no matching mode",
        },
        .provider_stage => switch (provider_stage) {
            .provider => "No providers found.",
            .method => "No sign-in methods found.",
            .team => if (loading) "Loading teams..." else if (failed) "Unable to load teams." else "No teams found.",
            .key_source => "No key sources found.",
            .base_url => "",
            .api_key => "",
        },
        .models => "no models available",
        .file => if (loading)
            "indexing files..."
        else if (failed)
            "unable to index files"
        else
            "no matching files",
        .slash => unreachable,
        .skills => "no matching skills",
        .help => "no matching commands",
        .settings => "no matching settings",
        .sessions => "no matching sessions",
        .workspace => "No workspace options.",
        .auth => "authentication actions unavailable",
    };

    try row_text.appendClipped(alloc, &row, label, @intCast(width_usize - @as(usize, start_col - 1)));
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn appendFilePickerLabel(
    alloc: Allocator,
    row: *std.ArrayList(u8),
    item: file_index.SearchResult,
    width: u16,
    base_style: []const u8,
) !void {
    const path = item.path;
    const width_usize: usize = width;
    const slash_width: usize = @intFromBool(item.kind == .directory);
    if (display_width.visibleWidth(path) + slash_width <= width_usize) {
        try appendStyledPathRange(alloc, row, item, 0, path.len, base_style);
        if (item.kind == .directory) try row.append(alloc, '/');
        return;
    }

    const basename = std.fs.path.basename(path);
    const basename_start = @intFromPtr(basename.ptr) - @intFromPtr(path.ptr);
    const dirname = std.fs.path.dirname(path) orelse {
        try appendBasenameProjection(alloc, row, item, basename_start, width_usize, base_style);
        return;
    };
    const separator = "/";
    const separator_width = display_width.visibleWidth(separator);
    const minimum_segmented_width = 8;
    if (width_usize < minimum_segmented_width) {
        try appendBasenameProjection(alloc, row, item, basename_start, width_usize, base_style);
        return;
    }

    const directory_budget = @min(display_width.visibleWidth(dirname), @min(@max(width_usize / 3, 3), 12));
    const basename_budget = width_usize - directory_budget - separator_width - slash_width;

    try appendStyledEllipsizedRange(alloc, row, item, 0, dirname.len, directory_budget, .middle, base_style);
    try appendStyledPathRange(alloc, row, item, dirname.len, basename_start, base_style);
    try appendStyledEllipsizedRange(alloc, row, item, basename_start, path.len, basename_budget, .prefix_biased, base_style);
    if (item.kind == .directory) try row.append(alloc, '/');
}

const FileEllipsisPlacement = enum { middle, prefix_biased };

fn appendBasenameProjection(
    alloc: Allocator,
    row: *std.ArrayList(u8),
    item: file_index.SearchResult,
    basename_start: usize,
    width: usize,
    base_style: []const u8,
) !void {
    if (item.kind == .directory) {
        if (width == 0) return;
        if (width > 1) {
            try appendStyledEllipsizedRange(alloc, row, item, basename_start, item.path.len, width - 1, .prefix_biased, base_style);
        }
        try row.append(alloc, '/');
        return;
    }
    try appendStyledEllipsizedRange(alloc, row, item, basename_start, item.path.len, width, .prefix_biased, base_style);
}

fn appendStyledEllipsizedRange(
    alloc: Allocator,
    row: *std.ArrayList(u8),
    item: file_index.SearchResult,
    source_start: usize,
    source_end: usize,
    width: usize,
    placement: FileEllipsisPlacement,
    base_style: []const u8,
) !void {
    if (width == 0 or source_start >= source_end) return;
    const source = item.path[source_start..source_end];
    if (display_width.visibleWidth(source) <= width) {
        try appendStyledPathRange(alloc, row, item, source_start, source_end, base_style);
        return;
    }
    if (width == 1) {
        try row.appendSlice(alloc, "…");
        return;
    }

    const content_width = width - 1;
    const prefix_width, const suffix_width = switch (placement) {
        .middle => .{ (content_width + 1) / 2, content_width / 2 },
        .prefix_biased => .{ content_width - content_width / 4, content_width / 4 },
    };
    const prefix = display_width.prefixByWidth(source, prefix_width);
    const suffix = displaySafeSuffixByWidth(source, suffix_width);
    try appendStyledPathRange(alloc, row, item, source_start, source_start + prefix.len, base_style);
    try row.appendSlice(alloc, "…");
    try appendStyledPathRange(alloc, row, item, source_end - suffix.len, source_end, base_style);
}

fn displaySafeSuffixByWidth(source: []const u8, width: usize) []const u8 {
    const suffix = display_width.suffixByWidth(source, width);
    if (suffix.len == 0 or suffix.len == source.len) return suffix;

    var start: usize = 0;
    while (start < suffix.len) {
        const unit = display_width.displayUnitAt(suffix, start);
        if (unit.cell_width != 0) break;
        start += unit.byte_len;
    }
    return suffix[start..];
}

fn appendStyledPathRange(
    alloc: Allocator,
    row: *std.ArrayList(u8),
    item: file_index.SearchResult,
    source_start: usize,
    source_end: usize,
    base_style: []const u8,
) !void {
    var cursor = source_start;
    for (item.matched_spans) |span| {
        const match_start: usize = span.byte_start;
        const match_end: usize = span.byte_end;
        if (match_end <= source_start) continue;
        if (match_start >= source_end) break;

        const visible_start = @max(match_start, source_start);
        const visible_end = @min(match_end, source_end);
        if (cursor < visible_start) try row.appendSlice(alloc, item.path[cursor..visible_start]);
        try row.appendSlice(alloc, ui_render.bold_style);
        try row.appendSlice(alloc, item.path[visible_start..visible_end]);
        try row.appendSlice(alloc, ui_render.reset_style);
        try row.appendSlice(alloc, base_style);
        cursor = visible_end;
    }
    if (cursor < source_end) try row.appendSlice(alloc, item.path[cursor..source_end]);
}

pub fn slashCompletionCommandColumnWidth(
    registry: command_specs.SlashRegistry,
    prefix: []const u8,
    window: PickerWindow,
) usize {
    var width: usize = 0;
    var match_idx = window.start;
    while (match_idx < window.end) : (match_idx += 1) {
        const label = command_specs.nthSlashCompletionLabel(registry, prefix, match_idx) orelse continue;
        width = @max(width, display_width.visibleWidth(label));
    }
    return width + 2;
}

const MixedSlashCompletionEntry = union(enum) {
    command: usize,
    skill: skill_runtime.Skill,
};

const PreparedSlashMenuEntry = union(enum) {
    command: usize,
    skill: *const skill_runtime.Skill,
};

pub const PreparedSlashMenu = struct {
    registry: command_specs.SlashRegistry = .{},
    prefix: []const u8 = "",
    command_count: usize = 0,
    skill_matches: std.ArrayList(*const skill_runtime.Skill) = .empty,

    pub fn deinit(self: *PreparedSlashMenu, alloc: Allocator) void {
        self.skill_matches.deinit(alloc);
        self.* = .{};
    }

    pub fn commandCount(self: *const PreparedSlashMenu) usize {
        return self.command_count;
    }

    pub fn resultCount(self: *const PreparedSlashMenu) usize {
        return self.command_count + self.skill_matches.items.len;
    }

    fn entryAt(self: *const PreparedSlashMenu, index: usize) ?PreparedSlashMenuEntry {
        if (index < self.command_count) return .{ .command = index };
        const skill_index = index - self.command_count;
        if (skill_index >= self.skill_matches.items.len) return null;
        return .{ .skill = self.skill_matches.items[skill_index] };
    }
};

pub fn prepareSlashMenu(
    alloc: Allocator,
    registry: command_specs.SlashRegistry,
    prefix: []const u8,
    skills: []const skill_runtime.Skill,
) !PreparedSlashMenu {
    var prepared = PreparedSlashMenu{
        .registry = registry,
        .prefix = prefix,
        .command_count = command_specs.slashCompletionCount(registry, prefix),
    };
    errdefer prepared.deinit(alloc);

    if (command_specs.argCompletionAnchor(prefix) != 0 or
        prefix.len == 0 or prefix[0] != '/' or skills.len == 0)
    {
        return prepared;
    }

    try prepared.skill_matches.resize(alloc, skills.len);
    const written = skill_runtime.fillSkillMenuRangeAtQuery(
        skills,
        .all,
        prefix[1..],
        0,
        prepared.skill_matches.items,
    );
    prepared.skill_matches.shrinkRetainingCapacity(written);
    return prepared;
}

pub fn mixedSlashCompletionCount(registry: command_specs.SlashRegistry, prefix: []const u8, skills: []const skill_runtime.Skill) usize {
    const command_count = command_specs.slashCompletionCount(registry, prefix);
    if (command_specs.argCompletionAnchor(prefix) != 0) return command_count;
    if (prefix.len == 0 or prefix[0] != '/') return command_count;
    return command_count + skill_runtime.skillMenuFilterQueryCount(skills, .all, prefix[1..]);
}

pub fn mixedSlashCompletionIsSkill(registry: command_specs.SlashRegistry, prefix: []const u8, skills: []const skill_runtime.Skill, n: usize) bool {
    return switch (mixedSlashCompletionEntry(registry, prefix, skills, n) orelse return false) {
        .command => false,
        .skill => true,
    };
}

pub fn nthMixedSlashCompletionSkill(registry: command_specs.SlashRegistry, prefix: []const u8, skills: []const skill_runtime.Skill, n: usize) ?skill_runtime.Skill {
    return switch (mixedSlashCompletionEntry(registry, prefix, skills, n) orelse return null) {
        .command => null,
        .skill => |skill| skill,
    };
}

pub fn nthMixedSlashCompletionText(registry: command_specs.SlashRegistry, prefix: []const u8, skills: []const skill_runtime.Skill, n: usize) ?[]const u8 {
    return switch (mixedSlashCompletionEntry(registry, prefix, skills, n) orelse return null) {
        .command => |match_idx| command_specs.nthSlashCompletion(registry, prefix, match_idx),
        .skill => |skill| skill.name,
    };
}

pub fn mixedSlashCompletionCommandColumnWidth(
    registry: command_specs.SlashRegistry,
    prefix: []const u8,
    skills: []const skill_runtime.Skill,
    window: PickerWindow,
) usize {
    var width: usize = 0;
    var match_idx = window.start;
    while (match_idx < window.end) : (match_idx += 1) {
        const label = mixedSlashCompletionLabel(registry, prefix, skills, match_idx) orelse continue;
        width = @max(width, display_width.visibleWidth(label));
    }
    return width + 2;
}

fn mixedSlashCompletionEntry(registry: command_specs.SlashRegistry, prefix: []const u8, skills: []const skill_runtime.Skill, n: usize) ?MixedSlashCompletionEntry {
    const command_count = command_specs.slashCompletionCount(registry, prefix);
    if (n < command_count) return .{ .command = n };
    if (command_specs.argCompletionAnchor(prefix) != 0) return null;
    if (prefix.len == 0 or prefix[0] != '/') return null;
    const skill = skill_runtime.skillMenuSkillAtQuery(skills, .all, prefix[1..], n - command_count) orelse return null;
    return .{ .skill = skill };
}

fn mixedSlashCompletionLabel(registry: command_specs.SlashRegistry, prefix: []const u8, skills: []const skill_runtime.Skill, n: usize) ?[]const u8 {
    return switch (mixedSlashCompletionEntry(registry, prefix, skills, n) orelse return null) {
        .command => |match_idx| command_specs.nthSlashCompletionLabel(registry, prefix, match_idx),
        .skill => |skill| skill.name,
    };
}

pub fn composeSlashMenuHeaderRow(
    alloc: Allocator,
    prefix: []const u8,
    layout: SlashMenuLayout,
    width: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    if (width == 0) return row;

    const noun = if (layout.command_count == layout.result_count) "Commands" else "Results";
    var left_buf: [96]u8 = undefined;
    const left = if (std.mem.eql(u8, prefix, "/"))
        std.fmt.bufPrint(&left_buf, "{s} {d} · type to filter", .{ noun, layout.result_count }) catch noun
    else
        std.fmt.bufPrint(&left_buf, "{s} {d}", .{ noun, layout.result_count }) catch noun;

    var range_buf: [48]u8 = undefined;
    const range = if (layout.result_count > layout.selectable_rows)
        std.fmt.bufPrint(&range_buf, "{d}–{d}", .{ layout.window.start + 1, layout.window.end }) catch ""
    else
        "";

    const content_width: usize = @as(usize, width) -| 1;
    const range_width = display_width.visibleWidth(range);
    const left_width = if (range_width > 0 and content_width > range_width + 2)
        content_width - range_width - 2
    else
        content_width;

    try row.appendSlice(alloc, ui_render.dim_style);
    try row_text.appendSingleLineEllipsized(alloc, &row, left, left_width);
    if (range_width > 0 and content_width > range_width + 2) {
        try appendSpacesToVisibleWidth(alloc, &row, content_width - range_width);
        try row.appendSlice(alloc, range);
    }
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

const SlashMenuRowContent = struct {
    label: []const u8,
    description: []const u8,
    metadata: []const u8,
};

pub const SlashMenuColumnWidths = struct {
    label: usize,
    metadata: usize,
};

fn slashMenuRowContent(
    registry: command_specs.SlashRegistry,
    prefix: []const u8,
    skills: []const skill_runtime.Skill,
    match_idx: usize,
    include_metadata: bool,
) ?SlashMenuRowContent {
    return switch (mixedSlashCompletionEntry(registry, prefix, skills, match_idx) orelse return null) {
        .command => |command_idx| .{
            .label = command_specs.nthSlashCompletionLabel(registry, prefix, command_idx) orelse return null,
            .description = command_specs.nthSlashCompletionDescription(registry, prefix, command_idx) orelse "",
            .metadata = if (include_metadata)
                if (command_specs.nthSlashCompletionCategory(registry, prefix, command_idx)) |category| category.label() else ""
            else
                "",
        },
        .skill => |skill| .{
            .label = skill.name,
            .description = skill.description,
            .metadata = if (include_metadata) skill_runtime.skillSourceShortLabel(skill.source) else "",
        },
    };
}

fn preparedSlashMenuRowContent(
    prepared: *const PreparedSlashMenu,
    match_idx: usize,
    include_metadata: bool,
) ?SlashMenuRowContent {
    return switch (prepared.entryAt(match_idx) orelse return null) {
        .command => |command_idx| .{
            .label = command_specs.nthSlashCompletionLabel(prepared.registry, prepared.prefix, command_idx) orelse return null,
            .description = command_specs.nthSlashCompletionDescription(prepared.registry, prepared.prefix, command_idx) orelse "",
            .metadata = if (include_metadata)
                if (command_specs.nthSlashCompletionCategory(prepared.registry, prepared.prefix, command_idx)) |category| category.label() else ""
            else
                "",
        },
        .skill => |skill| .{
            .label = skill.name,
            .description = skill.description,
            .metadata = if (include_metadata) skill_runtime.skillSourceShortLabel(skill.source) else "",
        },
    };
}

pub fn mixedSlashMenuColumnWidths(
    registry: command_specs.SlashRegistry,
    prefix: []const u8,
    skills: []const skill_runtime.Skill,
    window: PickerWindow,
    include_metadata: bool,
) SlashMenuColumnWidths {
    var widths: SlashMenuColumnWidths = .{ .label = 0, .metadata = 0 };
    var match_idx = window.start;
    while (match_idx < window.end) : (match_idx += 1) {
        const content = slashMenuRowContent(registry, prefix, skills, match_idx, include_metadata) orelse continue;
        widths.label = @max(widths.label, display_width.visibleWidth(content.label));
        widths.metadata = @max(widths.metadata, display_width.visibleWidth(content.metadata));
    }
    return widths;
}

pub fn preparedSlashMenuColumnWidths(
    prepared: *const PreparedSlashMenu,
    window: PickerWindow,
    include_metadata: bool,
) SlashMenuColumnWidths {
    var widths: SlashMenuColumnWidths = .{ .label = 0, .metadata = 0 };
    var match_idx = window.start;
    while (match_idx < window.end) : (match_idx += 1) {
        const content = preparedSlashMenuRowContent(prepared, match_idx, include_metadata) orelse continue;
        widths.label = @max(widths.label, display_width.visibleWidth(content.label));
        widths.metadata = @max(widths.metadata, display_width.visibleWidth(content.metadata));
    }
    return widths;
}

pub noinline fn composeSlashMenuOptionRow(
    alloc: Allocator,
    registry: command_specs.SlashRegistry,
    prefix: []const u8,
    skills: []const skill_runtime.Skill,
    match_idx: usize,
    selected: bool,
    column_widths: SlashMenuColumnWidths,
    width: u16,
    include_metadata: bool,
) !std.ArrayList(u8) {
    const content = slashMenuRowContent(registry, prefix, skills, match_idx, include_metadata) orelse return .empty;
    return composeSlashMenuRow(alloc, content, selected, column_widths, width);
}

pub noinline fn composePreparedSlashMenuOptionRow(
    alloc: Allocator,
    prepared: *const PreparedSlashMenu,
    match_idx: usize,
    selected: bool,
    column_widths: SlashMenuColumnWidths,
    width: u16,
    include_metadata: bool,
) !std.ArrayList(u8) {
    const content = preparedSlashMenuRowContent(prepared, match_idx, include_metadata) orelse return .empty;
    return composeSlashMenuRow(alloc, content, selected, column_widths, width);
}

fn composeSlashMenuRow(
    alloc: Allocator,
    content: SlashMenuRowContent,
    selected: bool,
    column_widths: SlashMenuColumnWidths,
    width: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    if (width == 0) return row;

    // Selection is signaled by brightness alone (like the model picker); no
    // caret marker. The two-column indent stays fixed so rows stay aligned.
    try row.appendSlice(alloc, if (selected) ui_render.selected_completion_style else ui_render.dim_style);
    try row.appendSlice(alloc, "  ");

    const content_width: usize = @as(usize, width) -| 1;
    const marker_width: usize = 2;
    if (content_width <= marker_width) {
        try row.appendSlice(alloc, ui_render.reset_style);
        return row;
    }
    try row_text.appendSingleLineEllipsized(alloc, &row, content.label, content_width - marker_width);

    const label_width = display_width.visibleWidth(content.label);
    const column_gap: usize = 3;
    const description_start = @min(content_width, marker_width + @max(column_widths.label, label_width) + column_gap);
    try appendSpacesToVisibleWidth(alloc, &row, description_start);

    const metadata_width = display_width.visibleWidth(content.metadata);
    const min_description_width: usize = 24;
    const metadata_start = content_width -| column_widths.metadata;
    const metadata_fits = metadata_width > 0 and column_widths.metadata > 0 and column_widths.metadata <= content_width;
    const show_metadata = if (content.description.len > 0)
        metadata_fits and metadata_start >= description_start + min_description_width + column_gap
    else
        metadata_fits and metadata_start >= description_start + column_gap;
    const description_width = if (show_metadata)
        metadata_start - description_start - column_gap
    else
        content_width - description_start;

    if (content.description.len > 0 and description_width > 0) {
        try row.appendSlice(alloc, ui_render.dim_style);
        try row_text.appendSingleLineEllipsized(alloc, &row, content.description, description_width);
    }
    if (show_metadata) {
        try appendSpacesToVisibleWidth(alloc, &row, metadata_start);
        try row.appendSlice(alloc, ui_render.dim_style);
        try row.appendSlice(alloc, content.metadata);
    }
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn appendSpacesToVisibleWidth(alloc: Allocator, row: *std.ArrayList(u8), target_width: usize) !void {
    var visible = display_width.visibleWidthIgnoringAnsi(row.items);
    while (visible < target_width) : (visible += 1) try row.append(alloc, ' ');
}

pub fn composeSlashCompletionOptionRow(
    alloc: Allocator,
    registry: command_specs.SlashRegistry,
    prefix: []const u8,
    match_idx: usize,
    selected: bool,
    start_col: u16,
    command_width: usize,
    width: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    const width_usize: usize = width;
    if (width_usize == 0) return row;

    const label = command_specs.nthSlashCompletionLabel(registry, prefix, match_idx) orelse return row;
    const description = command_specs.nthSlashCompletionDescription(registry, prefix, match_idx) orelse "";
    const label_col: u16 = if (start_col > 1) start_col else 3;
    if (label_col > 1) try row_text.appendAbsoluteColumn(alloc, &row, label_col);

    const before_label_width: usize = label_col - 1;
    if (before_label_width >= width_usize) return row;
    const remaining: u16 = @intCast(width_usize - before_label_width);

    try row.appendSlice(alloc, if (selected) ui_render.selected_completion_style else ui_render.dim_style);
    try row_text.appendClipped(alloc, &row, label, remaining);
    try row.appendSlice(alloc, ui_render.reset_style);

    var visible = display_width.visibleWidth(label);
    while (visible < command_width and before_label_width + visible < width_usize) : (visible += 1) {
        try row.append(alloc, ' ');
    }

    if (description.len > 0 and before_label_width + visible < width_usize) {
        try row.appendSlice(alloc, ui_render.dim_style);
        const desc_remaining: u16 = @intCast(width_usize - before_label_width - visible);
        try row_text.appendClipped(alloc, &row, description, desc_remaining);
        try row.appendSlice(alloc, ui_render.reset_style);
    }

    return row;
}

pub fn composeMixedSlashCompletionOptionRow(
    alloc: Allocator,
    registry: command_specs.SlashRegistry,
    prefix: []const u8,
    skills: []const skill_runtime.Skill,
    match_idx: usize,
    selected: bool,
    start_col: u16,
    command_width: usize,
    width: u16,
) !std.ArrayList(u8) {
    return switch (mixedSlashCompletionEntry(registry, prefix, skills, match_idx) orelse return .empty) {
        .command => |command_idx| composeSlashCompletionOptionRow(alloc, registry, prefix, command_idx, selected, start_col, command_width, width),
        .skill => |skill| composeSkillCompletionOptionRow(alloc, skill, selected, start_col, command_width, width),
    };
}

fn composeSkillCompletionOptionRow(
    alloc: Allocator,
    skill: skill_runtime.Skill,
    selected: bool,
    start_col: u16,
    command_width: usize,
    width: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    const width_usize: usize = width;
    if (width_usize == 0) return row;

    const label_col: u16 = if (start_col > 1) start_col else 3;
    if (label_col > 1) try row_text.appendAbsoluteColumn(alloc, &row, label_col);

    const before_label_width: usize = label_col - 1;
    if (before_label_width >= width_usize) return row;
    const remaining: u16 = @intCast(width_usize - before_label_width);

    try row.appendSlice(alloc, if (selected) ui_render.selected_completion_style else ui_render.dim_style);
    try row_text.appendClipped(alloc, &row, skill.name, remaining);
    try row.appendSlice(alloc, ui_render.reset_style);

    var visible = display_width.visibleWidth(skill.name);
    while (visible < command_width and before_label_width + visible < width_usize) : (visible += 1) {
        try row.append(alloc, ' ');
    }

    const source = skill_runtime.skillSourceShortLabel(skill.source);
    if (before_label_width + visible < width_usize) {
        try row.appendSlice(alloc, ui_render.dim_style);
        const desc_remaining: u16 = @intCast(width_usize - before_label_width - visible);
        try row_text.appendClipped(alloc, &row, source, desc_remaining);
        try row.appendSlice(alloc, ui_render.reset_style);
    }

    return row;
}

const picker_test_slash_specs = [_]command_specs.SlashSpec{
    .{ .kind = .help, .command = "/help", .help_entry = "/help", .completion_description = "show available slash commands", .presentation_category = .general },
    .{ .kind = .clear_screen, .command = "/clear", .help_entry = "/clear", .completion_description = "clear the terminal transcript", .presentation_category = .general },
    .{ .kind = .model, .command = "/model", .help_entry = "/model <id-or-query>", .completion_description = "choose what model and reasoning effort to use", .presentation_category = .model, .has_args = true },
    .{ .kind = .trace, .command = "/trace", .help_entry = "/trace", .completion_description = "copy a private diagnostic trace", .presentation_category = .product },
    .{ .kind = .settings, .command = "/settings", .aliases = &.{"/set"}, .help_entry = "/settings", .completion_description = "configure fx", .presentation_category = .general },
};
const picker_test_slash_registry = command_specs.SlashRegistry{ .commands = picker_test_slash_specs[0..] };

fn expectOrderedSubstrings(haystack: []const u8, needles: []const []const u8) !void {
    var offset: usize = 0;
    for (needles) |needle| {
        const relative = std.mem.find(u8, haystack[offset..], needle) orelse return error.TestUnexpectedResult;
        offset += relative + needle.len;
    }
}
