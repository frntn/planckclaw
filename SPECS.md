# PLANKCLAW — Design Specification for Claude Code
# The smallest possible functional AI agent on Linux x86-64
# NO CODE UNTIL YOU HAVE READ AND UNDERSTOOD THIS ENTIRE DOCUMENT.

================================================================================
LEVEL 1 — CAPABILITIES
================================================================================

## Project Name: plankclaw

## Founding Constraint
Smallest possible autonomous AI agent binary on Linux x86-64. Target: < 8 KB.
The agent follows Unix philosophy: do one thing well, delegate the rest to
existing tools on the host machine.

## Core Capabilities

  C1 — Receive messages from a human via Discord.
  C2 — Send a prompt to Anthropic Claude API and receive the response.
  C3 — Send the LLM response back to Discord.
  C4 — Maintain persistent memory between sessions: conversation history
       and an injectable personality/context file.
  C5 — Run continuously as a long-lived daemon process, listening for
       incoming messages.

## Explicitly Out of Scope (v1)

  - No embedded TLS (delegated to environment tools)
  - No multi-channel (Discord only)
  - No multi-model (Claude only)
  - No skills/plugins
  - No shell command execution
  - No cron/webhook triggers (reactive daemon only)
  - No web interface or dashboard
  - No sophisticated error handling (basic retry, clean crash otherwise)
  - No multi-user (single owner)

## Environment Constraints

  - Linux x86-64 only
  - Agent relies on host tools (curl, websocat, jq) for network transport/TLS
  - API keys (Anthropic, Discord Bot Token) provided via environment variables
  - Local filesystem is the only storage system

================================================================================
LEVEL 2 — COMPONENTS
================================================================================

## Architectural Philosophy

The agent itself is a minimalist Unix filter. Network complexity (TLS, HTTP,
WebSocket, polling) is delegated to external processes via pipes. The agent
only: reads, thinks, writes, remembers.

## Component Diagram
                                                           
   ┌──────────────────────────────────────────────────┐    
   │                   LINUX HOST                     │    
   │                                                  │    
   │  ┌───────────┐    FIFOs     ┌─────────────────┐  │    
   │  │           │              │                 │  │    
   │  │  BRIDGE   │  ─fifo_in──▶ │  AGENT          │  │    
   │  │  DISCORD  │              │  (binary ~5KB   │  │    
   │  │           │  ◀─fifo_out─ │   x86-64 asm)   │  │    
   │  │ (shell    │              ├─────────────────┤  │    
   │  │  script)  │              │                 │  │    
   │  │           │              │  BRIDGE LLM     │  │    
   │  │           │              │  (shell script) │  │    
   │  └───┬───▲───┘              └────┬────▲───────┘  │    
   │      │   │                       │    │          │    
   │      │   │                       │    │          │    
   │      │   │              fifo_llm_req fifo_llm_res│    
   │      │   │                       │    │          │    
   │      ▼   │                       ▼    │          │    
   │    Discord API               Anthropic API       │    
   │  ┌────────────────────────────────────────────┐  │    
   │  │              FILESYSTEM                    │  │    
   │  │  memory/history.jsonl  (conversation log)  │  │    
   │  │  memory/soul.md        (personality/prompt)│  │    
   │  │  memory/summary.md     (compacted memory)  │  │    
   │  │  config.env            (API tokens)        │  │    
   │  └────────────────────────────────────────────┘  │    
   └──────────────────────────────────────────────────┘    
                                                           
## Component Details

### A — AGENT (x86-64 assembly binary, NASM): "plankclaw"

  The core. The ONLY compiled component. Responsibilities:
    - Main loop: read incoming message on fifo_in, process, write response on fifo_out
    - Build JSON payload for Claude API (inject soul.md + recent history + message)
    - Parse LLM JSON response (extract response text) using a real minimal JSON parser
    - Write each exchange to history.jsonl (append-only)
    - Read soul.md at startup and keep in memory
    - Read summary.md at startup and keep in memory
    - Trigger compaction when history exceeds threshold

  What it does NOT do: no networking, no TLS, no HTTP, no WebSocket, no Discord polling.

