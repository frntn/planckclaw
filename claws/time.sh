#!/bin/sh
#TOOLS:{"name":"get_time","description":"Get current UTC time as Unix timestamp","input_schema":{"type":"object","properties":{}}}

case "$1" in
    get_time) printf 'Unix timestamp: %s' "$(date +%s)" ;;
esac
