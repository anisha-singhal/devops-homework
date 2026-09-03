#!/usr/bin/env bash
#
# sysinfo.sh - collect basic system information and save a report.
#
# Covers the assignment requirements: date, hostname, username, disk usage,
# running processes, variables, read -p input, mkdir, touch, and > redirection.

set -u   # abort on an unset variable rather than expanding it to empty

# ---------------------------------------------------------------------------
# Variables - collected once into variables, then reused below, so the report
# and the console output can never disagree with each other.
# ---------------------------------------------------------------------------
CURRENT_DATE=$(date "+%Y-%m-%d %H:%M:%S %Z")
HOST_NAME=$(hostname)
USER_NAME=$(whoami)
KERNEL=$(uname -sr)
UPTIME=$(uptime | sed 's/^[[:space:]]*//')
PROCESS_COUNT=$(ps -e --no-headers | wc -l | tr -d ' ')

echo "==============================================="
echo "           SYSTEM INFORMATION REPORT"
echo "==============================================="
echo

echo "--- 1. Date and time ---"
echo "$CURRENT_DATE"
echo

echo "--- 2. Hostname ---"
echo "$HOST_NAME"
echo

echo "--- 3. Current user ---"
echo "$USER_NAME  (uid=$(id -u), groups: $(id -nG | tr ' ' ','))"
echo

echo "--- 4. Kernel and uptime ---"
echo "kernel : $KERNEL"
echo "uptime : $UPTIME"
echo

echo "--- 5. Disk usage ---"
df -h
echo

echo "--- 6. Memory ---"
free -h
echo

echo "--- 7. Running processes (top 10 by memory) ---"
# --sort=-%mem puts the heaviest first; head keeps the console output readable.
# The full list still goes into the report file further down.
ps -eo pid,ppid,user,%cpu,%mem,comm --sort=-%mem | head -11
echo
echo "total processes running: $PROCESS_COUNT"
echo

# ---------------------------------------------------------------------------
# User input - read -p prompts on the same line. Defaults are applied when the
# input is empty so the script still works non-interactively (piped input, CI).
# ---------------------------------------------------------------------------
echo "-----------------------------------------------"
read -p "Enter a directory name for the report [sysinfo-reports]: " REPORT_DIR
read -p "Enter your name for the report header [$USER_NAME]: " OWNER_NAME

REPORT_DIR=${REPORT_DIR:-sysinfo-reports}
OWNER_NAME=${OWNER_NAME:-$USER_NAME}

# ---------------------------------------------------------------------------
# mkdir / touch / output redirection
# ---------------------------------------------------------------------------
REPORT_FILE="$REPORT_DIR/processes-$(date +%Y%m%d-%H%M%S).txt"

mkdir -p "$REPORT_DIR"          # -p: no error if it already exists
touch "$REPORT_FILE"            # create the empty file first

# ">" truncates and writes; ">>" appends. The first write below uses > so a
# re-run cannot append to a stale report, and everything after it uses >>.
{
  echo "System information report"
  echo "Prepared by : $OWNER_NAME"
  echo "Generated   : $CURRENT_DATE"
  echo "Host        : $HOST_NAME"
  echo "User        : $USER_NAME"
  echo "Kernel      : $KERNEL"
  echo "Uptime      : $UPTIME"
  echo
  echo "Disk usage"
  echo "----------"
} > "$REPORT_FILE"

df -h >> "$REPORT_FILE"

{
  echo
  echo "Running processes ($PROCESS_COUNT total)"
  echo "----------------------------------------"
} >> "$REPORT_FILE"

ps -eo pid,ppid,user,%cpu,%mem,comm --sort=-%mem >> "$REPORT_FILE"

echo
echo "-----------------------------------------------"
echo "Report written to : $REPORT_FILE"
echo "Size              : $(du -h "$REPORT_FILE" | cut -f1)"
echo "Lines             : $(wc -l < "$REPORT_FILE" | tr -d ' ')"
echo "-----------------------------------------------"
