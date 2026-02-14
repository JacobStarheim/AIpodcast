#!/usr/bin/env bash
set -euo pipefail

API_BASE_URL="${API_BASE_URL:-http://localhost:4000}"
ADMIN_KEY="${ADMIN_KEY:-dev-admin}"
SOURCE_NAME="${SOURCE_NAME:-Demo Podcast Source}"
RSS_URL="${RSS_URL:-https://feeds.simplecast.com/54nAGcIl}"
MAX_EPISODES="${MAX_EPISODES:-5}"

echo "Creating RSS source..."
source_response="$(curl -sS -X POST "${API_BASE_URL}/v1/admin/sources" \
  -H "Content-Type: application/json" \
  -H "x-admin-key: ${ADMIN_KEY}" \
  --data "{\"name\":\"${SOURCE_NAME}\",\"rssUrl\":\"${RSS_URL}\"}")"

echo "Source response: ${source_response}"

source_id=""
if command -v jq >/dev/null 2>&1; then
  source_id="$(printf '%s' "${source_response}" | jq -r '.id // empty')"
fi

echo "Queueing ingest job..."
if [[ -n "${source_id}" ]]; then
  ingest_payload="{\"sourceId\":\"${source_id}\",\"maxEpisodesPerSource\":${MAX_EPISODES}}"
else
  ingest_payload="{\"maxEpisodesPerSource\":${MAX_EPISODES}}"
fi

curl -sS -X POST "${API_BASE_URL}/v1/admin/ingest/run" \
  -H "Content-Type: application/json" \
  -H "x-admin-key: ${ADMIN_KEY}" \
  --data "${ingest_payload}"

echo ""
echo "Seed complete. Worker will ingest/transcribe queued episodes."
