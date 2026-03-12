# PlanckClaw

<p align="center">
  <img src="logo.svg" alt="PlanckClaw" width="600">
</p>

<p align="center">
  <img src="https://img.shields.io/badge/x86--64-assembly-blue" alt="x86-64 assembly">
  <img src="https://img.shields.io/badge/binary-6,880_bytes-green" alt="6,880 bytes">
  <img src="https://img.shields.io/badge/total_runtime-20_KB-green" alt="20 KB total">
  <img src="https://img.shields.io/badge/dependencies-zero-brightgreen" alt="zero dependencies">
  <img src="https://img.shields.io/badge/platform-Linux_only-orange" alt="Linux only">
  <img src="https://img.shields.io/badge/license-public_domain-lightgrey" alt="public domain">
</p>

An AI agent in ~7 KB of x86-64 assembly. No libc, no runtime, no allocator. Just Linux syscalls.

PlanckClaw is an autonomous agent that communicates through three bridges: one for user interaction (Discord), one for thinking (Claude API), and one for acting (tools). The core is a pure router — it doesn't know which platform it talks to, which LLM it uses, or which tools it has. All three bridges are swappable shell scripts connected via named pipes. Four processes, six FIFOs, one agent. That's it.

The entire runtime footprint (binary, shell scripts, config, soul file) is ~20 KB. That's the whole agent. It fits on a 1.44 MB floppy disk about 72 times.

Modern AI agent frameworks ship hundreds of megabytes of runtimes, package managers, and abstraction layers before a single token is generated. LangChain alone pulls in 400+ transitive dependencies. PlanckClaw asks: what if we stripped all of that away? What's the smallest thing that can still act?

***This is a thought experiment, not production-ready software.***

## quick start

```sh
make                          # build the ~7KB binary
cp config.env.example config.env
# edit config.env → add your Anthropic API key (Discord tokens optional for CLI mode)
./planckclaw.sh ./bridge_cli.sh   # run in terminal mode
```

Type a message, get a response. No Discord, no websocat, just `curl` and an Anthropic API key.

For Discord mode:

```sh
# add Discord bot token and channel ID to config.env
./planckclaw.sh               # defaults to bridge_discord.sh
```

You'll need `nasm`, `curl`, `jq`, and `websocat` installed (see [install](#install) below).

## what is this

