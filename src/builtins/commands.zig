const std = @import("std");
const command_specs = @import("../core/slash_commands/command_specs.zig");

const Allocator = std.mem.Allocator;

pub const TopLevelKind = command_specs.TopLevelKind;
pub const TopLevelSpec = command_specs.TopLevelSpec;
pub const TopLevelHelpGroup = command_specs.TopLevelHelpGroup;
pub const TopLevelFlag = command_specs.TopLevelFlag;
pub const TopLevelExample = command_specs.TopLevelExample;
pub const TopLevelResource = command_specs.TopLevelResource;
pub const TopLevelRegistry = command_specs.TopLevelRegistry;
pub const HelpStyle = command_specs.HelpStyle;
pub const SlashKind = command_specs.SlashKind;
pub const SlashPresentationCategory = command_specs.SlashPresentationCategory;
pub const SlashSpec = command_specs.SlashSpec;
pub const SlashRegistry = command_specs.SlashRegistry;

const json_option = command_specs.OptionDoc{ .flag = "--json", .description = "Emit machine-readable JSON instead of text" };

pub const top_level_specs = [_]TopLevelSpec{
    .{
        .kind = .help,
        .token = "help",
        .aliases = &.{ "--help", "-h" },
        .usage = "help",
        .summary = "Show this help",
    },
    .{
        .kind = .pr,
        .token = "pr",
        .usage = "pr [--auto] [--create] [context]",
        .summary = "Draft or publish a pull request",
        .options = &.{
            .{ .flag = "--auto", .description = "Automatically review unresolved permission requests" },
            .{ .flag = "--create", .description = "Publish the drafted pull request via the GitHub CLI" },
        },
        .details = &.{
            "Must run inside a git repository. Without --create, the drafted PR is printed only.",
        },
    },
    .{
        .kind = .issue,
        .token = "issue",
        .usage = "issue [--auto] [--create] [context]",
        .summary = "Draft or publish a GitHub issue",
        .options = &.{
            .{ .flag = "--auto", .description = "Automatically review unresolved permission requests" },
            .{ .flag = "--create", .description = "Publish the drafted issue via the GitHub CLI" },
        },
    },
    .{
        .kind = .setup,
        .token = "setup",
        .usage = "setup",
        .summary = "Save a model provider API key",
    },
    .{
        .kind = .status,
        .token = "status",
        .usage = "status [--json]",
        .summary = "Show configuration and runtime information",
        .options = &.{json_option},
    },
    .{
        .kind = .models,
        .token = "models",
        .usage = "models [--json]",
        .summary = "List available models",
        .options = &.{json_option},
    },
    .{
        .kind = .provider,
        .token = "provider",
        .usage = "provider",
        .summary = "Connect fx to a model provider with an API key",
        .details = &.{
            "Running fx provider with no arguments opens the provider picker. Choose OpenRouter, Groq, or OpenAI-compatible, then paste or type that provider's API key and press enter; fx saves it to the macOS Keychain.",
            "You can also set OPENROUTER_API_KEY, GROQ_API_KEY, or FX_OPENAI_COMPATIBLE_API_KEY in the environment instead of saving a key.",
        },
    },
    .{
        .kind = .doctor,
        .token = "doctor",
        .usage = "doctor [--json]",
        .summary = "Run local health and preflight checks",
        .options = &.{json_option},
    },
    .{
        .kind = .session,
        .token = "session",
        .usage = "session <last|id>|--id <id> [--json] | session resume [last|<id>] | session resume --id <id> | session migrate <id>|--id <id> [--allow-large] [--json] | session recover <id>|--id <id> [--json]",
        .summary = "Inspect, resume, migrate, or recover saved sessions",
        .options = &.{
            .{ .flag = "last", .description = "Inspect the current workspace session" },
            .{ .flag = "--id <id>", .description = "Inspect a saved session by exact id" },
            .{ .flag = "resume [last|<id>]", .description = "Resume the latest workspace session or a session by id" },
            .{ .flag = "migrate <id>", .description = "Migrate a saved session to the current format" },
            .{ .flag = "recover <id>", .description = "Copy a recoverable corrupt session into a new session" },
            .{ .flag = "--allow-large", .description = "Permit migrating an oversized session" },
            json_option,
        },
    },
    .{
        .kind = .sessions,
        .token = "sessions",
        .usage = "sessions [--all] [--limit <1-100>] [--cursor <cursor>] [--json]",
        .summary = "List saved sessions for the current workspace",
        .options = &.{
            .{ .flag = "--all", .description = "List saved sessions across every workspace in this profile" },
            .{ .flag = "--limit <1-100>", .description = "Set the maximum sessions returned per page" },
            .{ .flag = "--cursor <cursor>", .description = "Continue from a prior sessions result" },
            json_option,
        },
    },
    .{
        .kind = .@"resume",
        .token = "resume",
        .aliases = &.{ "--resume", "--resume-last", "--continue", "-c", "-r" },
        .hidden_from_top_level_help = true,
        .usage = "session resume [last|<id>] | session resume --id <id> | --resume [last|<id>] | resume [last|<id>] | resume --id <id> | --resume-last | --continue | -c | -r | --resume-<id>",
        .summary = "Continue a saved interactive session",
        .options = &.{
            .{ .flag = "-r", .description = "Choose the session to resume from a picker" },
            .{ .flag = "last", .description = "Resume the most recent session" },
            .{ .flag = "<id>", .description = "Resume a session by id" },
            .{ .flag = "--id <id>", .description = "Resume a session by exact id" },
        },
    },
    .{
        .kind = .usage,
        .token = "usage",
        .usage = "usage [--period <24h|7d|30d>] [--json]",
        .summary = "Show local fx token usage and spend",
        .options = &.{
            .{ .flag = "--period <24h|7d|30d>", .description = "Select a rolling window (default: 30d)" },
            json_option,
        },
        .details = &.{
            "Reports only usage recorded by fx on this machine.",
            "This command reads local state and never queries a remote account.",
        },
    },
    .{
        .kind = .upgrade,
        .token = "upgrade",
        .usage = "upgrade [--channel <stable|dev>] [--json]",
        .summary = "Upgrade 𝒇x on the selected release channel",
        .options = &.{
            .{ .flag = "--channel <stable|dev>", .description = "Select and remember the release channel" },
            json_option,
        },
    },
    .{
        .kind = .replay,
        .token = "replay",
        .usage = "replay <tape> [--frames] [--json] [--golden <path>] [--frames-dir <path>]",
        .summary = "Replay a recorded terminal session",
        .hidden_from_top_level_help = true,
        .options = &.{
            .{ .flag = "--frames", .description = "Render each captured frame" },
            .{ .flag = "--golden <path>", .description = "Write the final rendered grid to a file" },
            .{ .flag = "--frames-dir <path>", .description = "Write rendered frames to a directory" },
            json_option,
        },
    },
    .{
        .kind = .workspace,
        .token = "workspace",
        .usage = "workspace [list|add PATH|remove PATH|clear] [--json]",
        .summary = "Manage additional workspace directories",
        .options = &.{
            .{ .flag = "list", .description = "List the primary and additional directories (default)" },
            .{ .flag = "add PATH", .description = "Persist an existing additional directory" },
            .{ .flag = "remove PATH", .description = "Remove an additional directory" },
            .{ .flag = "clear", .description = "Remove all additional directories" },
            json_option,
        },
        .details = &.{
            "Additional directories are stored for the current primary workspace.",
        },
    },
};

