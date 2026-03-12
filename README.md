# plankclaw

The smallest possible functional AI agent on Linux x86-64. Target: < 8 KB binary.

plankclaw is an autonomous AI agent that receives messages from Discord, sends them to the Claude API, and returns responses — all while maintaining persistent memory between sessions. The compiled agent binary is written entirely in x86-64 assembly. Network complexity (TLS, HTTP, WebSocket) is delegated to host tools (`curl`, `websocat`, `jq`).

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                   LINUX HOST                        │
│                                                     │
│  ┌───────────┐    FIFOs    ┌──────────────────┐     │
│  │           │ ─fifo_in──▶ │                  │     │
│  │  BRIDGE   │             │   AGENT           │     │
│  │  DISCORD  │ ◀─fifo_out─ │   (binary ~5KB   │     │
│  │           │             │    x86-64 asm)   │     │
│  │ (shell    │             ├──────────────────┤     │
│  │  script)  │             │                  │     │
│  │           │             │   BRIDGE LLM     │     │
│  └───────────┘             │   (shell script) │     │
│       │  ▲                 └──┬────────▲──────┘     │
│       │  │                    │        │            │
│       ▼  │             fifo_llm_req  fifo_llm_res  │
│   Discord API              │        │              │
│   (WebSocket + REST)       ▼        │              │
│                        Anthropic API               │
└─────────────────────────────────────────────────────┘
```

Three processes communicate through four named pipes (FIFOs):

- **Agent** (`plankclaw`) — x86-64 assembly binary. Reads messages, builds Claude API payloads, parses responses, persists history. No networking.
- **Bridge Discord** (`bridge_discord.sh`) — Shell script. Connects to Discord Gateway via WebSocket, relays messages.
- **Bridge LLM** (`bridge_llm.sh`) — Shell script. Sends JSON payloads to the Anthropic API via `curl`.

## Requirements

- Linux x86-64
- [NASM](https://nasm.us/) (assembler)
- `curl` (HTTP client)
- `jq` (JSON processor)
- [websocat](https://github.com/vi/websocat) (WebSocket client)

## Build

```sh
make
make size   # show binary size
```

## Setup

1. Copy and edit the config file:
   ```sh
   cp config.env.example config.env
   # Edit config.env with your Discord Bot Token, Channel ID, and Anthropic API Key
   ```

2. (Optional) Edit `memory/soul.md` to customize the bot's personality.

3. Make scripts executable:
   ```sh
   chmod +x plankclaw.sh bridge_discord.sh bridge_llm.sh
   ```

4. Run:
   ```sh
   ./plankclaw.sh
   ```

## Memory System

- `memory/soul.md` — System prompt / personality (human-editable)
- `memory/history.jsonl` — Conversation log (append-only JSONL)
- `memory/summary.md` — Compacted memory summary (auto-generated)

When history exceeds `HISTORY_MAX` lines (default: 200), old conversations are summarized by the LLM and stored in `summary.md`. The last `HISTORY_KEEP` lines (default: 40) are kept as-is.

## Configuration

Environment variables (set in `config.env`):

| Variable | Description | Default |
|---|---|---|
| `DISCORD_BOT_TOKEN` | Discord bot token | (required) |
| `DISCORD_CHANNEL_ID` | Discord channel to listen on | (required) |
| `ANTHROPIC_API_KEY` | Anthropic API key | (required) |
| `PLANKCLAW_DIR` | Memory file directory | `./memory` |
| `HISTORY_MAX` | Max history lines before compaction | `200` |
| `HISTORY_KEEP` | Lines to keep after compaction | `40` |

## File Structure

```
plankclaw/
├── plankclaw.asm          # Agent — x86-64 NASM assembly source
├── Makefile               # nasm + ld → plankclaw binary
├── plankclaw.sh           # Launcher
├── bridge_discord.sh      # Bridge Discord
├── bridge_llm.sh          # Bridge LLM
├── config.env.example     # Config template
├── memory/
│   ├── soul.md            # Persistent system prompt
│   ├── summary.md         # Cumulative summary (generated)
│   └── history.jsonl      # Raw history (generated)
└── README.md
```

## License

Public domain.
