#!/bin/sh

# Run permission test if requested
if [ "$RUN_PERMISSIONS_TEST_ON_STARTUP" = "true" ] || [ "$RUN_PERMISSIONS_TEST_ON_STARTUP" = "only" ]; then
    echo "Running permission test..."
    echo "RCLONE_CONFIG=$RCLONE_CONFIG"
    echo "BUCKETS=$BUCKETS"
    /app/test-permissions.sh
    TEST_EXIT_CODE=$?
    
    if [ $TEST_EXIT_CODE -ne 0 ]; then
        echo "Permission test failed with exit code: $TEST_EXIT_CODE"
    fi
    
    # If "only" mode, exit after test
    if [ "$RUN_PERMISSIONS_TEST_ON_STARTUP" = "only" ]; then
        echo "Exiting after permission test (RUN_PERMISSIONS_TEST_ON_STARTUP=only)"
        exit $TEST_EXIT_CODE
    fi
fi

# If CRON_SCHEDULE is set, run as cron daemon
if [ -n "$CRON_SCHEDULE" ]; then
    # Ensure crontabs directory exists for dcron
    # dcron uses /etc/crontabs by default (not /var/spool/cron/crontabs)
    mkdir -p /etc/crontabs
    
    # Create crontab file for root user
    # Format: minute hour day month weekday command
    # IMPORTANT: Must end with empty line for dcron
    printf "%s /app/file-lock.sh >> /proc/1/fd/1 2>> /proc/1/fd/2\n\n" "$CRON_SCHEDULE" > /etc/crontabs/root
    
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