pub const top_level_help_default_width = command_specs.top_level_help_default_width;
pub const top_level_help_fast_buffer_bytes: usize = 32 * 1024;

pub const top_level_help_groups = [_]TopLevelHelpGroup{
    .{ .entries = &.{
        .{ .kind = .pr, .usage = "pr [context]" },
        .{ .kind = .issue, .usage = "issue [context]" },
    } },
    .{ .entries = &.{
        .{ .kind = .sessions, .usage = "sessions" },
        .{ .kind = .session, .usage = "session <last|id>" },
        .{ .usage = "session resume [last|id]", .summary = "Resume the latest workspace session or a session by id" },
        .{ .usage = "session migrate <id>", .summary = "Migrate a saved session to the current format" },
        .{ .usage = "session recover <id>", .summary = "Copy a recoverable corrupt session" },
    } },
    .{ .entries = &.{
        .{ .kind = .provider, .usage = "provider", .summary = "Connect fx to a model provider with an API key" },
        .{ .kind = .models, .usage = "models" },
    } },
    .{ .entries = &.{
        .{ .kind = .setup, .usage = "setup", .summary = "Save a model provider API key" },
    } },
    .{ .entries = &.{
        .{ .kind = .usage, .usage = "usage [--period <24h|7d|30d>]", .summary = "Show locally recorded token usage and spend" },
    } },
    .{ .entries = &.{
        .{ .kind = .status, .usage = "status" },
        .{ .kind = .doctor, .usage = "doctor" },
        .{ .kind = .workspace, .usage = "workspace" },
        .{ .kind = .upgrade, .usage = "upgrade", .summary = "Upgrade fx on the selected release channel" },
        .{ .kind = .help, .usage = "help" },
    } },
};

