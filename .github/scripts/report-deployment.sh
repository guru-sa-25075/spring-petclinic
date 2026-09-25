#!/usr/bin/env bash
# Report a deployment to Cursor Rollouts.
#
#   report-deployment.sh bootstrap   # idempotent environment + service rows
#   report-deployment.sh start       # open the deployment (reuses one on retry)
#   report-deployment.sh finish      # close it: succeeded, failed, or aborted
#
# Environment and service come from CHANGE_MONITOR_ENV and CHANGE_MONITOR_SERVICE.
# The API key comes from CURSOR_API_KEY. A failure here must not fail the deploy;
# callers set their own failure tolerance.

set -euo pipefail

COMMAND="${1:-}"

: "${CHANGE_MONITOR_ENV:?CHANGE_MONITOR_ENV is required}"
: "${CHANGE_MONITOR_SERVICE:?CHANGE_MONITOR_SERVICE is required}"

if [[ -z "${CURSOR_API_KEY:-}" ]]; then
  echo "CURSOR_API_KEY is not set; skipping Rollouts deployment report" >&2
  exit 1
fi

DEPLOY_SOURCE_URI="${DEPLOY_SOURCE_URI:?DEPLOY_SOURCE_URI is required}"
DEPLOY_VERSION="${DEPLOY_VERSION:-${GITHUB_SHA:-}}"
ACTOR="${CHANGE_MONITOR_ACTOR:?CHANGE_MONITOR_ACTOR is required}"
STATE_FILE="${CHANGE_MONITOR_STATE_FILE:-${RUNNER_TEMP:-/tmp}/cursor-rollouts-deployment.json}"

if [[ -z "$DEPLOY_VERSION" ]]; then
  echo "DEPLOY_VERSION (or GITHUB_SHA) is required" >&2
  exit 1
fi

TOKEN=""
AUTH_URL="${ROLLOUTS_AUTH_URL:-https://api2.cursor.sh/auth/exchange_user_api_key}"
FACTORY_URL="${ROLLOUTS_FACTORY_URL:-https://api.cursor.com/factory.v1.DeploymentsService}"

exchange_token() {
  local body code
  body=$(mktemp)
  code=$(curl -sS --connect-timeout 10 --max-time 30 -o "$body" -w "%{http_code}" \
    -X POST "$AUTH_URL" \
    -H "Authorization: Bearer ${CURSOR_API_KEY}" \
    -H "Content-Type: application/json" \
    -d '{}')
  if [[ "$code" != "200" ]]; then
    echo "token exchange failed with HTTP ${code}: $(cat "$body")" >&2
    rm -f "$body"
    exit 1
  fi
  TOKEN=$(jq -er '.accessToken' "$body")
  rm -f "$body"
}

# POST a Factory RPC. Prints the response body. Exits on unexpected HTTP errors.
# Pass "allow_conflict" as the third argument to treat HTTP 409 as success.
factory_post() {
  local url="$1"
  local payload="$2"
  local conflict="${3:-}"
  local body code
  body=$(mktemp)
  code=$(curl -sS --connect-timeout 10 --max-time 30 -o "$body" -w "%{http_code}" \
    -X POST "$url" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -H "Connect-Protocol-Version: 1" \
    --data "$payload")
  if [[ "$code" == "409" && "$conflict" == "allow_conflict" ]]; then
    rm -f "$body"
    return 0
  fi
  if [[ "$code" != "200" ]]; then
    echo "Factory call ${url} failed with HTTP ${code}: $(cat "$body")" >&2
    rm -f "$body"
    exit 1
  fi
  cat "$body"
  rm -f "$body"
}

bootstrap() {
  exchange_token
  local env_body service_body
  env_body=$(jq -nc --arg id "$CHANGE_MONITOR_ENV" \
    '{environmentId:$id,environment:{displayName:$id}}')
  service_body=$(jq -nc --arg id "$CHANGE_MONITOR_SERVICE" \
    '{serviceId:$id,service:{displayName:$id}}')
  factory_post "${FACTORY_URL}/CreateEnvironment" \
    "$env_body" allow_conflict >/dev/null
  factory_post "${FACTORY_URL}/CreateService" \
    "$service_body" allow_conflict >/dev/null
  echo "Rollouts catalog ready for ${CHANGE_MONITOR_ENV}/${CHANGE_MONITOR_SERVICE}"
}

list_payload() {
  jq -nc \
    --arg src "$DEPLOY_SOURCE_URI" \
    --arg env "$CHANGE_MONITOR_ENV" \
    --arg sha "$DEPLOY_VERSION" \
    --arg svc "$CHANGE_MONITOR_SERVICE" \
    '
    def esc: gsub("\\\\"; "\\\\") | gsub("\""; "\\\"");
    {
      deploySourceUri:$src,
      filter:("environment = \"environments/" + ($env|esc) + "\" AND deploy_version = \"" + ($sha|esc) + "\" AND service = \"services/" + ($svc|esc) + "\""),
      pageSize:100,
      readMask:"events"
    }'
}

