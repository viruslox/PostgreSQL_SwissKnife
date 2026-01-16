# PostgreSQL SwissKnife

A Bash suite for managing PostgreSQL instances.
Designed for **User-Space** usage (no root) and **Systemd** automation.

## Features

* **Multi-Profile Management**: Manage local or remote instances via `setup.sh`.
* **Zero-Root Architecture**: Runs entirely as a standard user (supports `systemd --user`).
* **Automated Backups**: Rotation, compression, and retention policies.
* **Maintenance**: Auto-detection of missing Primary Keys and Bloat (Vacuum).
* **Security Audits**: Checks for empty passwords, superuser abuse, and dangerous settings.
* **Performance Monitor**: Real-time snapshot of Cache Hit Ratio, Connections, and Slow Queries.

## Installation

1.  Clone the repository:
    ```bash
    git clone [https://github.com/viruslox/PostgreSQL_SwissKnife.git](https://github.com/viruslox/PostgreSQL_SwissKnife.git)
    cd PostgreSQL_SwissKnife
    chmod +x *.sh
    ```

2.  Run the Setup to create a profile:
    ```bash
    ./setup.sh
    ```
    * Choose *Configure profiles* to add connection details.
    * (Optional) Use it to initialize local instances via `initdb`.

## Usage

### Interactive Tools
* **`./Performance.sh`**: View live metrics (Cache, IO, Locks).
* **`./Security_Audit.sh`**: Generate a security report in `audits/`.
* **`./Maintenance.sh`**: Run VACUUM/ANALYZE interactive checks.

### Automation (Systemd)
To schedule Backups or Maintenance automatically:

1.  Run the installer (User Scope):
    ```bash
    ./install_systemd.sh
    ```
2.  Select the profile and the schedule (e.g., "daily", "weekly").
3.  Verify timers:
    ```bash
    systemctl --user list-timers
    ```

## Requirements
* `bash` (4.0+)
* `postgresql-client` (psql, pg_dump, vacuumdb)
* `systemd` (for automation)

## Directory Structure
* `~/.config/systemd/user/`: Where services are installed.
* `~/PostgreSQL_SwissKnife.conf`: Stores credentials (chmod 600).
* `backups/`: Dump destination (organized by profile name).
