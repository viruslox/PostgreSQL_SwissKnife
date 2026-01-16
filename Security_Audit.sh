#!/bin/bash

# PostgreSQL (VirusLox) SwissKnife -> Security Audit

cd "$(dirname "$0")"
CONFIG_FILE="${HOME}/PostgreSQL_SwissKnife.conf"
AUDIT_BASE_DIR="${HOME}/PostgreSQL_SwissKnife/audits"
BIN_PSQL=$(which psql)

if [[ ! -x "$BIN_PSQL" ]]; then echo "[ERR]: psql binary missing."; exit 1; fi
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

    echo "--- Select Instance for Audit ---"
    for i in "${!PROFILES_NAME[@]}"; do
        echo "  $i) ${PROFILES_NAME[$i]} [Host: ${PROFILES_HOST[$i]}]"
    done
    read -p "Select Profile Index: " IDX
fi

if [[ -z "${PROFILES_NAME[$IDX]}" ]]; then
    echo "[ERR]: Invalid profile index."
    exit 1
fi

DB_HOST="${PROFILES_HOST[$IDX]}"
DB_PORT="${PROFILES_PORT[$IDX]}"
DB_USER="${PROFILES_ADMIN[$IDX]}"
PROFILE_NAME="${PROFILES_NAME[$IDX]}"
mkdir -p "$AUDIT_BASE_DIR"
REPORT_FILE="${AUDIT_BASE_DIR}/Audit_${PROFILE_NAME}_$(date +%Y%m%d_%H%M).txt"

# Auth Handling (Interactive)
if [[ -t 0 && -z "$TARGET_PROFILE_IDX" ]]; then
    echo -n "Password for $DB_USER (Enter for Peer/.pgpass): "
    read -s DB_PASS
    echo ""
    if [[ -n "$DB_PASS" ]]; then export PGPASSWORD="$DB_PASS"; fi
fi

echo "[INFO]: Starting audit for $PROFILE_NAME..."
echo "[INFO]: Generating report at $REPORT_FILE"

{
    echo "========================================================"
    echo " PostgreSQL Security Audit Report"
    echo "========================================================"
    echo "Target:  $PROFILE_NAME"
    echo "Host:    $DB_HOST:$DB_PORT"
    echo "User:    $DB_USER"
    echo "Date:    $(date)"
    echo "========================================================"
    echo ""

    # 1. Superuser Check
    IS_SUPER=$("$BIN_PSQL" -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d postgres -t -A -c "SELECT usesuper FROM pg_user WHERE usename = current_user;")
    
    if [[ "$IS_SUPER" == "t" ]]; then
        echo "[PRIVILEGE]: Connected as SUPERUSER. Full audit enabled."
    else
        echo "[PRIVILEGE]: Connected as STANDARD user. Some checks (pg_shadow) will be skipped."
    fi
    echo ""

    # 2. Version & SSL
    echo "--- Server Information ---"
    "$BIN_PSQL" -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d postgres -c "SELECT version();"
    echo "SSL Active: "$("$BIN_PSQL" -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d postgres -t -A -c "SELECT ssl_is_used();")
    echo ""

    # 3. Critical Settings
    echo "--- Critical Settings (pg_settings) ---"
    "$BIN_PSQL" -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d postgres -c "
        SELECT name, setting, source 
        FROM pg_settings 
        WHERE name IN ('listen_addresses', 'port', 'max_connections', 'log_connections', 'password_encryption', 'ssl');"
    echo ""

    # 4. Superuser List
    echo "--- List of Superusers (High Risk) ---"
    "$BIN_PSQL" -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d postgres -c "
        SELECT usename, usecreatedb, usecreaterole, passwd 
        FROM pg_shadow 
        WHERE usesuper = true;" 2>/dev/null || echo "[WARN]: Cannot read pg_shadow (Permission Denied). Listing from pg_user:"
        
    if [[ "$IS_SUPER" != "t" ]]; then
        "$BIN_PSQL" -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d postgres -c "SELECT usename, usesuper FROM pg_user WHERE usesuper = true;"
    fi
    echo ""

    # 5. Empty Passwords (Superuser Only)
    if [[ "$IS_SUPER" == "t" ]]; then
        echo "--- Users with NULL Passwords ---"
        NULL_PASS=$("$BIN_PSQL" -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d postgres -t -A -c "SELECT usename FROM pg_shadow WHERE passwd IS NULL;")
        if [[ -z "$NULL_PASS" ]]; then
            echo "[PASS]: No users found with null passwords."
        else
            echo "[FAIL]: The following users have NO password:"
            echo "$NULL_PASS"
        fi
    else
        echo "--- Users with NULL Passwords ---"
        echo "[SKIP]: Requires Superuser privileges."
    fi
    echo ""

    # 6. Database List & Owner
    echo "--- Databases & Owners ---"
    "$BIN_PSQL" -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d postgres -c "
        SELECT datname, pg_catalog.pg_get_userbyid(datdba) as owner, pg_encoding_to_char(encoding) as encoding 
        FROM pg_database 
        WHERE datistemplate = false;"
    echo ""

} > "$REPORT_FILE" 2>&1

echo "[SUCCESS]: Audit Complete."
exit 0
