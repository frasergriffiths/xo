const groq = @import("../gateway/groq.zig");
const provider_set = @import("../core/gateway/provider_set.zig");
const openrouter = @import("../gateway/openrouter.zig");

pub const native = provider_set.Set{
    .configured_fn = @import("../gateway/chat_completions.zig").bundle,
    // A `providers.openrouter` entry retargets the built-in endpoint through the
    // same route, so only the address and key slot can change.
    .builtin_override_fn = openrouter.bundle,
    // The OpenAI-compatible route is built from a runtime definition supplied by
    // the profile; this factory wires it when one exists.
    .openai_compatible_fn = @import("../gateway/openai_compatible.zig").bundle,
    .openrouter = openrouter.provider_bundle,
    // Groq is the second built-in provider. It shares the OpenAI
    // chat-completions transport and has no retarget entry in the first cut.
    .groq = groq.provider_bundle,
};
