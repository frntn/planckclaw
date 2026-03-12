#!/bin/sh
# bridge_claw.sh — Claw bridge for planckclaw
# Handles tool discovery (__list_tools__) and tool execution via FIFOs.
# Discovery: scans claws/*.sh for #TOOLS: lines using builtins (zero fork).
# Execution: runs the matching claw script (one fork per call).
#
# Protocol:
#   Request:  __list_tools__\n        → responds with tools JSON array\n\n
#   Request:  {name}\t{input_json}\n  → responds with result text\n\n

FIFO_IN="/tmp/planckclaw/claw_in"
FIFO_OUT="/tmp/planckclaw/claw_out"
CLAWS_DIR="${CLAWS_DIR:-./claws}"

while true; do
    while IFS= read -r line; do
        # Skip empty lines
        [ -z "$line" ] && continue

        if [ "$line" = "__list_tools__" ]; then
            # Discovery: scan #TOOLS: lines with builtins — zero fork
            tools="["
            sep=""
            for f in "$CLAWS_DIR"/*.sh; do
                [ -f "$f" ] || continue
                while IFS= read -r tline; do
                    case "$tline" in
                        '#TOOLS:'*) tools="${tools}${sep}${tline#\#TOOLS:}"; sep="," ;;
                    esac
                done < "$f"
            done
            tools="${tools}]"
            printf '%s\n\n' "$tools" > "$FIFO_OUT"
        else
            # Tool execution: parse name\tinput
            name=$(printf '%s' "$line" | cut -f1)
            input=$(printf '%s' "$line" | cut -f2-)

            # Find and execute the matching claw
            result=""
            for f in "$CLAWS_DIR"/*.sh; do
                [ -x "$f" ] || continue
                result=$("$f" "$name" "$input")
                [ -n "$result" ] && break
            done
            [ -z "$result" ] && result="Unknown tool: ${name}"

            printf '%s\n\n' "$result" > "$FIFO_OUT"
        fi
    done < "$FIFO_IN"
done