pub const top_level_flags = [_]TopLevelFlag{
    .{
        .usage = "--context-limit <spec>",
        .description = "Set name=bytes|off; repeatable",
    },
    .{
        .usage = "--add-dir <path>",
        .description = "Add a workspace directory; repeatable",
    },
    .{
        .usage = "--no-additional-dirs",
        .description = "Ignore saved additional directories",
    },
    .{
        .usage = "--provider <name>",
        .description = "Override the model provider for an interactive session (openrouter or a configured name)",
    },
    .{
        .usage = "--model <id>",
        .description = "Override the model for an interactive session",
    },
    .{
        .usage = "--effort <level>",
        .description = "Override the reasoning effort for an interactive session",
    },
    .{
        .usage = "--fast, --no-fast",
        .description = "Turn Fast mode on or off for an interactive session",
    },
    .{
        .usage = "-c, --continue",
        .description = "Resume the remembered workspace session",
    },
    .{
        .usage = "-r",
        .description = "Open the saved-session picker",
    },
    .{
        .usage = "--resume [last|<id>]",
        .description = "Resume the latest workspace session or an exact ID",
    },
    .{
        .usage = "--resume-last",
        .description = "Resume the latest workspace session",
    },
    .{
        .usage = "--resume-<id>",
        .description = "Resume a session by exact ID",
    },
    .{
        .usage = "-h, --help",
        .description = "Display this help and exit",
    },
    .{
        .usage = "-v, --version",
        .description = "Print the fx version and exit",
    },
};

pub const top_level_examples = [_]TopLevelExample{
    .{ .command = "fx", .description = "Start a fresh interactive session" },
    .{ .command = "fx session resume last", .description = "Continue the latest session for this workspace" },
    .{ .command = "fx status --json", .description = "Inspect the current configuration as JSON" },
};

pub const top_level_notes = [_][]const u8{
    "Run `fx <command> --help` for command-specific usage and options.",
    "Run `/help` inside an interactive session for slash commands.",
};

pub const top_level_resources = [_]TopLevelResource{
    .{ .label = "Learn more about fx:", .value = "https://fx.sh/docs", .link = true },
    .{ .label = "Report a problem:", .value = "run `/trace` inside fx" },
};

pub const top_level_registry = TopLevelRegistry{
    .specs = top_level_specs[0..],
    .description = "Fast, native coding agent for the terminal.",
    .interactive_hint = "fx starts an interactive session. Type your request at the prompt.",
    .help_groups = top_level_help_groups[0..],
    .flags = top_level_flags[0..],
    .examples = top_level_examples[0..],
    .notes = top_level_notes[0..],
    .resources = top_level_resources[0..],
};