# Prints the matching deployment JSON, or nothing when this actor has not opened one.
find_own_deployment() {
  local raw
  raw=$(factory_post "${FACTORY_URL}/ListDeployments" "$(list_payload)")
  jq -c --arg actor "$ACTOR" '
    [(.deployments // [])[] | select(any(.events[]?; .actor == $actor))] | first // empty
  ' <<<"$raw"
}

deployment_already_closed() {
  local deployment="$1"
  jq -e --arg actor "$ACTOR" '
    any(.events[]?; .actor == $actor and ((.completed != null) or (.aborted != null)))
  ' <<<"$deployment" >/dev/null
}

write_state() {
  local name="$1"
  local closed="$2"
  mkdir -p "$(dirname "$STATE_FILE")"
  jq -nc --arg name "$name" --argjson closed "$closed" '{name:$name,closed:$closed}' >"$STATE_FILE"
}

start_deployment() {
  exchange_token
  local existing name closed
  existing=$(find_own_deployment)
  if [[ -n "$existing" ]]; then
    name=$(jq -er '.name' <<<"$existing")
    if deployment_already_closed "$existing"; then
      closed=true
    else
      closed=false
    fi
    write_state "$name" "$closed"
    echo "Reusing Rollouts deployment ${name}"
    return 0
  fi

  local payload response
  payload=$(jq -nc \
    --arg src "$DEPLOY_SOURCE_URI" \
    --arg env "$CHANGE_MONITOR_ENV" \
    --arg sha "$DEPLOY_VERSION" \
    --arg svc "$CHANGE_MONITOR_SERVICE" \
    --arg actor "$ACTOR" \
    '{
      deployment:{
        deploySourceUri:$src,
        environment:("environments/" + $env),
        deployVersion:$sha,
        service:("services/" + $svc)
      },
      event:{started:{},actor:$actor}
    }')
  response=$(factory_post "${FACTORY_URL}/CreateDeployment" "$payload")
  name=$(jq -er '.deployment.name' <<<"$response")
  write_state "$name" false
  echo "Opened Rollouts deployment ${name}"
}

ship_result() {
  local deploy="${DEPLOY_OUTCOME:-}"
  local wait="${WAIT_OUTCOME:-}"
  if [[ "$deploy" == "cancelled" || "$wait" == "cancelled" ]]; then
    echo aborted
    return
  fi
  if [[ "$deploy" == "failure" || "$wait" == "failure" ]]; then
    echo failed
    return
  fi
  if [[ "$deploy" == "success" && "$wait" == "success" ]]; then
    echo succeeded
    return
  fi
  echo aborted
}

failure_message() {
  local deploy="${DEPLOY_OUTCOME:-}"
  local wait="${WAIT_OUTCOME:-}"
  if [[ "$deploy" == "failure" && "$wait" == "failure" ]]; then
    echo "kubectl apply failed; pods were not ready"
  elif [[ "$deploy" == "failure" ]]; then
    echo "kubectl apply failed"
  elif [[ "$wait" == "failure" ]]; then
    echo "pods were not ready"
  else
    echo "deploy failed"
  fi
}

finish_event() {
  local result="$1"
  local message
  case "$result" in
    succeeded)
      jq -nc --arg actor "$ACTOR" '{completed:{succeeded:{}},actor:$actor}'
      ;;
    failed)
      message=$(failure_message)
      jq -nc --arg actor "$ACTOR" --arg message "$message" \
        '{completed:{failed:{message:$message}},actor:$actor}'
      ;;
    aborted)
      jq -nc --arg actor "$ACTOR" '{aborted:{},actor:$actor}'
      ;;
    *)
      echo "unknown ship result: ${result}" >&2
      exit 1
      ;;
  esac
}

finish_deployment() {
  exchange_token
  local name="" existing closed
  existing=$(find_own_deployment)
  if [[ -n "$existing" ]]; then
    name=$(jq -er '.name' <<<"$existing")
    if deployment_already_closed "$existing"; then
      write_state "$name" true
      echo "Rollouts deployment ${name} is already closed"
      return 0
    fi
  elif [[ -f "$STATE_FILE" ]]; then
    name=$(jq -er '.name' "$STATE_FILE")
    # jq -e treats JSON false as a failed exit, which aborts under set -e.
    closed=$(jq -r '.closed' "$STATE_FILE")
    if [[ "$closed" == "true" ]]; then
      echo "Rollouts deployment ${name} is already closed"
      return 0
    fi
  else
    echo "No Rollouts deployment to close for ${CHANGE_MONITOR_ENV}/${CHANGE_MONITOR_SERVICE} @ ${DEPLOY_VERSION}"
    return 0
  fi

  local result event payload
  result=$(ship_result)
  event=$(finish_event "$result")
  payload=$(jq -nc --arg name "$name" --argjson event "$event" '{name:$name,event:$event}')
  factory_post "${FACTORY_URL}/AppendDeploymentEvent" "$payload" >/dev/null
  write_state "$name" true
  echo "Closed Rollouts deployment ${name} (${result})"
}

case "$COMMAND" in
  bootstrap) bootstrap ;;
  start) start_deployment ;;
  finish) finish_deployment ;;
  *)
    echo "usage: $0 bootstrap|start|finish" >&2
    exit 1
    ;;
esac