### B — BRIDGE DISCORD (shell script): "bridge_discord.sh"

  A shell script (~100 lines) that:
    - Connects to Discord Gateway via websocat (WebSocket)
    - Handles Identify, Heartbeat, and MESSAGE_CREATE events
    - Extracts message text and channel_id with jq
    - Writes to fifo_in (format: channel_id\tmessage\n)
    - Reads from fifo_out and sends responses via Discord REST API with curl
    - Ignores bot messages (prevents loops)

  Dependencies: websocat, jq, curl

### C — BRIDGE LLM (shell script): "bridge_llm.sh"

  A shell script (~40 lines) that:
    - Reads complete JSON payload from fifo_llm_req (delimited by \n\n)
    - Sends it to https://api.anthropic.com/v1/messages via curl
    - Returns raw JSON response on fifo_llm_res (delimited by \n\n)
    - On failure after retries: returns {"error":"timeout"}\n\n

  Dependencies: curl

### D — FILESYSTEM (memory persistence)

  Not a software component — a file convention:
    - memory/history.jsonl — One JSON line per message, append-only
    - memory/soul.md — System prompt, read once at startup, human-editable
    - memory/summary.md — Cumulative summary, written by LLM during compaction
    - config.env — Environment variables for tokens and settings

## Key Architectural Decisions

  WHY shell scripts for bridges, not all in asm?
    curl already handles TLS, HTTP/2, certs, retries, redirects.
    Reimplementing in asm would be thousands of lines for zero functional gain.
    The "smallest binary" constraint applies to the compiled binary, not the
    shell ecosystem around it.

  WHY FIFOs for IPC?
    Simplest IPC mechanism on Unix. Zero extra syscalls beyond read() and write().
    Zero complex serialization. Makes the agent testable in isolation (pipe text
    manually).

  WHY JSONL for history, not Markdown like OpenClaw?
    The agent must build a JSON payload for the Claude API. If history is already
    JSON, no parsing/conversion needed — the agent concatenates lines. In asm,
    every parsing operation avoided saves hundreds of instructions.

  WHY separate Discord bridge and LLM bridge?
    So you can replace one without touching the other. Want to switch from
    Discord to Telegram? Rewrite only the Discord bridge. Want to switch from
    Claude to GPT? Rewrite only the LLM bridge. The compiled agent never changes.

================================================================================
LEVEL 3 — INTERACTIONS
================================================================================

## The 4 FIFOs

    /tmp/plankclaw/fifo_in       Bridge Discord → Agent     (incoming messages)
    /tmp/plankclaw/fifo_out      Agent → Bridge Discord      (responses)
    /tmp/plankclaw/fifo_llm_req  Agent → Bridge LLM          (JSON payloads)
    /tmp/plankclaw/fifo_llm_res  Bridge LLM → Agent          (JSON responses)

  All created by the launcher script before starting the three processes.

## Main Sequence — A message arrives

    TIME    BRIDGE DISCORD           AGENT                    BRIDGE LLM
    ────    ──────────────           ─────                    ──────────
     t0     websocat receives
            MESSAGE_CREATE from
            Discord Gateway

     t1     jq extracts channel_id
            and content
            Escape \n and \t

     t2     write fifo_in:
            "123456789\tHello\n"

     t3                              read fifo_in (blocking)
                                     parse: channel_id=123456789
                                            msg="Hello"

     t4                              --- BUILD PROMPT ---
                                     soul.md (in memory)
                                     summary.md (in memory)
                                     last HISTORY_KEEP lines
                                       from history.jsonl
                                     Build JSON payload

     t5                              write fifo_llm_req:
                                     {complete JSON}\n\n

     t6                                                       read fifo_llm_req
                                                              curl POST to
                                                              api.anthropic.com

     t7                                                       <── JSON response
                                                              write fifo_llm_res:
                                                              {raw JSON}\n\n

     t8                              read fifo_llm_res
                                     JSON parser: navigate to
                                       content[0].text

     t9                              --- PERSIST ---
                                     append history.jsonl:
                                       {"role":"user","content":"Hello"}
                                       {"role":"assistant","content":"..."}

    t10                              --- COMPACTION CHECK ---
                                     if history.jsonl > HISTORY_MAX lines:
                                       trigger compaction sequence

    t11                              write fifo_out:
                                     "123456789\tLLM response\n"

    t12     read fifo_out
            parse: channel_id, response
            Unescape \\n → \n
            curl POST to Discord
            REST API sendMessage

    t13     loop back to t0

