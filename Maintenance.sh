#!/bin/bash

# PostgreSQL (VirusLox) SwissKnife -> Maintenance Task

cd "$(dirname "$0")"
CONFIG_FILE="${HOME}/PostgreSQL_SwissKnife.conf"
DEAD_TUPLE_RATIO=0.1
BIN_PSQL=$(which psql)
BIN_VACUUMDB=$(which vacuumdb)
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
else
    echo "[ERR]: Configuration file not found. Run setup.sh."
    exit 1
fi

# Profile Selection
# Check if triggered by Systemd (Environment Variable)
if [[ -n "$TARGET_PROFILE_IDX" ]]; then
    IDX=$TARGET_PROFILE_IDX
    echo "[INFO]: Running in AUTOMATION mode for profile index: $IDX"
else
    # Interactive Mode
    if [ ${#PROFILES_NAME[@]} -eq 0 ]; then
        echo "[ERR]: No profiles configured."
        exit 1
    fi

    echo "Select Instance for Maintenance"
    for i in "${!PROFILES_NAME[@]}"; do
        echo "  $i) ${PROFILES_NAME[$i]} [Host: ${PROFILES_HOST[$i]}]"
    done
    read -p "Select Profile Index: " IDX
fi

# Validate Index
if [[ -z "${PROFILES_NAME[$IDX]}" ]]; then
    echo "[ERR]: Invalid profile index."
    exit 1
fi

# Connection Setup
DB_HOST="${PROFILES_HOST[$IDX]}"
DB_PORT="${PROFILES_PORT[$IDX]}"
DB_USER="${PROFILES_ADMIN[$IDX]}"

# Handle Authentication : # If interactive, ask for password. If automated, rely on .pgpass or Peer auth.
if [[ -t 0 && -z "$TARGET_PROFILE_IDX" ]]; then
    echo -n "Password for $DB_USER (Enter for Peer/.pgpass): "
    read -s DB_PASS
    echo ""
    if [[ -n "$DB_PASS" ]]; then export PGPASSWORD="$DB_PASS"; fi
fi

echo "Starting Maintenance: ${PROFILES_NAME[$IDX]}"
echo "Host: $DB_HOST | User: $DB_USER | Date: $(date)"

# Get list of all non-template databases
DB_LIST=$("$BIN_PSQL" -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d postgres -t -A -c "SELECT datname FROM pg_database WHERE datistemplate = false;")

if [[ -z "$DB_LIST" ]]; then
    echo "[ERR]: Could not retrieve database list. Check connection/auth."
    exit 1
fi

for DB in $DB_LIST; do
    echo "---------------------------------------------------"
    echo "[DB]: $DB"

    # 1. Missing Primary Keys Check
    MISSING_PK=$("$BIN_PSQL" -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB" -t -A -c "
        SELECT table_name FROM information_schema.tables t
        WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
        AND NOT EXISTS (
            SELECT 1 FROM information_schema.table_constraints c
            WHERE c.table_name = t.table_name AND c.constraint_type = 'PRIMARY KEY'
        );" 2>/dev/null)

    if [[ -n "$MISSING_PK" ]]; then
        echo "[WARN]: Tables missing Primary Key:"
        echo "$MISSING_PK" | awk '{print "  - "$0}'
    else
        echo "[OK]: All public tables have PKs."
    fi

    # 2. Dead Tuples & Vacuum
    NEED_VACUUM=$("$BIN_PSQL" -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB" -t -A -c "
        SELECT relname FROM pg_stat_user_tables
        WHERE n_live_tup > 0
        AND (n_dead_tup::float / n_live_tup::float) > $DEAD_TUPLE_RATIO;" 2>/dev/null)

    if [[ -n "$NEED_VACUUM" ]]; then
        echo "[INFO]: Dead tuple threshold exceeded. Running VACUUM ANALYZE..."
        for TBL in $NEED_VACUUM; do
            echo -n "  > Vacuuming $TBL ... "
            "$BIN_VACUUMDB" -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB" -t "$TBL" -z
            echo "Done."
        done
    else
        echo "[OK]: No tables exceed dead tuple ratio ($DEAD_TUPLE_RATIO)."
    fi
done

echo ""
echo "Maintenance complete."
exit 0