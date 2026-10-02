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

fx is a coding agent CLI written in Zig: a single native binary, open source under Apache-2.0, model-agnostic, and drivable from other tools over the Agent Client Protocol. Its interface stays closer to a Unix shell than an IDE in the terminal.

## Highlights

- **Any model:** Vercel AI Gateway, ChatGPT or Grok subscriptions, or your own OpenAI-compatible endpoint such as Ollama or OpenRouter
- **Any interface:** interactive shell, one-shot `fx ask` for scripts, or embedded through ACP
- **Shell-like output:** inline rendering that preserves your terminal scrollback
- **Extensible:** skills, MCP servers, and subagents

<p>
  <a href="https://vercel.com/labs#labs-products"><img alt="Vercel Labs Product" src="https://img.shields.io/badge/LABS-PRODUCT-0a0a0a.svg?style=for-the-badge&amp;logo=Vercel&amp;labelColor=000000" height="28"></a>
  <a href="https://github.com/frasergriffiths/xo/releases/latest"><img alt="fx CLI release" src="https://img.shields.io/github/v/release/frasergriffiths/xo.svg?style=for-the-badge&amp;labelColor=000000&amp;label=release" height="28"></a>
  <a href="https://github.com/frasergriffiths/xo/blob/main/LICENSE"><img alt="License: Apache-2.0" src="https://img.shields.io/github/license/frasergriffiths/xo.svg?style=for-the-badge&amp;labelColor=000000" height="28"></a>
</p>

## Install

```bash
curl -fsSL https://fx.sh/setup.sh | bash
```

## Get started

Sign in with one of:

- `fx login`: Vercel AI Gateway
- `fx login codex`: ChatGPT subscription (OpenAI Codex OAuth)
- `fx login grok`: Grok subscription (xAI OAuth)
- `fx setup`: AI Gateway API key

Then start the interactive shell from a project:

```bash
cd your_project
fx
```

Or make a one-shot request:

```bash
fx ask "explain the changes in this repository"
```

Inside the shell, run `/help` to browse interactive commands.

In tmux, use your usual prefix bindings to switch sessions or enter copy mode.
fx preserves those tmux views while resizing, including when the switcher zooms a split pane.

## Documentation

