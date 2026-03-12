#!/bin/sh
# plankclaw.sh — Launcher for the plankclaw AI agent
# Creates FIFOs, ensures memory files exist, starts all three processes.

set -e

# Load configuration
if [ -f ./config.env ]; then
    . ./config.env
else
    echo "plankclaw: config.env not found. Copy config.env.example to config.env and fill in your tokens." >&2
    exit 1
fi

# Create FIFO directory and memory directory
mkdir -p /tmp/plankclaw memory

# Create FIFOs (ignore error if they already exist)
mkfifo /tmp/plankclaw/fifo_in      2>/dev/null || true
mkfifo /tmp/plankclaw/fifo_out     2>/dev/null || true
mkfifo /tmp/plankclaw/fifo_llm_req 2>/dev/null || true
mkfifo /tmp/plankclaw/fifo_llm_res 2>/dev/null || true

# Ensure memory files exist
[ -f memory/soul.md ]       || echo "You are a helpful personal assistant." > memory/soul.md
[ -f memory/history.jsonl ] || touch memory/history.jsonl
[ -f memory/summary.md ]    || touch memory/summary.md

echo "plankclaw: starting..." >&2

# Start bridge_llm in background
./bridge_llm.sh &
LLM_PID=$!
echo "plankclaw: bridge_llm started (PID $LLM_PID)" >&2

# Start the agent binary in background
./plankclaw &
AGENT_PID=$!
echo "plankclaw: agent started (PID $AGENT_PID)" >&2

# Start bridge_discord in background
./bridge_discord.sh &
DISCORD_PID=$!
echo "plankclaw: bridge_discord started (PID $DISCORD_PID)" >&2

# Cleanup on exit
cleanup() {
    echo "plankclaw: shutting down..." >&2
    kill $LLM_PID $AGENT_PID $DISCORD_PID 2>/dev/null
    rm -f /tmp/plankclaw/fifo_in /tmp/plankclaw/fifo_out \
          /tmp/plankclaw/fifo_llm_req /tmp/plankclaw/fifo_llm_res
    rmdir /tmp/plankclaw 2>/dev/null || true
    echo "plankclaw: stopped." >&2
}
trap cleanup EXIT INT TERM

# Wait for any child to exit
wait
