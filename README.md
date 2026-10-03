```
 ⠀⠀⠀⠀⠀⠀⣠⣾⣿⣿⣿⠀⠀⠀⠀⠀⠀⠀⠀
 ⠀⠀⠀⠀⠀⢰⣿⡿⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
 ⠀⠀⠀⣠⣶⣿⣿⣷⣶⡶⣶⣶⣆⠀⠀⠀⣴⣶⣶⠆
 ⠀⠀⠀⠉⢹⣿⣿⠉⠉⠀⠘⢿⣿⣧⣀⣾⣿⡿⠃⠀             Tiny, open, embeddable, native coding agent.
 ⠀⠀⠀⠀⣼⣿⡏⠀⠀⠀⠀⠀⠻⣿⣿⣿⠟⠀⠀⠀
 ⠀⠀⠀⢀⣿⣿⠃⠀⠀⠀⠀⢠⣦⠘⢿⣿⣷⡀⠀⠀             curl -fsSL https://fx.sh/setup.sh | bash
 ⠀⠀⠀⣸⣿⡟⠀⠀⠀⠀⣰⣿⣿⠗⠀⠻⣿⣿⣄⠀
 ⠀⠀⠀⣿⣿⠇⠀⠀⠀⠾⠿⠿⠋⠀⠀⠀⠘⠿⠿⠦             ⚠ Status: Experimental. Use at your own risk.
  ⠀⣸⣿⡿⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
 ⣿⣿⣿⠟⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
```

fx is a coding agent CLI written in Zig: a small native binary that is open source (Apache-2.0), model-agnostic, and embeddable as a harness in larger systems. Its interface stays closer to a Unix shell than an IDE in the terminal.

## Highlights

- **OpenRouter:** every model fx can reach through one OpenRouter API key, plus your own OpenAI-compatible endpoints such as Ollama
- **Terminal only:** one interactive shell, plus one-shot commands for scripts
- **Shell-like output:** inline rendering that preserves your terminal scrollback
- **Extensible:** skills and subagents

<p>
  <a href="https://github.com/frasergriffiths/xo/releases/latest"><img alt="fx CLI release" src="https://img.shields.io/github/v/release/frasergriffiths/xo.svg?style=for-the-badge&amp;labelColor=000000&amp;label=release" height="28"></a>
  <a href="https://github.com/frasergriffiths/xo/blob/main/LICENSE"><img alt="License: Apache-2.0" src="https://img.shields.io/github/license/frasergriffiths/xo.svg?style=for-the-badge&amp;labelColor=000000" height="28"></a>
</p>

## Install

```bash
curl -fsSL https://fx.sh/setup.sh | bash
```

## Get started

Save an OpenRouter API key:

```bash
fx setup
```

Alternatively, set `OPENROUTER_API_KEY` in your environment instead of saving
a key. Open `/provider` and choose `remove` in the Providers menu to delete a
saved key.

Then start the interactive shell from a project:

```bash
cd your_project
fx
```

Type your request at the prompt. Inside the shell, run `/help` to browse
interactive commands.

In tmux, use your usual prefix bindings to switch sessions or enter copy mode.
fx preserves those tmux views while resizing, including when the switcher zooms a split pane.

## Providers

fx ships with three built-in providers:

- **OpenRouter:** set `OPENROUTER_API_KEY`, or save a key with `fx setup` or `/provider`.
- **Groq:** set `GROQ_API_KEY`, or save a key with `/provider`.
- **OpenAI-compatible:** point fx at any OpenAI Chat Completions endpoint. Set `FX_OPENAI_COMPATIBLE_API_KEY`, or save a key with `/provider` and enter the base URL when asked. The base URL defaults to `https://api.openai.com/v1`.

## Documentation

