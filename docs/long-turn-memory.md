# Long-turn memory

Saved agent turns keep messages and tool results alive across model steps. The
turn arena must therefore survive until finalization. Temporary work has a
shorter lifetime:

* Recovery checkpoint reconstruction uses a separate arena. Persistence sinks
  synchronously copy or serialize the borrowed checkpoint before returning.
* Provider attempts use a separate arena for HTTP and response-parser scratch.
  Successful or failed owned results are copied to the caller's allocator before
  that arena is destroyed. Deferred usage references and failure diagnostics
  are included in the copy. Stable borrowed provider results remain borrowed.

Both scopes release temporary storage on success, cancellation and error. The
step limit, history contents, request semantics and retry policy are unchanged.
The native prepared request body already uses the resetting overlay arena.

Focused unit regressions cover 1000 growing checkpoints and 1000 provider
attempts, including cancellation, transport failure, provider failure and a
failed checkpoint save. Result-copy tests destroy the source allocator before
reading the copied response, deferred usage and diagnostics, and inject failures
at each copy allocation to verify cleanup.
