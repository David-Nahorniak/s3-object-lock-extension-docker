#!/bin/sh
set -e

# If CRON_SCHEDULE is set, run as cron daemon
if [ -n "$CRON_SCHEDULE" ]; then
    # Ensure crontabs directory exists for dcron
    mkdir -p /var/spool/cron/crontabs
    
    # Create crontab file directly for dcron
    # Format: minute hour day month weekday command
    echo "$CRON_SCHEDULE /app/file-lock.sh" > /var/spool/cron/crontabs/root
    
    # Set proper permissions
    chmod 600 /var/spool/cron/crontabs/root
    
    # Verify crontab was created
    echo "Crontab configured:"
    cat /var/spool/cron/crontabs/root
    
    echo "Starting cron daemon with schedule: $CRON_SCHEDULE"
    # Run crond in foreground
    # -f: foreground
    # -l 2: log level (0-8, higher = more verbose)
    # -L /dev/stdout: log to stdout
    exec crond -f -l 2 -L /dev/stdout
else
    # Run script once
    exec /app/file-lock.sh
fi
