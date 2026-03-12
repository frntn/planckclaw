#!/bin/sh
#TOOLS:{"name":"system_status","description":"Get system uptime, memory, load, and process count","input_schema":{"type":"object","properties":{}}}

case "$1" in
    system_status)
        uptime_sec=$(awk '{print int($1)}' /proc/uptime)
        mem_total=$(awk '/MemTotal/ {print $2 * 1024}' /proc/meminfo)
        mem_free=$(awk '/MemAvailable/ {print $2 * 1024}' /proc/meminfo)
        load=$(awk '{print $1}' /proc/loadavg)
        procs=$(awk '{print $4}' /proc/loadavg | cut -d/ -f2)
        printf 'Uptime: %s seconds, Total RAM: %s bytes, Free RAM: %s bytes, Load (1m): %s, Processes: %s' \
            "$uptime_sec" "$mem_total" "$mem_free" "$load" "$procs"
        ;;
esac
