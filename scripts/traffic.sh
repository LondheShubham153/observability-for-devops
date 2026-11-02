#!/usr/bin/env bash
# Generate traffic against the notes app so the dashboards, traces and logs have data.
#
# Usage:  ./scripts/traffic.sh [normal|errors] [seconds]
#   normal  (default)  mix of list, create and the occasional 404
#   errors             mostly 404s, enough to trigger the HighErrorRate alert
#
# Override the target with:  APP=http://host:8000 ./scripts/traffic.sh

MODE="${1:-normal}"
SECONDS_TO_RUN="${2:-60}"
APP="${APP:-http://localhost:8000}"

if [ "$MODE" != "normal" ] && [ "$MODE" != "errors" ]; then
  echo "Usage: $0 [normal|errors] [seconds]" >&2
  exit 1
fi

if ! curl -s -o /dev/null --max-time 3 "$APP/api/notes/"; then
  echo "Cannot reach $APP. Is the stack up?  docker compose up -d --build" >&2
  exit 1
fi

echo "Sending '$MODE' traffic to $APP for ${SECONDS_TO_RUN}s (Ctrl+C to stop)..."

end=$(( $(date +%s) + SECONDS_TO_RUN ))
count=0
while [ "$(date +%s)" -lt "$end" ]; do
  if [ "$MODE" = "errors" ]; then
    # 4 failing requests for every good one
    curl -s -o /dev/null "$APP/nope"
    curl -s -o /dev/null "$APP/nope"
    curl -s -o /dev/null "$APP/nope"
    curl -s -o /dev/null "$APP/nope"
    curl -s -o /dev/null "$APP/api/notes/"
    count=$(( count + 5 ))
  else
    curl -s -o /dev/null "$APP/api/notes/"
    curl -s -o /dev/null -X POST "$APP/api/notes/create/" \
      -H 'Content-Type: application/json' -d '{"body":"traffic test note"}'
    curl -s -o /dev/null "$APP/api/notes/"
    # one 404 in every 5 rounds
    if [ $(( count % 5 )) -eq 0 ]; then
      curl -s -o /dev/null "$APP/nope"
    fi
    count=$(( count + 3 ))
  fi
  sleep 0.5
done

echo "Done: about $count requests sent. Metrics and traces show up in Grafana within ~30s."
