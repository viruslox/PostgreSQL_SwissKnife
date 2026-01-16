#!/bin/bash

# PostgreSQL (VirusLox) SwissKnife -> Performance Monitor

CONFIG_FILE="${HOME}/PostgreSQL_SwissKnife.conf"
BIN_PSQL=$(which psql)

if [[ ! -x "$BIN_PSQL" ]]; then
    echo "[ERR]: 'psql' binary not found."
    exit 1
fi

if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
else
    echo "[ERR]: Configuration not found. Run setup.sh first."
    exit 1
fi

# Profile Selection
if [ ${#PROFILES_NAME[@]} -eq 0 ]; then
    echo "[ERR]: No profiles configured."
    exit 1
fi

echo "Select Target Instance"
for i in "${!PROFILES_NAME[@]}"; do
    echo "  $i) ${PROFILES_NAME[$i]} [Host: ${PROFILES_HOST[$i]}]"
done

read -p "Select Profile Index: " IDX

if [[ -z "${PROFILES_NAME[$IDX]}" ]]; then
    echo "[ERR]: Invalid profile."
    exit 1
fi

# Load Connection Details
DB_HOST="${PROFILES_HOST[$IDX]}"
DB_PORT="${PROFILES_PORT[$IDX]}"
DB_USER="${PROFILES_ADMIN[$IDX]}"

echo -n "Target Database Name [default: postgres]: "
read DB_NAME
DB_NAME=${DB_NAME:-"postgres"}

echo -n "Password for $DB_USER (Enter for Peer/Trust): "
read -s DB_PASS
echo ""

if [[ -n "$DB_PASS" ]]; then
    export PGPASSWORD="$DB_PASS"
else
    unset PGPASSWORD
fi

# --- Execution Helper ---
run_query() {
    "$BIN_PSQL" -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -t -A -c "$1"
    if [[ $? -ne 0 ]]; then
        echo "[FAIL]: Query failed. Check connection or permissions."
        exit 1
    fi
}

echo "Performance audit: ${PROFILES_NAME[$IDX]} ($DB_NAME)"
echo "Time: $(date +%Y-%m-%dT%H:%M:%S)"

# 1. Cache Hit Ratio
echo ""
echo "[METRIC]: Cache Hit Ratio (Target: >99%)"
run_query "
SELECT 
  'Hit Ratio: ' || 
  ROUND(sum(heap_blks_hit) / (sum(heap_blks_hit) + sum(heap_blks_read) + 0.0001) * 100, 2) || '%'
FROM pg_statio_user_tables;"

# 2. Active Connections
echo ""
echo "[METRIC]: Active Connections"
run_query "
SELECT 'Active: ' || count(*) || ' / Max: ' || current_setting('max_connections')
FROM pg_stat_activity 
WHERE state = 'active';"

# 3. Slow Queries (>1 second)
echo ""
echo "[METRIC]: Slow Queries (> 1s)"
SLOW_Q=$(run_query "
SELECT pid || ' | ' || usename || ' | ' || (now() - query_start)::text || ' | ' || left(query, 50)
FROM pg_stat_activity 
WHERE state = 'active' AND (now() - query_start) > interval '1 second';")

if [[ -z "$SLOW_Q" ]]; then
    echo "[OK]: No slow queries detected."
else
    echo "PID | User | Duration | Query Snippet"
    echo "$SLOW_Q"
fi

# 4. DB Size
echo ""
echo "[METRIC]: Database Size"
run_query "SELECT pg_size_pretty(pg_database_size('$DB_NAME'));"

echo ""
echo "Perfoemance audit complete"
exit 0