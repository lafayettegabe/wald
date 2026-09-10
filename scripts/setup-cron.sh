#!/bin/bash
set -e

log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [CRON-SETUP] $1"
}

log_message "Setting up automated WAL-G backup schedule..."

INCREMENTAL_SCHEDULE="${WALG_INCREMENTAL_SCHEDULE:-0 0,2,6,8,10,12,14,18,20,22 * * *}"  # Every 2 hours except full backup hours
FULL_BACKUP_SCHEDULE="${WALG_FULL_BACKUP_SCHEDULE:-0 4,16 * * *}"                        # Twice a day
CLEANUP_SCHEDULE="${WALG_CLEANUP_SCHEDULE:-0 5 * * *}"                                   # Daily at 5 AM

RETENTION_DAYS="${WALG_RETENTION_DAYS:-30}"

if [ "${WALG_AUTOMATED_BACKUPS:-true}" = "false" ]; then
    log_message "Automated backups disabled via WALG_AUTOMATED_BACKUPS=false"
    exit 0
fi

log_message "Backup schedules (configurable via environment variables):"
log_message "- Incremental backups: $INCREMENTAL_SCHEDULE (every 2 hours except full backup hours)"
log_message "- Full backups: $FULL_BACKUP_SCHEDULE (twice a day)"
log_message "- Cleanup: $CLEANUP_SCHEDULE (daily at 5 AM)"
log_message "- Retention: $RETENTION_DAYS days"

cat > /tmp/postgres-cron << EOF
# Environment for cron jobs (cron does not inherit container env)
SHELL=/bin/bash
PATH=$PATH
PGDATA=${PGDATA:-/var/lib/postgresql/data}
POSTGRES_USER=${POSTGRES_USER:-postgres}
POSTGRES_DB=${POSTGRES_DB:-postgres}
WALG_RETENTION_DAYS=${WALG_RETENTION_DAYS:-30}

# WAL-G Automated Backup Jobs

# Incremental backups (default: every 2 hours except full backup hours)
# (root-crontab opens /proc/1/fd/1 while it has permission, then drops
#  privileges to postgres via gosu - inherited fd needs no permission check)
$INCREMENTAL_SCHEDULE flock -n /var/log/wal-g/backup.lock gosu postgres /scripts/backup-cron.sh incremental >> /proc/1/fd/1 2>&1

# Full backups (default: twice a day)
$FULL_BACKUP_SCHEDULE flock -n /var/log/wal-g/backup.lock gosu postgres /scripts/backup-cron.sh full >> /proc/1/fd/1 2>&1

# Cleanup old backups (default: daily at 5 AM)
$CLEANUP_SCHEDULE flock -n /var/log/wal-g/backup.lock gosu postgres /scripts/cleanup-cron.sh >> /proc/1/fd/1 2>&1

EOF

crontab /tmp/postgres-cron
rm /tmp/postgres-cron

cron || { log_message "ERROR: cron daemon failed to start"; exit 1; }

log_message "Automated backup schedule configured successfully"
log_message "Schedules are configurable via environment variables:"
log_message "- WALG_INCREMENTAL_SCHEDULE (default: every 2 hours, incremental)"
log_message "- WALG_FULL_BACKUP_SCHEDULE (default: twice a day, full backup)"
log_message "- WALG_CLEANUP_SCHEDULE (default: daily 5 AM, cleanup)"
