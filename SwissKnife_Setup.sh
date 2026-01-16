#!/bin/bash

# PostgreSQL (VirusLox) SwissKnife
# Use: Setup instances, databases, and users based on stored profiles.

CONFIG_FILE="${HOME}/PostgreSQL_SwissKnife.conf"
BACKUP_DIR="${HOME}/PostgreSQL_SwissKnife/purged_$(date +%F)"

# Check binaries
BIN_PSQL=$(which psql)
if [[ ! -x "$BIN_PSQL" ]]; then
    echo "[ERR]: 'psql' binary not found. Install postgresql:"
    echo "apt install postgresql"
	echo "#IF You prefer set up the service on Your own:"
	echo "systemctl stop postgresql"
	echo "systemctl disable postgresql"
	echo "systemctl mask postgresql"
    exit 1
fi
BIN_INITDB=$(which initdb)
BIN_PG_DUMP=$(which pg_dump)


# Configuration Management
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
fi

PROFILES_NAME=(${PROFILES_NAME[@]})
PROFILES_HOST=(${PROFILES_HOST[@]})
PROFILES_PORT=(${PROFILES_PORT[@]})
PROFILES_ADMIN=(${PROFILES_ADMIN[@]})
PROFILES_DATA_DIR=(${PROFILES_DATA_DIR[@]})

save_config() {
    echo "# PostgreSQL Profiles - Generated on $(date)" > "$CONFIG_FILE"
    echo "# Do not edit manually unless you respect bash array syntax." >> "$CONFIG_FILE"
    
    for i in "${!PROFILES_NAME[@]}"; do
        echo "PROFILES_NAME[$i]=\"${PROFILES_NAME[$i]}\"" >> "$CONFIG_FILE"
        echo "PROFILES_HOST[$i]=\"${PROFILES_HOST[$i]}\"" >> "$CONFIG_FILE"
        echo "PROFILES_PORT[$i]=\"${PROFILES_PORT[$i]}\"" >> "$CONFIG_FILE"
        echo "PROFILES_ADMIN[$i]=\"${PROFILES_ADMIN[$i]}\"" >> "$CONFIG_FILE"
        echo "PROFILES_DATA_DIR[$i]=\"${PROFILES_DATA_DIR[$i]}\"" >> "$CONFIG_FILE"
        echo "" >> "$CONFIG_FILE"
    done
    chmod 600 "$CONFIG_FILE"
    echo "[SUCCESS]: Configuration saved to $CONFIG_FILE"
}

