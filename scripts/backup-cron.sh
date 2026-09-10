#!/bin/bash
set -e


BACKUP_TYPE="${1:-incremental}"

log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [BACKUP-CRON] $1"
}

send_notification() {
    local subject="$1"
    local message="$2"
    
    if [ -n "${WALG_NOTIFICATION_EMAIL:-}" ] && command -v mail >/dev/null 2>&1; then
        echo "$message" | mail -s "$subject" "$WALG_NOTIFICATION_EMAIL" 2>/dev/null || true
    fi
}

check_postgres() {
    for i in {1..30}; do
        if pg_isready -U "${POSTGRES_USER:-postgres}" >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done
    return 1
}

log_message "Starting automated $BACKUP_TYPE backup..."

if ! check_postgres; then
    log_message "ERROR: PostgreSQL is not ready"
    send_notification "PostgreSQL Backup Failed" "PostgreSQL is not ready for backup"
    exit 1
fi

DB_SIZE=$(psql -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-postgres}" -t -c "SELECT pg_size_pretty(pg_database_size('${POSTGRES_DB:-postgres}'));" 2>/dev/null | xargs || echo "Unknown")

DATA_DIR=$(psql -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-postgres}" -tAc "SHOW data_directory;" 2>/dev/null | xargs)
DATA_DIR="${DATA_DIR:-${PGDATA:-/var/lib/postgresql/data}}"

BACKUP_START_TIME=$(date '+%Y-%m-%d %H:%M:%S')
BACKUP_START_EPOCH=$(date +%s)

log_message "Database: ${POSTGRES_DB:-postgres}"
log_message "Database size: $DB_SIZE"
log_message "Backup type: $BACKUP_TYPE"

if [ "$BACKUP_TYPE" = "full" ]; then
    log_message "Creating FULL backup..."
    BACKUP_COMMAND="WALG_DELTA_MAX_STEPS=0 envdir /etc/wal-g/env /usr/local/bin/wal-g backup-push ${DATA_DIR}"
else
    log_message "Creating INCREMENTAL backup..."
    BACKUP_COMMAND="envdir /etc/wal-g/env /usr/local/bin/wal-g backup-push ${DATA_DIR}"
fi

if eval "$BACKUP_COMMAND"; then
    BACKUP_END_TIME=$(date '+%Y-%m-%d %H:%M:%S')
    BACKUP_END_EPOCH=$(date +%s)
    BACKUP_DURATION=$((BACKUP_END_EPOCH - BACKUP_START_EPOCH))
    
    log_message "$BACKUP_TYPE backup completed successfully in ${BACKUP_DURATION} seconds"
    
    LATEST_BACKUP=$(envdir /etc/wal-g/env /usr/local/bin/wal-g backup-list --detail --json 2>/dev/null | tail -1 | grep -o '"backup_name":"[^"]*"' | cut -d'"' -f4 || echo "Unknown")
    
    if [[ "$LATEST_BACKUP" == *"_D_"* ]]; then
        ACTUAL_TYPE="incremental/delta"
    else
        ACTUAL_TYPE="full"
    fi
    
    send_notification "PostgreSQL $BACKUP_TYPE Backup Success" \
        "Automated $BACKUP_TYPE backup completed successfully

Details:
- Database: ${POSTGRES_DB:-postgres}
- Size: $DB_SIZE
- Duration: ${BACKUP_DURATION} seconds
- Backup: $LATEST_BACKUP
- Type: $ACTUAL_TYPE
- Started: $BACKUP_START_TIME
- Completed: $BACKUP_END_TIME"
    
    log_message "Backup name: $LATEST_BACKUP"
    log_message "Actual backup type: $ACTUAL_TYPE"
    
    TOTAL_BACKUPS=$(envdir /etc/wal-g/env /usr/local/bin/wal-g backup-list 2>/dev/null | wc -l || echo "0")
    RETENTION_DAYS="${WALG_RETENTION_DAYS:-30}"
    log_message "Total backups in storage: $TOTAL_BACKUPS (retained for $RETENTION_DAYS days)"
    
else
    BACKUP_END_TIME=$(date '+%Y-%m-%d %H:%M:%S')
    log_message "ERROR: $BACKUP_TYPE backup failed"
    
    send_notification "PostgreSQL $BACKUP_TYPE Backup Failed" \
        "Automated $BACKUP_TYPE backup failed for database ${POSTGRES_DB:-postgres}

Details:
- Started: $BACKUP_START_TIME
- Failed: $BACKUP_END_TIME
- Check container logs (docker logs)"
    
    exit 1
fi