## Compaction Sequence

  When history.jsonl exceeds HISTORY_MAX lines (200), the agent summarizes
  old exchanges to free space while preserving context.

    TIME    AGENT                                    BRIDGE LLM
    ────    ─────                                    ──────────

     c0     history.jsonl has 200+ lines.
            Split into two zones:
              LINES 0..159 (old)     → to compact
              LINES 160..199 (recent) → keep as-is

     c1     Read memory/summary.md
            (existing summary, may be empty)

     c2     Build a special compaction prompt:
            {
              model: claude-haiku-4-5-20241022,
              max_tokens: 2048,
              system: "You are a memory compaction assistant.
                Summarize the following conversation, preserving:
                key facts about the user, their preferences,
                decisions made, ongoing projects, and important
                context. Be concise but complete. Output only the
                summary, no preamble.",
              messages: [{
                role: "user",
                content: "EXISTING SUMMARY:\n[summary.md]\n\n
                  CONVERSATION TO SUMMARIZE:\n[lines 0..159]"
              }]
            }

     c3     write fifo_llm_req
                                                     read, curl, response
     c4                                              write fifo_llm_res

     c5     read fifo_llm_res
            Write response to memory/summary.md
            (overwrite, not append)

     c6     Rewrite history.jsonl:
            keep only lines 160..199
            (the last 40)

  After compaction, the normal prompt structure becomes:

      system:  [soul.md contents]
               ---
               CONVERSATION SUMMARY:
               [summary.md contents]

      messages: [last 40 exchanges from history.jsonl]
                + current message

## Data Formats on FIFOs

  fifo_in and fifo_out (Discord <-> Agent):

      {channel_id}\t{text}\n

    - channel_id: decimal ASCII integer (e.g. 1234567890123456789)
    - \t: tab character (0x09), separator
    - text: UTF-8 content, literal \n replaced by \\n, literal \t replaced by \\t
    - \n: message delimiter (0x0A)

    Example: 1234567890123456789\tHello how are you?\n

  fifo_llm_req and fifo_llm_res (Agent <-> LLM):

      {compact JSON on a single line}\n\n

    - The double newline (\n\n) is the message delimiter.
    - JSON is always compact (single line, never pretty-printed).
    - This works because curl returns compact JSON by default.

## Error Handling (minimal, v1)

    Situation                              Behavior
    ─────────                              ────────
    Bridge LLM: curl fails (timeout, 5xx)  Bridge writes {"error":"timeout"}\n\n
                                           on fifo_llm_res. Agent detects "error"
                                           field and writes apology on fifo_out.

    Bridge LLM: curl fails 3x in a row     Bridge writes {"error":"fatal"}\n\n.
                                           Agent writes "Temporarily unavailable"
                                           and continues listening on fifo_in.

    Bridge Discord: WebSocket disconnects   sleep 5 with exponential backoff
                                           (max 60s), reconnect.

    Agent: history.jsonl corrupted          Agent reads line by line, ignores
                                           unparseable lines. Graceful degradation.

    Agent: soul.md missing                  Agent uses hardcoded default system
                                           prompt: "You are a helpful personal
                                           assistant."

    A process dies                          Others block on FIFO (natural behavior).
                                           Launcher can monitor with wait and restart.

================================================================================
LEVEL 4 — CONTRACTS
================================================================================

