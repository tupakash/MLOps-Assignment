#!/usr/bin/env bash
set -euo pipefail

workspace_id="${1:?Usage: publish-grafana-dashboard.sh WORKSPACE_ID ENDPOINT REGION PROJECT_NAME}"
workspace_endpoint="${2:?Usage: publish-grafana-dashboard.sh WORKSPACE_ID ENDPOINT REGION PROJECT_NAME}"
region="${3:?Usage: publish-grafana-dashboard.sh WORKSPACE_ID ENDPOINT REGION PROJECT_NAME}"
project_name="${4:?Usage: publish-grafana-dashboard.sh WORKSPACE_ID ENDPOINT REGION PROJECT_NAME}"

dashboard_file="grafana/dashboards/api-monitoring.json"
base_url="${workspace_endpoint%/}"
key_name="dashboard-deploy-${GITHUB_RUN_ID:-manual}-$(date +%s)"
api_key=""
response_file="$(mktemp)"

cleanup() {
    exit_code=$?
    trap - EXIT
    if [[ -n "$api_key" ]]; then
        if ! aws grafana delete-workspace-api-key \
            --workspace-id "$workspace_id" \
            --key-name "$key_name" \
            >/dev/null; then
            echo "::error::Failed to delete temporary Grafana API key '$key_name'."
            if [[ "$exit_code" == "0" ]]; then
                exit_code=1
            fi
        fi
    fi
    rm -f "$response_file"
    exit "$exit_code"
}
trap cleanup EXIT

for attempt in {1..30}; do
    status_code="$(curl --silent --show-error --output /dev/null \
        --write-out '%{http_code}' "$base_url/api/health")"
    if [[ "$status_code" == "200" ]]; then
        break
    fi
    if [[ "$attempt" == "30" ]]; then
        echo "::error::AWS Managed Grafana workspace API did not become ready."
        exit 1
    fi
    sleep 10
done

api_key="$(aws grafana create-workspace-api-key \
    --workspace-id "$workspace_id" \
    --key-name "$key_name" \
    --key-role ADMIN \
    --seconds-to-live 900 \
    --query key \
    --output text)"
if [[ -z "$api_key" || "$api_key" == "None" ]]; then
    echo "::error::AWS did not return a temporary Grafana dashboard API key."
    exit 1
fi

datasource_payload="$(jq -n \
    --arg region "$region" \
    '{
      name: "CloudWatch",
      uid: "cloudwatch",
      type: "cloudwatch",
      access: "proxy",
      isDefault: true,
      editable: false,
      jsonData: {
        authType: "default",
        defaultRegion: $region
      }
    }')"

datasource_status="$(curl --silent --show-error \
    --output "$response_file" \
    --write-out '%{http_code}' \
    --header "Authorization: Bearer $api_key" \
    "$base_url/api/datasources/uid/cloudwatch")"
if [[ "$datasource_status" == "200" ]]; then
    curl --fail-with-body --silent --show-error \
        --request PUT \
        --header "Authorization: Bearer $api_key" \
        --header "Content-Type: application/json" \
        --data "$datasource_payload" \
        "$base_url/api/datasources/uid/cloudwatch" >/dev/null
elif [[ "$datasource_status" == "404" ]]; then
    curl --fail-with-body --silent --show-error \
        --request POST \
        --header "Authorization: Bearer $api_key" \
        --header "Content-Type: application/json" \
        --data "$datasource_payload" \
        "$base_url/api/datasources" >/dev/null
else
    cat "$response_file"
    echo "::error::Could not inspect the CloudWatch Grafana data source (HTTP $datasource_status)."
    exit 1
fi

health_status="$(curl --silent --show-error \
    --output "$response_file" \
    --write-out '%{http_code}' \
    --header "Authorization: Bearer $api_key" \
    "$base_url/api/datasources/uid/cloudwatch/health")"
if [[ "$health_status" != "200" ]] || ! grep -q '"status"[[:space:]]*:[[:space:]]*"OK"' "$response_file"; then
    cat "$response_file"
    echo "::error::CloudWatch data source health check failed for AWS region $region."
    exit 1
fi

query_payload="$(jq -n \
    --arg region "$region" \
    --arg log_group "/ecs/${project_name}" \
    '{
      from: "now-15m",
      to: "now",
      queries: [{
        datasource: {type: "cloudwatch", uid: "cloudwatch"},
        refId: "A",
        queryMode: "Logs",
        region: $region,
        expression: "fields @timestamp | limit 1",
        logGroups: [{name: $log_group}],
        intervalMs: 1000,
        maxDataPoints: 100
      }]
    }')"
query_status="$(curl --silent --show-error \
    --output "$response_file" \
    --write-out '%{http_code}' \
    --request POST \
    --header "Authorization: Bearer $api_key" \
    --header "Content-Type: application/json" \
    --data "$query_payload" \
    "$base_url/api/ds/query")"
if [[ "$query_status" != "200" ]] || ! jq -e '(.results.A? != null) and ((.results.A.error? // "") == "")' "$response_file" >/dev/null; then
    cat "$response_file"
    echo "::error::CloudWatch Logs Insights query access failed for /ecs/${project_name} in $region."
    exit 1
fi

dashboard_payload="$(jq -n \
    --slurpfile dashboard "$dashboard_file" \
    --arg message "Provisioned from ${GITHUB_SHA:-local} for ${project_name}" \
    '{
      dashboard: $dashboard[0],
      folderId: 0,
      overwrite: true,
      message: $message
    }')"
curl --fail-with-body --silent --show-error \
    --request POST \
    --header "Authorization: Bearer $api_key" \
    --header "Content-Type: application/json" \
    --data "$dashboard_payload" \
    "$base_url/api/dashboards/db" >/dev/null

echo "Provisioned CloudWatch Logs data source and API dashboard in AWS Managed Grafana."