Visit [fx.sh/docs](https://fx.sh/docs) for the full manual: sessions, models, custom model connections, permissions, configuration, skills, subagents, embedding, and the complete CLI and slash command references. Agents can read any page as Markdown by appending `.md` to its URL, or fetch [llms-full.txt](https://fx.sh/llms-full.txt) for everything in one file.

## Custom model connections

Add named connections for any OpenAI Chat Completions endpoint, including local servers such as Ollama and gateways such as OpenRouter, in `~/.fx/settings.json`, then select one for the profile or a single invocation:

```bash
fx provider local
FX_PROVIDER=openrouter FX_MODEL=openai/gpt-4.1 fx
```

See [Custom model connections](https://fx.sh/docs/configure-fx/custom-model-connections) for connection JSON, model metadata, and behavior details.

## Provider routing

OpenRouter can serve one model from several upstream providers (for example
Anthropic directly, AWS Bedrock, or Google Vertex). fx can tell OpenRouter
which providers to use, and in what order:

```jsonc
// ~/.fx/settings.json
{
  "provider_order": ["bedrock", "anthropic"], // try Bedrock first, then Anthropic
  "provider_strict": false                     // true restricts requests to only these providers
}
```

Both keys also work in a committed project `.fx.json`, and per launch:

```bash
fx --provider-order azure,openai --provider-strict
FX_PROVIDER_ORDER=vertex FX_PROVIDER_STRICT=1 fx
```

Slugs are the upstream provider identifiers (letters, digits, dashes, for
example `anthropic`, `bedrock`, `vertexAnthropic`). An empty `provider_order`
in a higher-precedence layer clears a list set by a lower one. Routing applies
to OpenRouter requests only; custom model connections ignore it.

## Permissions

fx runs with a single permission mode: full access. Tool calls execute without a
human permission prompt and the effective sandbox is `none`.

`yolo` is the only accepted value for `permission_mode` and `FX_PERMISSION_MODE`,
and it is what fx persists. The former `ask` and `auto` modes no longer exist,
and the `full-access` and `full access` spellings are no longer recognized. Any
unrecognized value is ignored and full access still applies.

## Context compaction

When a conversation approaches the model's context window, fx summarizes the
earlier turns into a handoff and continues from that. The summary keeps the goal,
constraints, decisions, completed work, failures, and unfinished work, and keeps
recent user messages verbatim.

Two settings control it:

- `auto_compact_percent` in `~/.fx/settings.json` sets the share of usable input
  at which automatic compaction fires. It accepts 10 through 80 and defaults to
  80. `FX_AUTO_COMPACT_PERCENT` overrides it for one launch. A value outside the
  range is ignored and the default applies, so a typo can never disable
  compaction.
- `/compact` runs compaction on demand, regardless of how much context is in use.

Compacted turns and tool results get short names, `M1` and `T1` and up, which
`read_tool_result` accepts in place of the long handles the handoff also carries.
Both spellings work, so nothing depends on the short names being available.

The summary is written by the lowest reasoning effort the model supports, since
writing a summary is a compression task rather than a reasoning one. When a
second provider family is configured, one availability failure retries the
summary there, so a single provider outage does not cost a long session.

## Themes

fx ships with `fx-dark` and `fx-light` and follows your terminal's light or dark mode. Pin a variant with `FX_THEME=light` or `FX_THEME=dark`, or drop a VS Code format theme at `~/.fx/themes/<name>.json` and select it with the `theme` setting or `FX_THEME=<name>` per launch. Without an explicitly selected theme, diff markers and edit counts stay monochrome; selecting any theme adds its diff marker colors. See [Configuration](https://fx.sh/docs/configure-fx/configuration) for all environment variables.

## Build from source

Building fx requires [Zig 0.16.0+](https://ziglang.org/download/):

```bash
git clone https://github.com/frasergriffiths/xo.git
cd xo
zig build -Doptimize=ReleaseSafe
./zig-out/bin/fx
```

Run the test suite with `zig build test`. See [CONTRIBUTING.md](CONTRIBUTING.md) for development and contribution guidelines.

## Security

Report security vulnerabilities through the [contact page](https://fx.sh/contact) instead of a public issue.

## License

[Apache-2.0](LICENSE). Third-party licenses and attributions are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Credits

Interface sounds by [cuelume](https://github.com/Danilaa1/cuelume).