## A — AGENT LIFECYCLE (plankclaw, x86-64 asm binary)

  STARTUP:
    1. Read env var PLANKCLAW_DIR (default: "./memory")
    2. Read env var HISTORY_MAX (default: "200")
    3. Read env var HISTORY_KEEP (default: "40")
    4. Open and read $PLANKCLAW_DIR/soul.md entirely into memory
       - If missing → use hardcoded default: "You are a helpful personal assistant."
    5. Open and read $PLANKCLAW_DIR/summary.md entirely into memory
       - If missing → empty string
    6. Open the 4 FIFOs:
       - /tmp/plankclaw/fifo_in      (O_RDONLY)
       - /tmp/plankclaw/fifo_out     (O_WRONLY)
       - /tmp/plankclaw/fifo_llm_req (O_WRONLY)
       - /tmp/plankclaw/fifo_llm_res (O_RDONLY)
    7. Enter MAIN LOOP

  MAIN LOOP (infinite):
    8.  read() on fifo_in → buffer (blocking)
    9.  Parse: channel_id, message (separated by \t, terminated by \n)
    10. Read last HISTORY_KEEP lines from history.jsonl
    11. Build JSON payload (see payload contract below)
    12. write() payload to fifo_llm_req, terminated by \n\n
    13. read() response from fifo_llm_res until \n\n (blocking)
    14. Parse response JSON using structural JSON parser:
        navigate to content → array index 0 → "text" field
        - If "error" field present → response = "I'm temporarily unavailable."
    15. Append 2 lines to history.jsonl:
        {"role":"user","content":"..."}
        {"role":"assistant","content":"..."}
    16. If line count of history.jsonl > HISTORY_MAX:
        → Trigger COMPACTION sequence
    17. write() response to fifo_out: channel_id\tresponse\n
    18. Go to step 8

## B — STATIC BUFFERS (constants compiled into binary)

  All allocated in .bss (zero binary cost — zeroed by kernel at load).

    Name            Size     Purpose
    ────            ────     ───────
    MAX_MSG_IN      4096     Max incoming message (fifo_in)
    MAX_JSON_OUT    65536    Max JSON payload to LLM
    MAX_JSON_IN     65536    Max JSON response from LLM
    MAX_SOUL        8192     Max soul.md size
    MAX_SUMMARY     8192     Max summary.md size
    MAX_HISTORY     32768    Max history block injected in prompt
    MAX_LINE        4096     Max single line in history.jsonl

## C — SYSCALLS USED (exhaustive list)

    Number  Name        Usage
    ──────  ────        ─────
    0       sys_read    Read FIFOs and files
    1       sys_write   Write FIFOs and files
    2       sys_open    Open files and FIFOs
    3       sys_close   Close file descriptors
    8       sys_lseek   Seek in history.jsonl
    21      sys_access  Check file existence (F_OK)
    60      sys_exit    Termination

  NO fork(). NO exec(). NO mmap(). NO brk(). Zero dynamic allocation.

## D — JSON PAYLOAD: Agent → Bridge LLM (fifo_llm_req)

  Normal prompt (compact, single line):

    {"model":"claude-haiku-4-5-20241022","max_tokens":1024,"system":"[SOUL.MD CONTENTS]\\n---\\nCONVERSATION SUMMARY:\\n[SUMMARY.MD CONTENTS]","messages":[{"role":"user","content":"msg1"},{"role":"assistant","content":"rep1"},{"role":"user","content":"current_msg"}]}

  Construction rules:
    - Always compact JSON (single line, never pretty-printed)
    - "system" field = soul.md + "\\n---\\nCONVERSATION SUMMARY:\\n" + summary.md
      (if summary.md is empty, omit the separator and summary part)
    - "messages" field = array of last HISTORY_KEEP exchanges from history.jsonl
      + current message as last element
    - Special characters in content are JSON-escaped:
        " → \"
        newline → \\n
        tab → \\t
        backslash → \\\\

  Compaction prompt (compact, single line):

    {"model":"claude-haiku-4-5-20241022","max_tokens":2048,"system":"You are a memory compaction assistant. Summarize the following conversation, preserving: key facts about the user, their preferences, decisions made, ongoing projects, and important context. Be concise but complete. Output only the summary, no preamble.","messages":[{"role":"user","content":"EXISTING SUMMARY:\\n[summary.md]\\n\\nCONVERSATION TO SUMMARIZE:\\n[lines 0..N-HISTORY_KEEP from history.jsonl]"}]}

