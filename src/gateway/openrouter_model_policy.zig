const std = @import("std");
const model_capabilities = @import("../core/config/model_capabilities.zig");

/// Vendor model heuristics used when a live OpenRouter catalog entry is not
/// available. OpenRouter ids are `vendor/model`, so the same family rules apply.
pub fn capabilitiesForModel(model: []const u8) model_capabilities.Capabilities {
    var capabilities = model_capabilities.capabilitiesForModel(model);
    if (std.mem.startsWith(u8, model, "deepseek/")) {
        capabilities.parallel_tool_calls = true;
    }
    capabilities.context_window = contextWindowSize(model);
    return capabilities;
}

pub fn contextWindowSize(model: []const u8) ?u32 {
    if (std.mem.startsWith(u8, model, "anthropic/")) {
        // Sonnet moved to a 1M window; every other Claude family stays at 200k.
        if (containsIgnoreCase(model, "sonnet")) return 1_000_000;
        return 200_000;
    }
    if (std.mem.startsWith(u8, model, "openai/")) {
        if (containsIgnoreCase(model, "gpt-5") or containsIgnoreCase(model, "gpt-6")) return 400_000;
        if (containsIgnoreCase(model, "o3") or
            containsIgnoreCase(model, "o4") or
            containsIgnoreCase(model, "o1")) return 200_000;
        return 128_000;
    }
    if (std.mem.startsWith(u8, model, "google/gemini")) return 1_000_000;
    if (std.mem.startsWith(u8, model, "deepseek/")) return 131_072;
    if (std.mem.startsWith(u8, model, "qwen/qwen3")) return 262_144;
    return null;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    const last_start = haystack.len - needle.len;
    var index: usize = 0;
    while (index <= last_start) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    }
    return false;
}
