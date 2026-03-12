#!/bin/sh
# bridge_brain.sh — LLM brain bridge for planckclaw
# Reads JSON payloads from brain_in, sends to Anthropic API, returns responses on brain_out.
# Delimiter: double newline (\n\n)

FIFO_REQ="/tmp/planckclaw/brain_in"
FIFO_RES="/tmp/planckclaw/brain_out"

DEBUG="${PLANCKCLAW_DEBUG:-0}"

if [ -z "$ANTHROPIC_API_KEY" ]; then
    echo "bridge_brain: ANTHROPIC_API_KEY not set" >&2
    exit 1
fi

while true; do
    # Read payload until empty line (double newline delimiter)
    payload=""
    while IFS= read -r line; do
        if [ -z "$line" ]; then
            break
        fi
        if [ -z "$payload" ]; then
            payload="$line"
        else
            payload="$payload
$line"
        fi
    done < "$FIFO_REQ"

    # Skip if empty read (FIFO closed and reopened)
    if [ -z "$payload" ]; then
        continue
    fi

    # Debug: dump payload
    [ "$DEBUG" = "1" ] && printf '%s' "$payload" > /tmp/planckclaw/last_payload.json

    # Send to Anthropic API
    response=$(curl -s -w "\n%{http_code}" \
        --max-time 120 \
        -X POST "https://api.anthropic.com/v1/messages" \
        -H "x-api-key: $ANTHROPIC_API_KEY" \
        -H "anthropic-version: 2023-06-01" \
        -H "content-type: application/json" \
        -d "$payload" 2>/dev/null)

    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')

    [ "$DEBUG" = "1" ] && echo "bridge_brain: HTTP $http_code" >&2
    [ "$DEBUG" = "1" ] && [ "$http_code" != "200" ] && echo "bridge_brain: body=$body" >&2

    if [ "$http_code" = "200" ] && [ -n "$body" ]; then
        printf '%s\n\n' "$body" > "$FIFO_RES"
    else
        # Retry once
        sleep 2
        response=$(curl -s -w "\n%{http_code}" \
            --max-time 120 \
            -X POST "https://api.anthropic.com/v1/messages" \
            -H "x-api-key: $ANTHROPIC_API_KEY" \
            -H "anthropic-version: 2023-06-01" \
            -H "content-type: application/json" \
            -d "$payload" 2>/dev/null)

        http_code=$(echo "$response" | tail -n1)
        body=$(echo "$response" | sed '$d')

        if [ "$http_code" = "200" ] && [ -n "$body" ]; then
            printf '%s\n\n' "$body" > "$FIFO_RES"
        else
            # Second retry
            sleep 4
            response=$(curl -s -w "\n%{http_code}" \
                --max-time 120 \
                -X POST "https://api.anthropic.com/v1/messages" \
                -H "x-api-key: $ANTHROPIC_API_KEY" \
                -H "anthropic-version: 2023-06-01" \
                -H "content-type: application/json" \
                -d "$payload" 2>/dev/null)

            http_code=$(echo "$response" | tail -n1)
            body=$(echo "$response" | sed '$d')

            if [ "$http_code" = "200" ] && [ -n "$body" ]; then
                printf '%s\n\n' "$body" > "$FIFO_RES"
            else
                printf '{"error":"timeout"}\n\n' > "$FIFO_RES"
            fi
        fi
    fi
done