## E — JSON RESPONSE: Bridge LLM → Agent (fifo_llm_res)

  Success response from Anthropic API (compact, single line):

    {"id":"msg_01X","type":"message","role":"assistant","content":[{"type":"text","text":"The actual LLM response here"}],"model":"claude-haiku-4-5-20241022","stop_reason":"end_turn"}

  The agent's JSON parser must structurally navigate:
    → find key "content"
    → enter array
    → enter first object
    → find key "text"
    → extract string value (handling \" escapes)

  This is NOT a search for the string "text:" — it is structural navigation
  that knows its depth level and context. This is important for injection safety.

  Error response (from bridge, not from API):

    {"error":"timeout"}
    {"error":"fatal"}

  Agent checks: if root-level key "error" exists → use default error message.

## F — FIFO FORMATS

  fifo_in and fifo_out (Discord <-> Agent):

    {channel_id}\t{text_with_escaped_newlines}\n

    Escaping rules:
      Literal newline in message  → \\n (two chars: backslash, n)
      Literal tab in message      → \\t (two chars: backslash, t)
      Literal backslash in message → \\\\ (two chars: backslash, backslash)

    Example input:  1234567890123456789\tHello how are you?\n
    Example output: 1234567890123456789\tI'm fine thanks!\\nHow about you?\n

  fifo_llm_req and fifo_llm_res (Agent <-> LLM):

    {compact JSON}\n\n

    Double newline (\n\n) = message delimiter.
    JSON is always on a single line (compact).

## G — BRIDGE DISCORD: bridge_discord.sh

  Interface:
    Env vars:    DISCORD_BOT_TOKEN, DISCORD_CHANNEL_ID
    FIFO read:   /tmp/plankclaw/fifo_out
    FIFO write:  /tmp/plankclaw/fifo_in
    Network:     wss://gateway.discord.gg (WebSocket via websocat)
                 https://discord.com/api/v10 (REST via curl)
    Dependencies: websocat, jq, curl

  RECEPTION subprocess (WebSocket → fifo_in):

    STARTUP:
      1. curl GET https://discord.com/api/v10/gateway
         → extract "url" field
      2. Open websocat to {url}/?v=10&encoding=json

    IDENTIFY:
      3. On receiving opcode 10 (Hello):
         → extract heartbeat_interval from d.heartbeat_interval
      4. Send Identify payload:
         {"op":2,"d":{"token":"$TOKEN","intents":512,"properties":{"os":"linux","browser":"plankclaw","device":"plankclaw"}}}
         (intents 512 = GUILD_MESSAGES, bit 9)

    LOOP:
      5. Read JSON messages from WebSocket (one per line from websocat)
      6. For each message:
         a. If op=10 (Hello) → already handled
         b. If op=11 (Heartbeat ACK) → noop
         c. If op=1 or heartbeat_interval elapsed:
            → Send {"op":1,"d":$last_sequence}
         d. If op=0 and t="MESSAGE_CREATE":
            - Extract .d.channel_id, .d.content, .d.author.id, .d.author.bot
            - IGNORE if .d.author.bot == true (prevent loops)
            - IGNORE if .d.channel_id != $DISCORD_CHANNEL_ID
            - Escape \n → \\n and \t → \\t in content
            - Write "{channel_id}\t{content}\n" to fifo_in
         e. Store .s (sequence number) for next heartbeat
      7. Back to 5

    ERROR/DISCONNECT:
      - If websocat closes: sleep 5, back to STARTUP
      - Exponential backoff: 5s, 10s, 20s, max 60s, reset on success

  SEND subprocess (fifo_out → REST):

    LOOP:
      1. Read fifo_out line by line
      2. Parse: channel_id, response (separated by \t)
      3. Unescape \\n → newline and \\t → tab
      4. curl POST https://discord.com/api/v10/channels/{channel_id}/messages
           -H "Authorization: Bot $DISCORD_BOT_TOKEN"
           -H "Content-Type: application/json"
           -d '{"content":"$response"}'
      5. If response > 2000 chars (Discord limit):
         → Split into chunks of 1990 chars
         → Send sequentially
      6. Back to 1

    ERROR:
      - HTTP 429 (rate limit): read Retry-After header, sleep, retry
      - Other errors: log to stderr, continue

## H — BRIDGE LLM: bridge_llm.sh

  Interface:
    Env var:     ANTHROPIC_API_KEY
    FIFO read:   /tmp/plankclaw/fifo_llm_req
    FIFO write:  /tmp/plankclaw/fifo_llm_res
    Dependencies: curl

  LOOP:
    1. Read fifo_llm_req until empty line (\n\n)
       → store in variable $payload
    2. curl POST https://api.anthropic.com/v1/messages \
         -H "x-api-key: $ANTHROPIC_API_KEY" \
         -H "anthropic-version: 2023-06-01" \
         -H "content-type: application/json" \
         -d "$payload" \
         --max-time 120 \
         --retry 2
    3. If success (HTTP 200):
       → write JSON response + \n\n to fifo_llm_res
    4. If failure after retries:
       → write {"error":"timeout"}\n\n to fifo_llm_res
    5. Back to 1

## I — LAUNCHER: plankclaw.sh

    #!/bin/sh
    . ./config.env

    mkdir -p /tmp/plankclaw memory
    mkfifo /tmp/plankclaw/fifo_in      2>/dev/null
    mkfifo /tmp/plankclaw/fifo_out     2>/dev/null
    mkfifo /tmp/plankclaw/fifo_llm_req 2>/dev/null
    mkfifo /tmp/plankclaw/fifo_llm_res 2>/dev/null

    [ -f memory/soul.md ]       || echo "You are a helpful personal assistant." > memory/soul.md
    [ -f memory/history.jsonl ]  || touch memory/history.jsonl
    [ -f memory/summary.md ]     || touch memory/summary.md

    ./bridge_llm.sh &
    ./plankclaw &
    ./bridge_discord.sh &

    wait

## J — CONFIG FILE: config.env.example

    export DISCORD_BOT_TOKEN="MTI3..."
    export DISCORD_CHANNEL_ID="1234567890123456789"
    export ANTHROPIC_API_KEY="sk-ant-..."
    export PLANKCLAW_DIR="./memory"
    export HISTORY_MAX="200"
    export HISTORY_KEEP="40"

## K — MEMORY FILES

  memory/soul.md — Free-form UTF-8 text. Example:

    You are Planck, a minimalist personal assistant.
    You respond in French by default.
    You are concise and direct.
    You remember previous conversations through your summary.

  memory/summary.md — Free-form UTF-8, written by LLM during compaction.
  Overwritten each time. Example:

    The user's name is Marc. He works in tech.
    He is interested in minimalist AI agents and x86-64 assembly.
    He prefers responses in French, concise.
    Current project: building the smallest possible AI agent (plankclaw).

  memory/history.jsonl — One JSON object per line. Always in user/assistant pairs.

    {"role":"user","content":"Hello"}
    {"role":"assistant","content":"Hi! How are you?"}
    {"role":"user","content":"Can you explain Unix FIFOs?"}
    {"role":"assistant","content":"FIFOs (named pipes) are..."}

## L — FILE TREE

    plankclaw/
    ├── plankclaw.asm          # Agent — x86-64 NASM assembly source
    ├── Makefile               # nasm + ld → plankclaw binary (~5 KB target)
    ├── plankclaw.sh           # Launcher
    ├── bridge_discord.sh      # Bridge Discord (websocat + jq + curl)
    ├── bridge_llm.sh          # Bridge LLM (curl)
    ├── config.env.example     # Config template
    ├── memory/
    │   ├── soul.md            # Persistent system prompt
    │   ├── summary.md         # Cumulative summary (generated)
    │   └── history.jsonl      # Raw history (generated)
    └── README.md

## M — MAKEFILE

    ASM      = nasm
    LDFLAGS  = -s -n
    TARGET   = plankclaw

    all: $(TARGET)

    $(TARGET): plankclaw.o
    	ld $(LDFLAGS) -o $@ $

    plankclaw.o: plankclaw.asm
    	$(ASM) -f elf64 -o $@ $

    size: $(TARGET)
    	wc -c $(TARGET)
    	size $(TARGET)

    clean:
    	rm -f plankclaw.o $(TARGET)

    .PHONY: all size clean

  ld flags:
    -s : strip symbols (saves ~1-2 KB)
    -n : no page alignment (allows more compact ELF binary)

## N — RUNTIME DEPENDENCIES

    Component         Requires              Default on Linux?
    ─────────         ────────              ─────────────────
    Agent             nothing (static bin)  N/A — this is our binary
    Bridge Discord    websocat, jq, curl    curl: yes. jq: usually. websocat: MUST INSTALL
    Bridge LLM        curl                  yes
    Launcher          sh, mkfifo, mkdir     yes (POSIX)

  websocat install: cargo install websocat
  or download static binary (~3 MB) from GitHub releases.

## O — JSON PARSER SPECIFICATION (for the asm agent)

  The agent implements a STRUCTURAL JSON parser, not pattern matching.
  This is critical for injection safety.

  The parser is a state machine with these states:
    STATE_ROOT        — expecting { to start object
    STATE_KEY         — inside object, expecting "key"
    STATE_COLON       — expecting : after key
    STATE_VALUE       — expecting value (string, number, object, array, bool, null)
    STATE_STRING      — inside a "string", handling \" escapes
    STATE_ARRAY       — inside [...], tracking index
    STATE_OBJECT      — inside {...}, tracking depth

  The parser tracks:
    - Current nesting depth (incremented on { or [, decremented on } or ])
    - Current array index (incremented on , within arrays)
    - A "path target" to match against (e.g., content.0.text)

  Navigation algorithm for extracting content[0].text:
    1. Enter root object (depth 0)
    2. Scan keys at depth 0 until key == "content"
    3. Enter array (depth 1)
    4. Enter first element at index 0 (depth 2, it's an object)
    5. Scan keys at depth 2 until key == "text"
    6. Extract the string value (handling \" and \\\\ escapes)
    7. Return extracted string

  For error detection:
    1. Enter root object (depth 0)
    2. Scan keys at depth 0. If key == "error" → return error flag
    3. If key == "content" → proceed with normal extraction

  This parser does NOT need to handle:
    - Numbers (we never extract numeric values)
    - Booleans or null (we never extract these)
    - Nested objects beyond depth 3
    - Unicode escape sequences \\uXXXX (pass through as-is)
    - Pretty-printed JSON (input is always compact single-line)

  Estimated size: ~500-700 bytes of x86-64 assembly.

================================================================================
IMPLEMENTATION NOTES FOR CLAUDE CODE
================================================================================

  PRIORITY ORDER:
    1. bridge_llm.sh        (simplest, can test API connectivity)
    2. bridge_discord.sh    (test Discord connectivity)
    3. plankclaw.asm        (the core challenge)
    4. plankclaw.sh         (trivial launcher)
    5. Makefile             (trivial)
    6. config.env.example   (trivial)
    7. README.md            (document everything)

  TESTING STRATEGY:
    - Test bridge_llm.sh independently:
        echo '{"model":"claude-haiku-4-5-20241022","max_tokens":64,"messages":[{"role":"user","content":"Say hello"}]}' > /tmp/plankclaw/fifo_llm_req
      and read from fifo_llm_res
    - Test agent independently by piping text to fifo_in manually
      and reading from fifo_out, with bridge_llm.sh running
    - Test bridge_discord.sh independently by monitoring fifo_in output
      when sending a message in the Discord channel

  ASM TIPS:
    - Use section .bss for all buffers (zero binary cost)
    - Use section .data for constant strings (system prompt default,
      JSON templates, FIFO paths)
    - Use section .text for code
    - All syscalls via: mov rax, SYSCALL_NUM; syscall
    - String operations: use rep movsb, rep stosb, repne scasb
    - The JSON builder can use a "template + fill" approach:
      pre-store JSON skeleton in .data with placeholder markers,
      copy to buffer, then memcpy variable content at marker positions

  BINARY SIZE TARGET: < 8 KB
    If the binary exceeds 8 KB, optimize:
    - Remove any unused code paths
    - Shorten constant strings
    - Combine similar subroutines
    - Use shorter instruction encodings where possible
