#!/bin/sh
# bridge_cli.sh — CLI interaction bridge for planckclaw
# Terminal-based alternative to bridge_discord.sh (Discord).
# Same FIFO protocol: {channel_id}\t{message}\n
# Uses "cli" as channel_id.

FIFO_IN="/tmp/planckclaw/interact_in"
FIFO_OUT="/tmp/planckclaw/interact_out"

# --- RECEIVE: read fifo_out, print to terminal ---
recv_loop() {
    while IFS= read -r line; do
        # Parse: channel_id\tresponse
        response=$(printf '%s' "$line" | cut -f2-)

        # Unescape \n → newline, \t → tab, \\ → backslash
        printf '%s' "$response" | sed -e 's/\\n/\n/g' -e 's/\\t/\t/g' -e 's/\\\\/\\/g'
        printf '\n'
        printf 'planckclaw> '
    done < "$FIFO_OUT"
}

# --- SEND: read terminal, write to fifo_in ---
send_loop() {
    printf 'planckclaw> '
    while IFS= read -r line; do
        [ -z "$line" ] && { printf 'planckclaw> '; continue; }

        # Escape newlines and tabs (single-line input, but be safe)
        escaped=$(printf '%s' "$line" | sed -e 's/\\/\\\\/g' -e 's/\t/\\t/g')

        # Write to fifo_in: cli\t{message}\n
        printf 'cli\t%s\n' "$escaped" > "$FIFO_IN"
    done
}

# Launch both
recv_loop &
RECV_PID=$!

send_loop
kill $RECV_PID 2>/dev/null