Visit [fx.sh/docs](https://fx.sh/docs) for the full manual: sessions, models, custom model connections, permissions, configuration, skills, MCP, subagents, embedding, and the complete CLI and slash command references. Agents can read any page as Markdown by appending `.md` to its URL, or fetch [llms-full.txt](https://fx.sh/llms-full.txt) for everything in one file.

## Custom model connections

Add named connections for any OpenAI Chat Completions endpoint, including local servers such as Ollama and gateways such as OpenRouter, in `~/.fx/settings.json`, then select one for the profile or a single invocation:

```bash
fx provider local
FX_PROVIDER=openrouter FX_MODEL=openai/gpt-4.1 fx ask "review this change"
```

See [Custom model connections](https://fx.sh/docs/configure-fx/custom-model-connections) for connection JSON, model metadata, and behavior details.

## Gateway provider routing

When the active model goes through the Vercel AI Gateway, one model is often served by several providers (for example Anthropic directly, AWS Bedrock, or Google Vertex). fx can tell the gateway which providers to use, in what order:

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
fx ask --provider-order bedrock "review this change"
FX_PROVIDER_ORDER=vertex FX_PROVIDER_STRICT=1 fx
```

Slugs are the gateway's provider identifiers (letters, digits, dashes, for example `anthropic`, `bedrock`, `vertexAnthropic`), listed on the [models page](https://vercel.com/ai-gateway/models). An empty `provider_order` in a higher-precedence layer clears a list set by a lower one. Routing applies to gateway requests only; custom model connections ignore it.

## Themes

fx ships with `fx-dark` and `fx-light` and follows your terminal's light or dark mode. Pin a variant with `FX_THEME=light` or `FX_THEME=dark`, or drop a VS Code format theme at `~/.fx/themes/<name>.json` and select it with the `theme` setting or `FX_THEME=<name>` per launch. Without an explicitly selected theme, diff markers and edit counts stay monochrome; selecting any theme adds its diff marker colors. See [Configuration](https://fx.sh/docs/configure-fx/configuration) for all environment variables.

## Connect a client over ACP

fx ships one embedding surface: an Agent Client Protocol server over stdio. Start
it with `fx acp` and point your editor or tool at it.

```bash
fx acp                          # serve ACP on stdin and stdout
fx acp --model anthropic/claude-sonnet-5.5
fx acp --log-file /tmp/fx-acp.log
```

The server reports `protocolVersion` 1 on `initialize` and advertises session
loading, prompt images and embedded context, HTTP and SSE MCP transports, and
session list, resume, and close capabilities. Providers available are the Vercel
AI Gateway, a Codex subscription, and a Grok subscription.

fx also accepts the `libfx/*` ACP methods (`new`, `steer`, `checkpoint`,
`restore`, `tool_call`). They are part of the protocol fx speaks and are
unaffected by the removal of the JavaScript SDK.

There is no JavaScript or WebAssembly package. Build the binary and talk to it
over ACP, or use `fx ask` from a script.

## Slack workspace installation

Run `fx slack install` to install the fx bot in the configured Vercel Slack
workspace. Leave the command running and authorize Slack in a browser on the same
computer. The HTTPS callback at fx.sh returns the authorization to the CLI, so the
PKCE state and verifier never leave memory. The companion web bridge has to be
deployed and configured before installation will work.

Once the CLI saves the installation, the browser lands on an fx.sh confirmation
page. Close that tab or refresh it after the command exits.

`fx slack status --json` reports local installation metadata and no tokens. Plain
text hides the Slack IDs and prints the expiry as a readable UTC date; JSON keeps
the IDs and Unix timestamps for scripts. `fx slack refresh` rotates the local bot
credentials when they need it.

Credentials live in the owner-only file `~/.fx/slack/installation.json`. There is
no hosted database and no background refresh service, so an expired refresh token
means installing again.

## Slack user authorization

Workspace installation and per-user authorization are separate steps. Each
employee connects their own account with `/mcp auth slack --open` inside an fx
session, or `fx mcp auth slack` from a terminal.

For `https://mcp.slack.com/mcp`, fx recognizes its own app by public Client ID
and uses the HTTPS callback for personal login. Changing that Client ID means a
CLI update. OAuth targets the canonical form of Slack's advertised resource,
`https://mcp.slack.com/`, while the MCP transport itself stays at
`https://mcp.slack.com/mcp`.

First login and reauthorization ask for the full shared `user_scopes` list from
fx.sh. A local `scopes` override has to be at least that wide, and extra local
scopes are never requested. Anything narrower stops authorization before the
browser opens, leaving configuration and stored credentials untouched. Saved
scopes, Slack's advertised capabilities, and scope challenges cannot widen the
request. The shared list is nine personal scopes, configured for fx and
advertised by Slack MCP; changing it is a deliberate configuration change and may
need Slack approval. It does not revoke permissions on tokens already issued.

Personal authorization opens an ephemeral loopback listener instead of the
configured `callback_port`, keeps PKCE and personal tokens in the CLI, and shows
"Slack connected" once the tokens land in the existing MCP credential store. Other
MCP providers and other Slack app Client IDs keep their direct callback behavior
and never contact fx.sh. When fx.sh is unavailable the metadata endpoint returns
`SlackBridgeUnavailable`, and missing or invalid shared scopes stop authorization
rather than falling back to Slack's broader capabilities. Slack's own workspace
approval requirements still apply.

Bot installation does not tell you whether Slack will show a hoverable "Sent
using @fx" attribution. That needs a live message test.

## Build from source

Building fx requires [Zig 0.16.0+](https://ziglang.org/download/):

```bash
git clone https://github.com/frasergriffiths/xo.git
cd fx
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
