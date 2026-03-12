#!/bin/sh
# bridge_discord.sh — Discord bridge for planckclaw
# Connects to Discord Gateway via websocat, relays messages through FIFOs.
# Dependencies: websocat, jq, curl

FIFO_IN="/tmp/planckclaw/fifo_in"
FIFO_OUT="/tmp/planckclaw/fifo_out"

if [ -z "$DISCORD_BOT_TOKEN" ]; then
    echo "bridge_discord: DISCORD_BOT_TOKEN not set" >&2
    exit 1
fi

if [ -z "$DISCORD_CHANNEL_ID" ]; then
    echo "bridge_discord: DISCORD_CHANNEL_ID not set" >&2
    exit 1
fi

API_BASE="https://discord.com/api/v10"

# --- SEND SUBPROCESS: fifo_out → Discord REST API ---
send_loop() {
    while IFS= read -r line; do
        # Parse channel_id and response separated by tab
        channel_id=$(printf '%s' "$line" | cut -f1)
        raw_response=$(printf '%s' "$line" | cut -f2-)

        # Unescape \n → newline, \t → tab, \\ → backslash
        response=$(printf '%s' "$raw_response" | sed -e 's/\\n/\n/g' -e 's/\\t/\t/g' -e 's/\\\\/\\/g')

        # Check length — Discord limit is 2000 chars
        len=$(printf '%s' "$response" | wc -c)

        if [ "$len" -le 2000 ]; then
            # Send single message
            json_body=$(printf '%s' "$response" | jq -Rs '{content: .}')
            curl -s -X POST "$API_BASE/channels/$channel_id/messages" \
                -H "Authorization: Bot $DISCORD_BOT_TOKEN" \
                -H "Content-Type: application/json" \
                -d "$json_body" > /dev/null 2>&1

            # Handle rate limiting
            if [ $? -ne 0 ]; then
                echo "bridge_discord: send failed" >&2
            fi
        else
            # Split into chunks of 1990 chars
            printf '%s' "$response" | fold -w 1990 -s | while IFS= read -r chunk; do
                json_body=$(printf '%s' "$chunk" | jq -Rs '{content: .}')
                curl -s -X POST "$API_BASE/channels/$channel_id/messages" \
                    -H "Authorization: Bot $DISCORD_BOT_TOKEN" \
                    -H "Content-Type: application/json" \
                    -d "$json_body" > /dev/null 2>&1
                sleep 1
            done
        fi
    done < "$FIFO_OUT"
}

# --- RECEIVE SUBPROCESS: Discord WebSocket → fifo_in ---
recv_loop() {
    backoff=5
    ws_send="/tmp/planckclaw/ws_send"
    ws_recv="/tmp/planckclaw/ws_recv"

    while true; do
        # Get gateway URL
        gateway_url=$(curl -s "$API_BASE/gateway" \
            -H "Authorization: Bot $DISCORD_BOT_TOKEN" | jq -r '.url')

        if [ -z "$gateway_url" ] || [ "$gateway_url" = "null" ]; then
            echo "bridge_discord: failed to get gateway URL, retrying in ${backoff}s" >&2
            sleep "$backoff"
            backoff=$((backoff * 2))
            [ "$backoff" -gt 60 ] && backoff=60
            continue
        fi

        last_seq="null"

        # Named pipes for bidirectional WebSocket communication
        mkfifo "$ws_send" 2>/dev/null || true
        mkfifo "$ws_recv" 2>/dev/null || true

        # Keep ws_send open so websocat doesn't see EOF on stdin
        sleep 86400 > "$ws_send" &
        KEEPALIVE_PID=$!

        # Start websocat: reads from ws_send, writes to ws_recv
        websocat -t "$gateway_url/?v=10&encoding=json" < "$ws_send" > "$ws_recv" 2>/dev/null &
        WS_PID=$!

        # Read from ws_recv in the current shell (no subshell — variables persist)
        while IFS= read -r msg; do
            op=$(printf '%s' "$msg" | jq -r '.op // empty')
            t=$(printf '%s' "$msg" | jq -r '.t // empty')
            seq=$(printf '%s' "$msg" | jq -r '.s // empty')

            # Update sequence number
            if [ -n "$seq" ] && [ "$seq" != "null" ]; then
                last_seq="$seq"
            fi

            case "$op" in
                10)
                    # Hello — extract heartbeat interval and send Identify
                    heartbeat_interval=$(printf '%s' "$msg" | jq -r '.d.heartbeat_interval')

                    printf '{"op":2,"d":{"token":"%s","intents":4608,"properties":{"os":"linux","browser":"planckclaw","device":"planckclaw"}}}\n' \
                        "$DISCORD_BOT_TOKEN" > "$ws_send"

                    echo "bridge_discord: identified, starting heartbeat (${heartbeat_interval}ms)" >&2

                    # Start heartbeat in background
                    (
                        hb_interval_sec=$((heartbeat_interval / 1000))
                        while true; do
                            sleep "$hb_interval_sec"
                            printf '{"op":1,"d":%s}\n' "$last_seq" > "$ws_send"
                        done
                    ) &
                    HB_PID=$!
                    ;;
                1)
                    # Heartbeat request
                    printf '{"op":1,"d":%s}\n' "$last_seq" > "$ws_send"
                    ;;
                11)
                    # Heartbeat ACK — noop
                    ;;
                0)
                    # Dispatch event
                    if [ "$t" = "MESSAGE_CREATE" ]; then
                        msg_channel=$(printf '%s' "$msg" | jq -r '.d.channel_id')
                        msg_content=$(printf '%s' "$msg" | jq -r '.d.content')
                        msg_bot=$(printf '%s' "$msg" | jq -r '.d.author.bot // false')

                        # Ignore bot messages
                        if [ "$msg_bot" = "true" ]; then
                            continue
                        fi

                        # Ignore messages from other channels
                        if [ "$msg_channel" != "$DISCORD_CHANNEL_ID" ]; then
                            continue
                        fi

                        echo "bridge_discord: message from $msg_channel" >&2

                        # Escape newlines and tabs in content
                        escaped_content=$(printf '%s' "$msg_content" | sed -e 's/\\/\\\\/g' -e 's/\t/\\t/g' | tr '\n' ' ')

                        # Write to fifo_in
                        printf '%s\t%s\n' "$msg_channel" "$escaped_content" > "$FIFO_IN"
                    fi
                    ;;
            esac
        done < "$ws_recv"

        # websocat disconnected — clean up
        [ -n "$HB_PID" ] && kill "$HB_PID" 2>/dev/null
        kill "$WS_PID" "$KEEPALIVE_PID" 2>/dev/null
        rm -f "$ws_send" "$ws_recv"
        echo "bridge_discord: disconnected, reconnecting in ${backoff}s" >&2
        sleep "$backoff"
        backoff=$((backoff * 2))
        [ "$backoff" -gt 60 ] && backoff=60
    done
}

# Launch both subprocesses
send_loop &
SEND_PID=$!

recv_loop &
RECV_PID=$!

# Wait for either to exit
wait $SEND_PID $RECV_PID
