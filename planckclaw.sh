#!/bin/sh
# planckclaw.sh — Launcher for the planckclaw AI agent
# Creates 6 FIFOs (3 bridge pairs), ensures memory files exist, starts all 4 processes.
# Usage: ./planckclaw.sh [interact_bridge]
#   interact_bridge: path to the interact bridge script (default: ./bridge_discord.sh)
#   Example: ./planckclaw.sh ./bridge_cli.sh

set -e

INTERACT_BRIDGE="${1:-./bridge_cli.sh}"

if [ ! -x "$INTERACT_BRIDGE" ]; then
    echo "planckclaw: interact bridge '$INTERACT_BRIDGE' not found or not executable." >&2
    exit 1
fi

# Load configuration
if [ -f ./config.env ]; then
    . ./config.env
else
    echo "planckclaw: config.env not found. Copy config.env.example to config.env and fill in your tokens." >&2
    exit 1
fi

# Kill leftover processes from previous runs (exclude ourselves)
for pat in 'bridge_discord.sh' 'bridge_cli.sh' 'bridge_brain.sh' 'bridge_claw.sh' 'websocat.*planckclaw' 'sleep 86400'; do
    for pid in $(pgrep -f "$pat" 2>/dev/null); do
        [ "$pid" = "$$" ] && continue
        kill "$pid" 2>/dev/null || true
    done
done
pkill -x planckclaw 2>/dev/null || true

# Clean stale FIFOs
rm -f /tmp/planckclaw/interact_in /tmp/planckclaw/interact_out \
      /tmp/planckclaw/brain_in /tmp/planckclaw/brain_out \
      /tmp/planckclaw/claw_in /tmp/planckclaw/claw_out \
      /tmp/planckclaw/ws_send /tmp/planckclaw/ws_recv

# Secure FIFO directory — owner-only access (API keys transit in clear)
umask 077
mkdir -p /tmp/planckclaw memory claws

# Create 6 FIFOs (3 bridge pairs)
mkfifo /tmp/planckclaw/interact_in
mkfifo /tmp/planckclaw/interact_out
mkfifo /tmp/planckclaw/brain_in
mkfifo /tmp/planckclaw/brain_out
mkfifo /tmp/planckclaw/claw_in
mkfifo /tmp/planckclaw/claw_out

# Ensure memory files exist
[ -f memory/soul.md ]       || echo "You are a helpful personal assistant." > memory/soul.md
[ -f memory/history.jsonl ] || touch memory/history.jsonl
[ -f memory/summary.md ]    || touch memory/summary.md

echo "planckclaw: starting..." >&2

# Save terminal stdin — POSIX redirects stdin to /dev/null for & processes
exec 3<&0

# Start bridges and agent
./bridge_brain.sh &
BRAIN_PID=$!
echo "planckclaw: bridge_brain started (PID $BRAIN_PID)" >&2

./bridge_claw.sh &
CLAW_PID=$!
echo "planckclaw: bridge_claw started (PID $CLAW_PID)" >&2

./planckclaw &
AGENT_PID=$!
echo "planckclaw: agent started (PID $AGENT_PID)" >&2

echo "planckclaw: $(basename "$INTERACT_BRIDGE") starting..." >&2
"$INTERACT_BRIDGE" <&3 &
INTERACT_PID=$!
exec 3<&-

# Cleanup on exit — kill all children recursively
cleanup() {
    trap '' EXIT INT TERM
    echo "planckclaw: shutting down..." >&2
    kill $BRAIN_PID $CLAW_PID $AGENT_PID $INTERACT_PID 2>/dev/null
    pkill -P $INTERACT_PID 2>/dev/null
    pkill -P $$ 2>/dev/null
    wait 2>/dev/null
    rm -f /tmp/planckclaw/interact_in /tmp/planckclaw/interact_out \
          /tmp/planckclaw/brain_in /tmp/planckclaw/brain_out \
          /tmp/planckclaw/claw_in /tmp/planckclaw/claw_out \
          /tmp/planckclaw/ws_send /tmp/planckclaw/ws_recv
    rmdir /tmp/planckclaw 2>/dev/null || true
    echo "planckclaw: stopped." >&2
}
trap cleanup EXIT INT TERM

# Wait for any child to exit
wait