pub fn matchesTopLevel(token: []const u8, kind: TopLevelKind) bool {
    return command_specs.matchesTopLevel(top_level_registry, token, kind);
}

pub fn renderTopLevelHelp(alloc: Allocator, columns: usize, version: []const u8) ![]u8 {
    return command_specs.renderTopLevelHelp(alloc, top_level_registry, columns, version);
}

pub fn renderTopLevelHelpWithStyle(alloc: Allocator, columns: usize, version: []const u8, style: HelpStyle) ![]u8 {
    return command_specs.renderTopLevelHelpWithStyle(alloc, top_level_registry, columns, version, style);
}

pub fn renderTopLevelCommandHelp(alloc: Allocator, kind: TopLevelKind) ![]u8 {
    return command_specs.renderTopLevelCommandHelp(alloc, top_level_registry, kind);
}

pub fn topLevelKindFromToken(token: []const u8) ?TopLevelKind {
    return command_specs.topLevelKindFromToken(top_level_registry, token);
}

pub fn topLevelUsage(kind: TopLevelKind) []const u8 {
    return command_specs.topLevelUsage(top_level_registry, kind);
}

pub const slash_specs = [_]SlashSpec{
    .{ .kind = .help, .command = "/help", .help_entry = "/help", .completion_description = "show available slash commands", .presentation_category = .general, .show_in_welcome = true },
    .{ .kind = .clear_screen, .command = "/clear", .help_entry = "/clear", .completion_description = "start a fresh conversation while keeping managed processes", .presentation_category = .general, .show_in_welcome = true },
    .{ .kind = .new_session, .command = "/new", .help_entry = "/new", .completion_description = "start a fresh session", .presentation_category = .session, .show_in_welcome = true },
    .{ .kind = .reset_session, .command = "/reset", .help_entry = "/reset", .completion_description = "reset the current session context", .presentation_category = .session },
    .{ .kind = .resume_session, .command = "/resume", .help_entry = "/resume", .completion_description = "resume a saved session", .presentation_category = .session },

    .{ .kind = .rename_session, .command = "/rename", .help_entry = "/rename <title>", .completion_description = "rename the current session", .presentation_category = .session, .has_args = true, .accepts_payload = true },
    .{ .kind = .provider, .command = "/provider", .aliases = &.{"/setup"}, .help_entry = "/provider (/setup)", .completion_description = "connect fx to a model provider with an API key", .presentation_category = .account, .show_in_welcome = true },
    .{ .kind = .stats, .command = "/stats", .help_entry = "/stats", .completion_description = "show token and turn statistics", .presentation_category = .account },
    .{ .kind = .usage, .command = "/usage", .aliases = &.{"/cost"}, .help_entry = "/usage (/cost)", .completion_description = "show local fx tokens, models, and spend", .presentation_category = .account },
    .{ .kind = .status, .command = "/status", .help_entry = "/status", .completion_description = "show runtime configuration", .presentation_category = .general, .show_in_welcome = true },
    .{ .kind = .image, .command = "/image", .aliases = &.{"/img"}, .help_entry = "/image <path> (/img)", .completion_description = "attach an image by path", .presentation_category = .media, .has_args = true, .accepts_payload = true },
    .{ .kind = .images, .command = "/images", .help_entry = "/images [clear]", .completion_description = "manage pending image attachments", .presentation_category = .media, .has_args = true, .accepts_payload = true },
    .{ .kind = .model, .command = "/model", .help_entry = "/model <id-or-query>", .completion_description = "choose what model and reasoning effort to use", .presentation_category = .model, .has_args = true, .accepts_payload = true },
    .{ .kind = .undo, .command = "/undo", .help_entry = "/undo", .completion_description = "undo the latest tracked file operation", .presentation_category = .session },
    .{ .kind = .skills, .command = "/skills", .help_entry = "/skills [list|add|install|show|create|remove|path] [name|url|path] ($ opens skill search)", .completion_description = "browse and manage skills", .presentation_category = .extensions, .has_args = true, .accepts_payload = true },
    .{ .kind = .copy, .command = "/copy", .help_entry = "/copy", .completion_description = "copy the last assistant response", .presentation_category = .session },
    .{ .kind = .trace, .command = "/trace", .help_entry = "/trace", .completion_description = "copy a private diagnostic trace", .presentation_category = .product },
    .{ .kind = .compact, .command = "/compact", .help_entry = "/compact", .completion_description = "summarize context into a fresh window", .presentation_category = .session },
    .{ .kind = .settings, .command = "/settings", .help_entry = "/settings [startup-scrollback [on|off]]", .completion_description = "browse and update settings", .presentation_category = .appearance, .has_args = true, .accepts_payload = true },
    .{ .kind = .paste, .command = "/paste", .help_entry = "/paste", .completion_description = "attach an image from the clipboard when supported", .presentation_category = .media },
    .{ .kind = .fast, .command = "/fast", .help_entry = "/fast", .completion_description = "toggle Fast mode when supported", .presentation_category = .model },
    .{ .kind = .statusline, .command = "/statusline", .help_entry = "/statusline [context|session|workspace]", .completion_description = "toggle status line segments", .presentation_category = .appearance, .has_args = true, .accepts_payload = true },
    .{ .kind = .notifications, .command = "/sound", .help_entry = "/sound [on|off|max]", .completion_description = "toggle sounds and terminal bells", .presentation_category = .appearance, .has_args = true, .accepts_payload = true },
    .{ .kind = .workspace, .command = "/workspace", .help_entry = "/workspace [list|add PATH|remove PATH|clear]", .completion_description = "manage additional workspace directories", .presentation_category = .workspace, .show_in_welcome = true, .has_args = true, .accepts_payload = true },
    .{ .kind = .version, .command = "/version", .help_entry = "/version", .completion_description = "show the fx version", .presentation_category = .general },
    .{ .kind = .quit, .command = "/quit", .aliases = &.{"/exit"}, .help_entry = "/quit", .completion_description = "exit the interactive shell", .presentation_category = .general, .show_in_welcome = true },
};