select_profile() {
    if [ ${#PROFILES_NAME[@]} -eq 0 ]; then
        echo "[WARN]: No profiles found. Run 'Configure this toolset' first."
        return 1
    fi

    echo "Available Profiles:"
    for i in "${!PROFILES_NAME[@]}"; do
        echo "  $i) ${PROFILES_NAME[$i]} [Host: ${PROFILES_HOST[$i]}]"
    done
    
    read -p "Select Profile Index: " IDX
    if [[ -z "${PROFILES_NAME[$IDX]}" ]]; then
        echo "[ERR]: Invalid index."
        return 1
    fi
    return 0 
}

get_admin_creds() {
    # Handles logic for Peer Auth vs Password Auth
    echo "[AUTH] Enter password for admin user '${PROFILES_ADMIN[$IDX]}':"
    echo "       (Press Enter if using Peer Auth / OS User)"
    read -s DB_PASS
    
    if [[ -z "$DB_PASS" ]]; then
        unset PGPASSWORD
    else
        export PGPASSWORD="$DB_PASS"
    fi
    echo ""
}

update_conffile() {
    echo "--- Configuration Editor ---"
    echo "Existing profiles: ${#PROFILES_NAME[@]}"
    
    read -p "Enter Profile Index to edit or 'n' for new: " CHOICE
    
    if [[ "$CHOICE" == "n" ]]; then
        IDX=${#PROFILES_NAME[@]} 
    else
        IDX=$CHOICE
    fi

    echo "Editing Profile [$IDX]..."
    
    read -p "Profile Name [${PROFILES_NAME[$IDX]}]: " VAL; [ -n "$VAL" ] && PROFILES_NAME[$IDX]=$VAL
    read -p "DB Host/IP [${PROFILES_HOST[$IDX]}]: " VAL; [ -n "$VAL" ] && PROFILES_HOST[$IDX]=$VAL
    read -p "DB Port [${PROFILES_PORT[$IDX]}]: " VAL; [ -n "$VAL" ] && PROFILES_PORT[$IDX]=$VAL
    read -p "Admin Username [${PROFILES_ADMIN[$IDX]}]: " VAL; [ -n "$VAL" ] && PROFILES_ADMIN[$IDX]=$VAL
    read -p "Data Dir (Local only) [${PROFILES_DATA_DIR[$IDX]}]: " VAL; [ -n "$VAL" ] && PROFILES_DATA_DIR[$IDX]=$VAL

    save_config
}

create_instance() {
    echo "--- Create Local Instance (initdb) ---"
    if [[ ! -x "$BIN_INITDB" ]]; then
        echo "[ERR]: 'initdb' not found. Install postgresql server package."
        return
    fi

    select_profile || return
    TARGET_DIR="${PROFILES_DATA_DIR[$IDX]}"

    if [[ -z "$TARGET_DIR" ]]; then
        echo "[ERR]: No Data Directory defined for this profile."
        return
    fi

    if [[ -d "$TARGET_DIR" ]]; then
        if [ "$(ls -A $TARGET_DIR)" ]; then
            echo "[WARN]: Target directory '$TARGET_DIR' exists and is not empty."
            echo "1) Backup (tar.gz) and Recreate"
            echo "2) DELETE (rm -rf) and Recreate"
            echo "3) Cancel"
            read -p "Select: " ACT
            
            case "$ACT" in
                1)
                    mkdir -p "$BACKUP_DIR"
                    BAK_FILE="$BACKUP_DIR/raw_backup_$(date +%Y%m%d_%H%M).tar.gz"
                    echo "[INFO]: Archiving to $BAK_FILE..."
                    tar -czf "$BAK_FILE" -C "$TARGET_DIR" .
                    rm -rf "$TARGET_DIR"/*
                    ;;
                2)
                    echo "[INFO]: Purging directory..."
                    rm -rf "$TARGET_DIR"/*
                    ;;
                *) return ;;
            esac
        fi
    else
        mkdir -p "$TARGET_DIR"
    fi

    echo "[INFO]: Initializing database in $TARGET_DIR..."
    "$BIN_INITDB" -D "$TARGET_DIR" --auth-local=peer --auth-host=scram-sha-256
    
    if [[ $? -eq 0 ]]; then
        echo "[SUCCESS]: Instance initialized."
        echo "To start: pg_ctl -D $TARGET_DIR -l logfile start"
    else
        echo "[FAIL]: initdb failed."
    fi
}

create_database() {
    echo "--- Create Database ---"
    select_profile || return
    get_admin_creds

    read -p "Enter Target Database Name: " TGT_DB

    # Check existence
    EXISTS=$("$BIN_PSQL" -h "${PROFILES_HOST[$IDX]}" -p "${PROFILES_PORT[$IDX]}" -U "${PROFILES_ADMIN[$IDX]}" -tAc "SELECT 1 FROM pg_database WHERE datname='$TGT_DB'")

    if [[ "$EXISTS" == "1" ]]; then
        echo "[WARN]: Database '$TGT_DB' already exists."
        echo "1) Dump and Recreate"
        echo "2) Drop and Recreate"
        echo "3) Skip"
        read -p "Select: " ACT

        case "$ACT" in
            1)
                mkdir -p "$BACKUP_DIR"
                DUMP_FILE="$BACKUP_DIR/${TGT_DB}_pre_drop_$(date +%Y%m%d).sql"
                echo "[INFO]: Dumping to $DUMP_FILE..."
                "$BIN_PG_DUMP" -h "${PROFILES_HOST[$IDX]}" -p "${PROFILES_PORT[$IDX]}" -U "${PROFILES_ADMIN[$IDX]}" "$TGT_DB" > "$DUMP_FILE"
                ;& # Fallthrough to drop
            2)
                echo "[INFO]: Dropping database..."
                "$BIN_PSQL" -h "${PROFILES_HOST[$IDX]}" -p "${PROFILES_PORT[$IDX]}" -U "${PROFILES_ADMIN[$IDX]}" -c "DROP DATABASE \"$TGT_DB\";"
                ;;
            *) return ;;
        esac
    fi

    echo "[INFO]: Creating database '$TGT_DB'..."
    "$BIN_PSQL" -h "${PROFILES_HOST[$IDX]}" -p "${PROFILES_PORT[$IDX]}" -U "${PROFILES_ADMIN[$IDX]}" -c "CREATE DATABASE \"$TGT_DB\";"
}

create_user() {
    echo "--- Create / Update User ---"
    select_profile || return
    get_admin_creds

    read -p "Enter Username to create/update: " TGT_USER
    read -s -p "Enter Password for $TGT_USER: " TGT_PASS
    echo ""
    read -p "Enter Database to grant access to (optional): " TGT_DB_GRANT

    # Check existence
    USER_EXISTS=$("$BIN_PSQL" -h "${PROFILES_HOST[$IDX]}" -p "${PROFILES_PORT[$IDX]}" -U "${PROFILES_ADMIN[$IDX]}" -tAc "SELECT 1 FROM pg_roles WHERE rolname='$TGT_USER'")

    if [[ "$USER_EXISTS" == "1" ]]; then
        echo "[INFO]: User '$TGT_USER' exists. Updating password..."
        "$BIN_PSQL" -h "${PROFILES_HOST[$IDX]}" -p "${PROFILES_PORT[$IDX]}" -U "${PROFILES_ADMIN[$IDX]}" -c "ALTER USER \"$TGT_USER\" WITH PASSWORD '$TGT_PASS';"
    else
        echo "[INFO]: Creating new user '$TGT_USER'..."
        "$BIN_PSQL" -h "${PROFILES_HOST[$IDX]}" -p "${PROFILES_PORT[$IDX]}" -U "${PROFILES_ADMIN[$IDX]}" -c "CREATE USER \"$TGT_USER\" WITH PASSWORD '$TGT_PASS';"
    fi

    # Grants
    if [[ -n "$TGT_DB_GRANT" ]]; then
        echo "[INFO]: Granting privileges on $TGT_DB_GRANT..."
        "$BIN_PSQL" -h "${PROFILES_HOST[$IDX]}" -p "${PROFILES_PORT[$IDX]}" -U "${PROFILES_ADMIN[$IDX]}" -d "$TGT_DB_GRANT" -c "GRANT ALL PRIVILEGES ON DATABASE \"$TGT_DB_GRANT\" TO \"$TGT_USER\"; GRANT USAGE ON SCHEMA public TO \"$TGT_USER\";"
    fi
}

# MAIN
while true; do
    echo ""
    echo "=== PostgreSQL Setup Tool ==="
    echo "1) Configure profiles (Edit/Add)"
    echo "2) Create local service instance (initdb)"
    echo "3) Create database (Dump/Drop/Create)"
    echo "4) Create/Update DB user"
    echo "5) Exit"
    read -p "Select: " OPT

    case "$OPT" in
        1) update_conffile ;;
        2) create_instance ;;
        3) create_database ;;
        4) create_user ;;
        5) echo "Exiting."; exit 0 ;;
        *) echo "[ERR]: Invalid option." ;;
    esac
done