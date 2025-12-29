#!/bin/sh

# Graceful Shutdown Handling
STOP_REQUESTED=false
shutdown_handler() {
    echo "[$(date)] SIGTERM/SIGINT received. Shutting down gracefully..."
    STOP_REQUESTED=true
    
    # Clear cache on stop to ensure the next start is a clean resync
    echo "Clearing bisync cache before exit..."
    rm -rf /root/.cache/rclone/bisync
    
    # If sleeping, kill sleep to exit
    if [ -n "$SLEEP_PID" ]; then
        kill "$SLEEP_PID" 2>/dev/null
    fi
}

trap 'shutdown_handler' SIGTERM SIGINT

echo "Initializing rclone entrypoint..."

# Ensure we start fresh on every container boot
echo "Forcing fresh start: Clearing bisync cache..."
rm -rf /root/.cache/rclone/bisync

while [ "$STOP_REQUESTED" = false ]; do
    echo "----------------------------------------------------------------"
    
    # Check if we've ever synced before by looking for rclone's internal cache.
    # Since we clear it at boot and on stop, this will be TRUE for the first iteration.
    if [ ! -d "/root/.cache/rclone/bisync" ]; then
        echo "First run of session: Initializing with --resync..."
        rclone bisync "gdrive:${GDRIVE_VAULT_PATH}" /data --verbose --checksum --resync --create-empty-src-dirs
    else
        echo "Subsequent run: Syncing changes..."
        rclone bisync "gdrive:${GDRIVE_VAULT_PATH}" /data --verbose --checksum --create-empty-src-dirs
    fi

    echo "Sync complete. Sleeping for 30 seconds..."
    
    # Sleep with interrupt capability
    sleep 30 &
    SLEEP_PID=$!
    wait "$SLEEP_PID"
    SLEEP_PID=""
done

echo "[$(date)] Rclone service stopped."