pub const slash_registry = SlashRegistry{ .commands = slash_specs[0..] };

pub fn matchesSlashExact(cmd: []const u8, kind: SlashKind) bool {
    return command_specs.matchesSlashExact(slash_registry, cmd, kind);
}

pub fn isExactSlashCommand(cmd: []const u8) bool {
    return slash_registry.matchExact(cmd) != null;
}

pub fn matchedSlashPrefix(cmd: []const u8, kind: SlashKind) ?[]const u8 {
    return command_specs.matchedSlashPrefix(slash_registry, cmd, kind);
}

pub fn renderSlashHelp(alloc: Allocator) ![]u8 {
    return command_specs.renderSlashHelp(alloc, slash_registry);
}

pub fn firstSlashCompletion(prefix: []const u8) ?[]const u8 {
    return command_specs.firstSlashCompletion(slash_registry, prefix);
}

pub fn slashCompletionCount(prefix: []const u8) usize {
    return command_specs.slashCompletionCount(slash_registry, prefix);
}

pub fn nthSlashCompletion(prefix: []const u8, n: usize) ?[]const u8 {
    return command_specs.nthSlashCompletion(slash_registry, prefix, n);
}

pub fn nthSlashCompletionLabel(prefix: []const u8, n: usize) ?[]const u8 {
    return command_specs.nthSlashCompletionLabel(slash_registry, prefix, n);
}

pub fn nthSlashCompletionDescription(prefix: []const u8, n: usize) ?[]const u8 {
    return command_specs.nthSlashCompletionDescription(slash_registry, prefix, n);
}

pub fn nthSlashCompletionCategory(prefix: []const u8, n: usize) ?SlashPresentationCategory {
    return command_specs.nthSlashCompletionCategory(slash_registry, prefix, n);
}

pub fn slashCompletionHasArgs(command: []const u8) bool {
    return command_specs.slashCompletionHasArgs(slash_registry, command);
}

pub const argCompletionAnchor = command_specs.argCompletionAnchor;
