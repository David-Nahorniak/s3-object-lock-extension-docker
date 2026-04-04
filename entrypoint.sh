#!/bin/sh

# If CRON_SCHEDULE is set, run as cron daemon
if [ -n "$CRON_SCHEDULE" ]; then
    # Ensure crontabs directory exists for dcron
    # dcron uses /etc/crontabs by default (not /var/spool/cron/crontabs)
    mkdir -p /etc/crontabs
    
    # Create crontab file for root user
    # Format: minute hour day month weekday command
    # IMPORTANT: Must end with empty line for dcron
    printf "%s /app/file-lock.sh\n\n" "$CRON_SCHEDULE" > /etc/crontabs/root
    
    # Set proper ownership and permissions (dcron requires 600 and root ownership)
    chown root:root /etc/crontabs/root
    chmod 600 /etc/crontabs/root
    
    # Verify crontab was created
    echo "Crontab configured:"
    cat /etc/crontabs/root
    echo "--- end of crontab ---"
    echo "Crontab file permissions:"
    ls -la /etc/crontabs/
    
    echo "Starting cron daemon with schedule: $CRON_SCHEDULE"
    
    # Run crond in foreground
    # -f: foreground mode (keeps container running)
    # -l 2: log level (notice and higher)
    # -L /dev/stdout: log to stdout for docker logs
    exec crond -f -l 2 -L /dev/stdout
else
    # Run script once
    exec /app/file-lock.sh
fi