This is a thought experiment. A deliberate return to the Unix philosophy: do one thing, and do it well. The name comes from the [Planck length](https://en.wikipedia.org/wiki/Planck_length), the smallest meaningful scale in physics. PlanckClaw is the smallest meaningful AI agent we could build.

The agent binary does no networking and executes no tools. It is a pure router: read a message from the interaction bridge, ask the claw bridge what capabilities are available, build a prompt, send it to the brain bridge, parse the response, dispatch tool calls back to the claw bridge, and relay the final answer. All of this with raw `read`/`write`/`open`/`close` syscalls. No malloc. No printf. No libc at all. The binary is fully static and has zero runtime dependencies.

Everything else is composed around it:

- `bridge_discord.sh` connects to the Discord Gateway via WebSocket, relays messages through FIFOs. ~180 lines of shell.
- `bridge_brain.sh` takes JSON payloads from a FIFO, `curl`s the Anthropic API, writes responses back. ~85 lines of shell.
- `bridge_claw.sh` scans `claws/*.sh` for tool definitions (builtins, zero fork) and dispatches tool calls to the matching claw. ~50 lines of shell.
- `planckclaw.sh` creates pipes, starts all four processes, cleans up on exit. ~75 lines of shell.

The total codebase is ~2,800 lines. The compiled binary is 6,880 bytes. It runs in ~200KB of RAM (mostly BSS buffers). There is no build system beyond a 6-line Makefile. There are no dependencies beyond what's already on your Linux box (plus `websocat`).

The point is not that you should write your agents in assembly. The point is that you *can*, that the core logic of an AI agent (read, think, act, remember, respond) is simple enough to fit in a few kilobytes of machine code. Everything else is ceremony.

## architecture

```
   ┌──────────────────┐
   │   Discord API    │
   └───┬──────────▲───┘
       │          │
   ┌───▼──────────┴───┐
   │  BRIDGE INTERACT │
   │  (shell script)  │
   └───┬──────────▲───┘
       │          │
  interact_in  interact_out
       │          │
   ┌───▼──────────┴───┐              ┌──────────────────┐
   │      AGENT       ├──────────────►   BRIDGE CLAW   │
   │   (~7KB x86-64)  ◄──────────────┤  (shell script)  │
   └───┬──────────▲───┘              └──────────────────┘
       │          │               claw_in / claw_out
    brain_in   brain_out
       │          │
   ┌───▼──────────┴───┐
   │   BRIDGE BRAIN   │
   │  (shell script)  │
   └───┬──────────▲───┘
       │          │
   ┌───▼──────────┴───┐
   │  Anthropic API   │
   └──────────────────┘
```

Four processes, six named pipes. The agent never touches the network. The bridges never touch the state. Clean separation.

- **Agent** (`planckclaw`): the ~7KB binary. Pure router — reads messages, discovers tools, builds API payloads, parses responses, dispatches tool calls, persists history and memory. Written in x86-64 assembly. No networking, no tool execution.
- **Bridge Interact** (`bridge_discord.sh` or `bridge_cli.sh`): swappable. `bridge_discord.sh` connects to Discord via WebSocket. `bridge_cli.sh` provides a terminal interface. Pass as argument to `planckclaw.sh`.
- **Bridge Brain** (`bridge_brain.sh`): reads JSON payloads from `brain_in`, sends them to the Anthropic Messages API via `curl`, writes responses to `brain_out`. Retries on failure.
- **Bridge Claw** (`bridge_claw.sh`): scans `claws/*.sh` for tool definitions on `__list_tools__` (builtins, zero fork), dispatches tool calls to matching claw scripts. Hot-reload: add/remove a file, the next message sees the change.

## tools

What makes PlanckClaw an *agent* rather than a chatbot is tool use. At each message, the agent asks the claw bridge for available tools via the `__list_tools__` discovery protocol and injects them into the Claude API request using the standard [tool use](https://docs.anthropic.com/en/docs/build-with-claude/tool-use) protocol.

PlanckClaw ships with two default claws in the `claws/` directory:

| Tool | Claw file | What it returns |
|---|---|---|
| `get_time` | `claws/time.sh` | Current Unix timestamp |
| `system_status` | `claws/system.sh` | Uptime, RAM total/free, 1-min load average, process count |

When the LLM decides it needs information, it returns `stop_reason: "tool_use"` instead of text. The agent detects this, dispatches the call to the claw bridge via FIFO, and sends the result back in a `tool_result` message. The LLM then generates its final response using the real data.

### extensibility

Adding a new tool is simple — drop a file in `claws/`:

```sh
#!/bin/sh
#TOOLS:{"name":"my_tool","description":"What it does","input_schema":{"type":"object","properties":{}}}

case "$1" in
    my_tool) printf 'result here' ;;
esac
```

Make it executable (`chmod +x`) and you're done. The claw bridge scans `claws/*.sh` at each message using shell builtins (zero fork for discovery). No recompilation, no config file, no restart needed — hot-reload is built in.

### limitations

The default tools are deliberately minimal. PlanckClaw is a thought experiment, not a framework. But the architecture supports any tool — filesystem access, HTTP requests, command execution — by adding a claw file. The core stays under 8KB. Forever.

## memory

The agent maintains three files:

- `memory/soul.md`: system prompt, personality. You write this. The agent reads it on startup and injects it into every API call.
- `memory/history.jsonl`: full conversation log, append-only JSONL. One line per message, alternating user/assistant roles.
- `memory/summary.md`: compacted memory. When history exceeds `HISTORY_MAX` lines (default: 200), the agent sends old conversations to the LLM for summarization, keeps the last `HISTORY_KEEP` lines (default: 40), and stores the summary here. Next conversations include the summary as context.

This gives the agent long-term memory that survives restarts and grows without bound (thanks to compaction). Edit `soul.md` to change who the agent is. Delete `history.jsonl` and `summary.md` to wipe its memory.

## configuration

Environment variables in `config.env`:

| Variable | Description | Default |
|---|---|---|
| `DISCORD_BOT_TOKEN` | Discord bot token | (required for Discord) |
| `DISCORD_CHANNEL_ID` | Channel to listen on | (required for Discord) |
| `ANTHROPIC_API_KEY` | Anthropic API key | (required) |
| `PLANCKCLAW_DIR` | Memory directory | `./memory` |
| `HISTORY_MAX` | Lines before compaction | `200` |
| `HISTORY_KEEP` | Lines kept after compaction | `40` |

## install

**Build tools** (to compile the agent):

```sh
sudo apt install nasm binutils make    # Debian/Ubuntu
sudo dnf install nasm binutils make    # Fedora
```

**Runtime tools** (to run):

```sh
sudo apt install curl jq               # Debian/Ubuntu
```

Plus [websocat](https://github.com/vi/websocat), grab a binary from the releases page. It's a single static binary (the Unix way).

You'll also need a [Discord bot token](https://discord.com/developers/applications) with the Message Content intent enabled, and an [Anthropic API key](https://console.anthropic.com/).

## files

```
planckclaw/
├── planckclaw.asm         # the agent, ~2,300 lines of x86-64 NASM
├── Makefile               # nasm + ld → ~7KB binary
├── planckclaw.sh          # launcher, starts everything, cleans up on exit
├── bridge_discord.sh     # Discord ↔ FIFO interaction bridge
├── bridge_cli.sh          # Terminal ↔ FIFO interaction bridge
├── bridge_brain.sh        # FIFO ↔ Anthropic API brain bridge
├── bridge_claw.sh         # FIFO ↔ claw router (discovery + dispatch)
├── config.env.example     # config template
├── claws/
│   ├── time.sh            # claw: get_time
│   └── system.sh          # claw: system_status
└── memory/
    ├── soul.md            # who the agent is (you write this)
    ├── history.jsonl      # conversation log (auto-generated)
    └── summary.md         # compacted memory (auto-generated)
```

## license

Public domain.
