const std = @import("std");
const model_capabilities = @import("../core/config/model_capabilities.zig");

/// Groq model heuristics used when a live catalog entry is not available or does
/// not describe the model. Groq ids are mostly un-prefixed
/// (`llama-3.3-70b-versatile`) with a few vendor-prefixed ones
/// (`openai/gpt-oss-120b`), so the rules match on substrings rather than
/// OpenRouter's `vendor/model` shape. Unknown models return null and fall back to
/// the live catalog's own `context_window`.
pub fn capabilitiesForModel(model: []const u8) model_capabilities.Capabilities {
    var capabilities = model_capabilities.capabilitiesForModel(model);
    capabilities.context_window = contextWindowSize(model);
    return capabilities;
}

pub fn contextWindowSize(model: []const u8) ?u32 {
    if (isNonChatModel(model)) return null;
    // Every current Groq chat model publishes a 131,072-token window except the
    // older Gemma 2 family, which stays at 8,192.
    if (containsIgnoreCase(model, "gemma2")) return 8192;
    if (containsIgnoreCase(model, "llama") or
        containsIgnoreCase(model, "qwen") or
        containsIgnoreCase(model, "kimi") or
        containsIgnoreCase(model, "deepseek") or
        containsIgnoreCase(model, "gemma") or
        containsIgnoreCase(model, "mixtral") or
        containsIgnoreCase(model, "mistral") or
        containsIgnoreCase(model, "gpt-oss"))
    {
        return 131_072;
    }
    return null;
}

/// Speech (whisper), text-to-speech (orpheus/tts), and guard models are not
/// agent targets, so they are hidden from the picker and carry no chat context
/// window.
pub fn isNonChatModel(model: []const u8) bool {
    return containsIgnoreCase(model, "whisper") or
        containsIgnoreCase(model, "guard") or
        containsIgnoreCase(model, "tts") or
        containsIgnoreCase(model, "orpheus");
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
