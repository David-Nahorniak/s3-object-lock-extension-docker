#!/bin/sh
set -e

# If CRON_SCHEDULE is set, run as cron daemon
if [ -n "$CRON_SCHEDULE" ]; then
    echo "$CRON_SCHEDULE /app/file-lock.sh" | crontab -
    echo "Starting cron daemon with schedule: $CRON_SCHEDULE"
    exec crond -f -l 2
else
    # Run script once
    exec /app/file-lock.sh
fi
