#!/bin/sh
# Starts a supervisor that restarts herdr-notify 5 s after any exit, unless one is running.
# Called at install, by cron (@reboot / every minute) and by the app on connect.
D="$(cd "$(dirname "$0")" && pwd)"

# alive PIDFILE PATTERN: pid in file is running AND its command line matches (pids get reused).
alive() {
  p="$(cat "$1" 2>/dev/null)" || return 1
  [ -n "$p" ] && kill -0 "$p" 2>/dev/null || return 1
  ps -p "$p" -o args= 2>/dev/null | grep -q -- "$2"
}

if [ "$1" = "--supervise" ]; then
  echo $$ > "$D/supervisor.pid"
  while :; do
    if [ -f "$D/log" ] && [ "$(wc -c < "$D/log")" -gt 1000000 ]; then mv "$D/log" "$D/log.1"; fi
    python3 "$D/herdr-notify.py" --config "$D/config.json" >> "$D/log" 2>&1 < /dev/null
    sleep 5
  done
fi

# One starter at a time; a lock older than a minute is left over from a killed run.
if ! mkdir "$D/start.lock" 2>/dev/null; then
  [ -n "$(find "$D/start.lock" -maxdepth 0 -mmin +1 2>/dev/null)" ] || exit 0
  rmdir "$D/start.lock" 2>/dev/null; mkdir "$D/start.lock" 2>/dev/null || exit 0
fi
trap 'rmdir "$D/start.lock" 2>/dev/null' EXIT

alive "$D/supervisor.pid" "run.sh --supervise" && exit 0
rm -f "$D/supervisor.pid"
nohup "$D/run.sh" --supervise < /dev/null > /dev/null 2>&1 &
# Hold the lock until the supervisor has registered itself.
i=0; while [ $i -lt 50 ] && ! alive "$D/supervisor.pid" "run.sh --supervise"; do sleep 0.1; i=$((i+1)); done
