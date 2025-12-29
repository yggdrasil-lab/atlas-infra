#!/bin/sh
set -e

echo "Initializing git backup script..."

# Validate that necessary environment variables are set
if [ -z "$GIT_USER_EMAIL" ] || [ -z "$GIT_USER_NAME" ] || [ -z "$GIT_REPO_URL" ]; then
  echo "Error: One or more required environment variables are not set."
  echo "Please set GIT_USER_EMAIL, GIT_USER_NAME, and GIT_REPO_URL."
  exit 1
fi

# Configure Git
git config --global user.email "${GIT_USER_EMAIL}"
git config --global user.name "${GIT_USER_NAME}"

# Setup SSH keys from mounted volume
echo "Setting up SSH keys..."
mkdir -p /root/.ssh
if [ -d "/mnt/ssh_keys" ]; then
    cp -R /mnt/ssh_keys/* /root/.ssh/
fi
chmod 700 /root/.ssh
chmod 600 /root/.ssh/*

# Add github.com to known_hosts
if ! ssh-keygen -F github.com &> /dev/null; then
  echo "Adding github.com to known_hosts..."
  ssh-keyscan github.com >> /root/.ssh/known_hosts 2>/dev/null
fi
chmod 600 /root/.ssh/known_hosts


# Initialize git repository if it doesn't exist
if [ ! -d ".git" ]; then
  echo "No .git directory found. Connecting to existing repository..."
  git init
  git remote add origin "${GIT_REPO_URL}"
  git fetch
  git checkout -f main || git checkout -b main
fi

# Always ensure the remote URL is up-to-date
git remote set-url origin "${GIT_REPO_URL}"

echo "Pulling latest changes..."
git pull origin main || echo "Initial pull failed."

# Signal readiness for healthcheck
touch .git_ready

# Graceful Shutdown Handling
STOP_REQUESTED=false
shutdown_handler() {
    echo "[$(date)] SIGTERM/SIGINT received. Shutting down gracefully..."
    STOP_REQUESTED=true
    # If we are sleeping (PID of sleep command), kill it to exit immediately
    if [ -n "$SLEEP_PID" ]; then
        kill "$SLEEP_PID" 2>/dev/null
    fi
}

trap 'shutdown_handler' SIGTERM SIGINT

# Main backup loop
while [ "$STOP_REQUESTED" = false ]; do
  echo "[$(date)] --- Starting hourly backup check ---"
  
  # 1. Pull latest changes FIRST.
  echo "Pulling latest changes from remote..."
  if ! git pull --ff-only origin main; then
    echo "Standard pull failed (not fast-forward). Attempting to resolve by prioritizing local state..."
    
    # User instruction: "forcefully rebase and I want to keep the current changes"
    # Strategy: Commit local changes, then rebase our commits on top of origin, favoring 'theirs' (our local) in conflicts.
    
    git add .
    # Allow empty commits in case the diff is trivial but git was confused
    git commit --allow-empty -m "Pre-rebase save: $(date)"
    
    # Rebase using 'theirs' strategy. 
    # In a rebase, 'theirs' refers to the current branch commits being replayed (our local content).
    if ! git pull --rebase -X theirs origin main; then
       echo "Critical: Rebase failed even with strategy options. Aborting this cycle."
       # We don't exit, just loop around and try again later/sleep
    else
       echo "Rebase successful. Local state preserved."
    fi
  fi

  # 2. Add all current local files to staging
  git add .
  
  # 3. Check if there are any changes to commit (after the pull)
  if git diff --staged --quiet; then
    echo "No local changes to backup."
  else
    echo "Changes detected. Committing and pushing to remote."
    
    # Identify source
    SOURCE_TAG="${BACKUP_SOURCE_NAME:-Unknown Source}"
    
    # Commit changes with a timestamp and source identifier
    git commit -m "Hourly Vault Backup from [${SOURCE_TAG}]: $(date)"
    
    # Push changes to the remote repository
    # If push fails, we try to pull --rebase once to resolve simple races
    if ! git push -u origin main; then
        echo "Push failed. Attempting rebase and retry..."
        git pull --rebase origin main
        git push -u origin main || echo "Push failed after rebase."
    else
        echo "Successfully pushed changes to the remote repository."
    fi
  fi
  
  echo "Backup check complete. Sleeping for 1 hour..."
  
  # Sleep with background process to allow trap interruption
  sleep 3600 &
  SLEEP_PID=$!
  wait "$SLEEP_PID"
  SLEEP_PID=""
done

echo "[$(date)] Backup script stopped."
