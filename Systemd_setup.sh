#!/bin/bash

# PostgreSQL (VirusLox) SwissKnife -> Systemd Installer

# Systemd Requirements
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
# in case a desktop manager is running
if [ -f "/run/user/$(id -u)/gdm/Xauthority" ]; then
    export XAUTHORITY="/run/user/$(id -u)/gdm/Xauthority"
fi

# Sanity Check
if [[ $EUID -eq 0 ]]; then
   echo "[ERR]: Do NOT run this as root. Run as the service user." 
   exit 1
fi

# Environment
USER_HOME="${HOME}"
SUITE_DIR=$(pwd)
CONFIG_FILE="${USER_HOME}/PostgreSQL_SwissKnife.conf"
SYSTEMD_USER_DIR="${USER_HOME}/.config/systemd/user"

# Load Configuration
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "[ERR]: Configuration not found at $CONFIG_FILE."
    exit 1
fi
source "$CONFIG_FILE"

if [ ${#PROFILES_NAME[@]} -eq 0 ]; then
    echo "[ERR]: No profiles configured."
    exit 1
fi

# Checking Lingering
LINGER_STATUS=$(loginctl show-user $(whoami) --property=Linger)
if [[ "$LINGER_STATUS" == "Linger=no" ]]; then
    echo "[INFO]: Enabling lingering for user $(whoami)..."
    loginctl enable-linger $(whoami)
    if [[ $? -eq 0 ]]; then
        echo "[SUCCESS]: Lingering enabled."
    else
        echo "[WARN]: Could not enable lingering. Timers may stop on logout."
        echo "       Ask admin to run: loginctl enable-linger $(whoami)"
    fi
fi

echo "Select Profile"
for i in "${!PROFILES_NAME[@]}"; do
    echo "  $i) ${PROFILES_NAME[$i]} [Host: ${PROFILES_HOST[$i]}]"
done

read -p "Select Profile Index: " IDX

if [[ -z "${PROFILES_NAME[$IDX]}" ]]; then
    echo "[ERR]: Invalid profile."
    exit 1
fi

PROFILE_NAME="${PROFILES_NAME[$IDX]}"
SAFE_NAME=$(echo "$PROFILE_NAME" | tr -cd '[:alnum:]')

create_unit() {
    local TYPE=$1      # "backup" or "maint"
    local SCRIPT=$2
    local SCHEDULE=$3
    local DESC=$4

    SERVICE_NAME="pg_${TYPE}_${SAFE_NAME}"
    mkdir -p "$SYSTEMD_USER_DIR"

    echo "[INFO]: Configuring $SERVICE_NAME..."

    # Service Unit
    cat > "${SYSTEMD_USER_DIR}/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=$DESC (${PROFILE_NAME})

[Service]
Type=oneshot
WorkingDirectory=${SUITE_DIR}
ExecStart=${SUITE_DIR}/${SCRIPT}
Environment="CONFIG_FILE=${CONFIG_FILE}"
Environment="TARGET_PROFILE_IDX=${IDX}"

StandardOutput=journal
StandardError=journal
EOF

    # Timer Unit
    cat > "${SYSTEMD_USER_DIR}/${SERVICE_NAME}.timer" <<EOF
[Unit]
Description=Timer for $SERVICE_NAME

[Timer]
OnCalendar=$SCHEDULE
Persistent=true

[Install]
WantedBy=timers.target
EOF

    # Reload and Enable
    systemctl --user daemon-reload
    systemctl --user enable --now "${SERVICE_NAME}.timer"
    echo "[SUCCESS]: ${SERVICE_NAME} active. Schedule: $SCHEDULE"
}

# Backup Configuration
echo ""
read -p "Enable automated BACKUPS for '$PROFILE_NAME'? [y/N]: " DO_BACKUP
if [[ "$DO_BACKUP" =~ ^[Yy]$ ]]; then
    read -p "  Enter Schedule [daily]: " SCHED
    SCHED=${SCHED:-"daily"}
    create_unit "backup" "Backup_strategy.sh" "$SCHED" "PostgreSQL Backup Strategy"
fi

# Maintenance Configuration
echo ""
read -p "Enable automated MAINTENANCE for '$PROFILE_NAME'? [y/N]: " DO_MAINT
if [[ "$DO_MAINT" =~ ^[Yy]$ ]]; then
    read -p "  Enter Schedule [weekly]: " SCHED
    SCHED=${SCHED:-"weekly"}
    create_unit "maint" "Maintenance.sh" "$SCHED" "PostgreSQL Maintenance Tasks"
fi

echo ""
echo "[DONE]: User-level Systemd setup complete."
echo "        Check status: systemctl --user list-timers"
echo "        Check logs:   journalctl --user -u pg_backup_${SAFE_NAME}"
exit 0