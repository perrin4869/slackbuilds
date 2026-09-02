#!/bin/bash
# Reconcile the set of projects tracked on newreleases.io with packages/*.conf,
# so adding a package here doesn't also require remembering to add it by hand
# on their site. Idempotent - safe to run on every detect.yml invocation.
#
# Only GitHub-sourced, non-frozen packages are synced: newreleases.io is the
# *trigger* (repository_dispatch -> detect.yml), not the source of truth for
# versions, and non-GitHub sources (wofi/sr.ht, libtraceevent/kernel.org)
# aren't covered by any of their providers - those rely on the daily cron
# backstop in detect.yml instead.
#
# API reference: https://newreleases.io/api/v1
#
# Requires:
#   NEWRELEASES_API_KEY       - account API key (sent as X-Key header)
#   NEWRELEASES_WEBHOOK_ID    - id of a webhook already configured on the
#                                account (Settings > Webhooks) pointing at
#                                this repo's `repository_dispatch` endpoint.
#                                Created once by hand; this script does not
#                                create webhooks, only attaches this one.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib.sh

: "${NEWRELEASES_API_KEY:?NEWRELEASES_API_KEY not set}"
: "${NEWRELEASES_WEBHOOK_ID:?NEWRELEASES_WEBHOOK_ID not set}"

API="https://api.newreleases.io/v1"

nr_api() {
    local method="$1" path="$2" body="${3:-}"
    if [ -n "$body" ]; then
        curl -sS -X "$method" "${API}${path}" \
            -H "X-Key: ${NEWRELEASES_API_KEY}" -H 'Content-Type: application/json' \
            -d "$body"
    else
        curl -sS -X "$method" "${API}${path}" -H "X-Key: ${NEWRELEASES_API_KEY}"
    fi
}

log "fetching currently tracked projects"
existing_json="$(nr_api GET /projects)"

for conf in packages/*.conf; do
    [ -e "$conf" ] || continue
    load_package_conf "$conf"

    if [ "${FROZEN:-0}" = "1" ]; then
        log "$PRGNAM: frozen, not tracking on newreleases.io"
        continue
    fi
    if [ "$SOURCE" != github ]; then
        log "$PRGNAM: SOURCE=$SOURCE not supported by newreleases.io sync, relying on cron backstop"
        continue
    fi

    existing="$(printf '%s' "$existing_json" \
        | jq -r --arg name "$GITHUB_REPO" '.projects[]? | select(.provider=="github" and .name==$name)')"

    if [ -z "$existing" ]; then
        log "$PRGNAM: adding $GITHUB_REPO to newreleases.io"
        nr_api POST /projects "$(jq -n \
            --arg name "$GITHUB_REPO" --arg hook "$NEWRELEASES_WEBHOOK_ID" \
            '{provider: "github", name: $name, exclude_prereleases: true, webhooks: [$hook]}')" \
            | jq -e '.project // empty' >/dev/null \
            || log "warn: $PRGNAM: add failed: $(nr_api POST /projects "{}" 2>&1 | head -c 200)"
        continue
    fi

    id="$(printf '%s' "$existing" | jq -r '.id')"
    has_hook="$(printf '%s' "$existing" | jq -r --arg h "$NEWRELEASES_WEBHOOK_ID" '(.webhooks // []) | index($h) != null')"
    if [ "$has_hook" != "true" ]; then
        log "$PRGNAM: attaching webhook to existing project $GITHUB_REPO"
        hooks="$(printf '%s' "$existing" | jq -c --arg h "$NEWRELEASES_WEBHOOK_ID" '(.webhooks // []) + [$h]')"
        nr_api POST "/projects/${id}" "$(jq -n --argjson hooks "$hooks" '{webhooks: $hooks}')" >/dev/null
    else
        log "$PRGNAM: already tracked with webhook attached"
    fi
done
