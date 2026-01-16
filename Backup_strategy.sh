#!/bin/bash

# PostgreSQL (VirusLox) SwissKnife -> Backup Strategy

cd "$(dirname "$0")"
CONFIG_FILE="${HOME}/PostgreSQL_SwissKnife.conf"
BIN_PSQL=$(which psql)
BIN_PG_DUMP=$(which pg_dump)
BIN_GZIP=$(which gzip)
DEFAULT_RETENTION_DAYS=30
DEFAULT_MIN_COPIES=5

if [[ ! -x "$BIN_PG_DUMP" ]]; then echo "[ERR]: pg_dump binary missing."; exit 1; fi
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
else
    echo "[ERR]: Configuration file not found. Run setup.sh."
    exit 1
fi

# Profile Selection
if [[ -n "$TARGET_PROFILE_IDX" ]]; then
    # Automated Mode
    IDX=$TARGET_PROFILE_IDX
else
    # Interactive Mode
    if [ ${#PROFILES_NAME[@]} -eq 0 ]; then
        echo "[ERR]: No profiles configured."
        exit 1
    fi

    echo "Select Instance for Backup"
    for i in "${!PROFILES_NAME[@]}"; do
        echo "  $i) ${PROFILES_NAME[$i]} [Host: ${PROFILES_HOST[$i]}]"
    done
    read -p "Select Profile Index: " IDX
fi

if [[ -z "${PROFILES_NAME[$IDX]}" ]]; then
    echo "[ERR]: Invalid profile index."
    exit 1
fi

PROFILE_NAME="${PROFILES_NAME[$IDX]}"
SAFE_NAME=$(echo "$PROFILE_NAME" | tr -cd '[:alnum:]')
DB_HOST="${PROFILES_HOST[$IDX]}"
DB_PORT="${PROFILES_PORT[$IDX]}"
DB_USER="${PROFILES_ADMIN[$IDX]}"

# Directory Setup: Use a subfolder for this specific profile
BACKUP_ROOT="${HOME}/PostgreSQL_SwissKnife/backups"
BACKUP_DIR="${BACKUP_ROOT}/${SAFE_NAME}"
mkdir -p "$BACKUP_DIR"

TIMESTAMP=$(date +%Y%m%d_%H%M)

# Auth Handling
if [[ -t 0 && -z "$TARGET_PROFILE_IDX" ]]; then
    echo -n "Password for $DB_USER (Enter for Peer/.pgpass): "
    read -s DB_PASS
    echo ""
    if [[ -n "$DB_PASS" ]]; then export PGPASSWORD="$DB_PASS"; fi
fi

echo "=== Starting Backup Strategy: $PROFILE_NAME ==="
echo "Target Dir: $BACKUP_DIR"

# --- Database Discovery ---
DB_LIST=$("$BIN_PSQL" -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d postgres -t -A -c "SELECT datname FROM pg_database WHERE datistemplate = false;" 2>/dev/null)

if [[ -z "$DB_LIST" ]]; then
    echo "[ERR]: Unable to list databases. Check connection/auth."
    exit 1
fi

for DB in $DB_LIST; do
    DUMP_FILE="${BACKUP_DIR}/${TIMESTAMP}_${DB}.sql"
    
    echo -n "[INFO]: Dumping '$DB'... "
    
    # -Fp (Plain), -C (Create DB statement), --no-acl (optional, depends on needs)
    "$BIN_PG_DUMP" -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB" -Fp -C > "$DUMP_FILE" 2> "${DUMP_FILE}.log"

    if [[ $? -eq 0 ]]; then
        echo "Success."
        rm "${DUMP_FILE}.log" # Remove log if successful
        
        # Compression
        if [[ -x "$BIN_GZIP" ]]; then
            "$BIN_GZIP" -f "$DUMP_FILE"
        fi
    else
        echo "FAILED. Check ${DUMP_FILE}.log"
    fi
done

echo "--- Checking Retention Policy ---"

# Count existing backup files (compressed or sql)
FILE_COUNT=$(find "$BACKUP_DIR" -type f -name "*.sql*" | wc -l)

if [[ "$FILE_COUNT" -gt "$DEFAULT_MIN_COPIES" ]]; then
    echo "[INFO]: File count ($FILE_COUNT) > Min ($DEFAULT_MIN_COPIES). Processing cleanup..."
    
    # Delete files older than X days
    # Note: We use -mtime. +30 means "more than 30 days ago"
    CLEANED_COUNT=$(find "$BACKUP_DIR" -type f -name "*.sql*" -mtime +$DEFAULT_RETENTION_DAYS -print -delete | wc -l)
    
    if [[ "$CLEANED_COUNT" -gt 0 ]]; then
        echo "[INFO]: Deleted $CLEANED_COUNT expired backup(s)."
    else
        echo "[INFO]: No expired backups found."
    fi
else
    echo "[SKIP]: Total backups ($FILE_COUNT) <= Min Limit ($DEFAULT_MIN_COPIES). No deletion."
fi

echo "=== Backup Procedure Complete ==="
exit 0