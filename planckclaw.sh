#!/bin/sh
# planckclaw.sh — Launcher for the planckclaw AI agent
# Creates FIFOs, ensures memory files exist, starts all three processes.

set -e

# Load configuration
if [ -f ./config.env ]; then
    . ./config.env
else
    echo "planckclaw: config.env not found. Copy config.env.example to config.env and fill in your tokens." >&2
    exit 1
fi

# Kill leftover processes from previous runs
for pat in 'bridge_discord.sh' 'bridge_llm.sh' 'websocat.*planckclaw' 'sleep 86400'; do
    pkill -f "$pat" 2>/dev/null || true
done
pkill -x planckclaw 2>/dev/null || true
# Clean stale FIFOs
rm -f /tmp/planckclaw/fifo_in /tmp/planckclaw/fifo_out \
      /tmp/planckclaw/fifo_llm_req /tmp/planckclaw/fifo_llm_res \
      /tmp/planckclaw/ws_send /tmp/planckclaw/ws_recv

# Create FIFO directory and memory directory
mkdir -p /tmp/planckclaw memory

# Create FIFOs
mkfifo /tmp/planckclaw/fifo_in
mkfifo /tmp/planckclaw/fifo_out
mkfifo /tmp/planckclaw/fifo_llm_req
mkfifo /tmp/planckclaw/fifo_llm_res

# Ensure memory files exist
[ -f memory/soul.md ]       || echo "You are a helpful personal assistant." > memory/soul.md
[ -f memory/history.jsonl ] || touch memory/history.jsonl
[ -f memory/summary.md ]    || touch memory/summary.md

echo "planckclaw: starting..." >&2

# Start bridge_llm in background
./bridge_llm.sh &
LLM_PID=$!
echo "planckclaw: bridge_llm started (PID $LLM_PID)" >&2

# Start the agent binary in background
./planckclaw &
AGENT_PID=$!
echo "planckclaw: agent started (PID $AGENT_PID)" >&2

# Start bridge_discord in background
./bridge_discord.sh &
DISCORD_PID=$!
echo "planckclaw: bridge_discord started (PID $DISCORD_PID)" >&2

# Cleanup on exit — kill all children recursively
cleanup() {
    trap '' EXIT INT TERM   # disable trap to prevent recursion
    echo "planckclaw: shutting down..." >&2
    kill $LLM_PID $AGENT_PID $DISCORD_PID 2>/dev/null
    # Kill any remaining children (heartbeat, keepalive, websocat, etc.)
    pkill -P $DISCORD_PID 2>/dev/null
    pkill -P $$ 2>/dev/null
    wait 2>/dev/null
    rm -f /tmp/planckclaw/fifo_in /tmp/planckclaw/fifo_out \
          /tmp/planckclaw/fifo_llm_req /tmp/planckclaw/fifo_llm_res \
          /tmp/planckclaw/ws_send /tmp/planckclaw/ws_recv
    rmdir /tmp/planckclaw 2>/dev/null || true
    echo "planckclaw: stopped." >&2
}
trap cleanup EXIT INT TERM

# Wait for any child to exit
wait
