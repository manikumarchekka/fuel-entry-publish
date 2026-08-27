#!/bin/bash
# ---------------------------------------------------------------------------
# Smart restart / deploy for FuelTrack API  (branch-aware, mirrors
# cctv-auth-publish/r.sh). Lives in the source repo under
# src/FuelTrack.Api/deploy/r.sh and is copied into every release by
# build.bat, so `git clean` on the server keeps it (it is in the clean
# exclude list too).
#
# On the server this file sits at $APP_DIR/r.sh next to the published DLLs.
# ---------------------------------------------------------------------------

APP_NAME="FuelTrack.Api.dll"
APP_DIR="/root/fuel-entry-publish"
LOG_FILE="$APP_DIR/nohup.out"
APP_URLS="http://0.0.0.0:5080"

echo "-------------------------------------"
echo "  Smart Restart FuelTrack API (branch-aware)"
echo "-------------------------------------"

cd "$APP_DIR" || exit 1

DOTNET="$(command -v dotnet || echo /usr/bin/dotnet)"

# --- Require ASP.NET Core 9 runtime -----------------------------------------
if ! "$DOTNET" --list-runtimes | grep -q 'Microsoft.AspNetCore.App 9\.'; then
    echo "ERROR: ASP.NET Core 9 runtime not found."
    echo "Install: sudo <dotnet-install.sh> --channel 9.0 --runtime aspnetcore --install-dir /usr/lib/dotnet"
    exit 1
fi

# --- Clear any stuck rebase/merge from a previous bad run ------------------
if [ -d .git/rebase-merge ] || [ -d .git/rebase-apply ]; then
    echo "Aborting stuck rebase from a previous run..."
    git rebase --abort 2>/dev/null
fi
git merge --abort 2>/dev/null

echo "Fetching latest changes..."
git fetch --all --prune

CURRENT_BRANCH=$(git branch --show-current)

# Newest release/* branch by last commit date; fall back to newest of any branch
LATEST_BRANCH=$(git for-each-ref --sort=-committerdate \
  --format="%(refname:short)" refs/remotes/origin | grep -E '^origin/release/' | head -n 1)
[ -z "$LATEST_BRANCH" ] && LATEST_BRANCH=$(git for-each-ref --sort=-committerdate \
  --format="%(refname:short)" refs/remotes/origin | head -n 1)
LATEST_LOCAL_BRANCH=${LATEST_BRANCH#origin/}

echo "Current branch: $CURRENT_BRANCH"
echo "Latest branch:  $LATEST_BRANCH"

RESTART_ONLY=0
if [ "$CURRENT_BRANCH" == "$LATEST_LOCAL_BRANCH" ]; then
    if pgrep -f "$APP_NAME" > /dev/null; then
        echo "Already on latest branch and app is running. Nothing to do."
        exit 0
    fi
    echo "Already on latest branch but app not running - restarting."
    RESTART_ONLY=1
fi

# --- 1. Stop --------------------------------------------------------------
echo "Stopping application..."
pkill -f "$APP_NAME" 2>/dev/null || true
sleep 3

# --- 2. Switch branch (release branches are full snapshots - reset, never
#        merge/rebase; keep server-only untracked files). ----------------
if [ "$RESTART_ONLY" -eq 0 ]; then
    echo "Switching to $LATEST_LOCAL_BRANCH..."
    git checkout -B "$LATEST_LOCAL_BRANCH" "$LATEST_BRANCH"
    git reset --hard "$LATEST_BRANCH"
    git clean -fd -e appsettings.json -e nohup.out -e r.sh -e "*.log" -e App_Data
fi

# --- 2.5 Apply idempotent DDL shipped with the release (belt-and-braces;
#         the app also auto-migrates on startup). ------------------------
if [ -f "$APP_DIR/ddl/schema.sql" ] && command -v psql > /dev/null; then
    echo "Applying DB migrations from ddl/schema.sql..."
    PGCONN=$(grep -oP '"PostgreSQL":\s*"\K[^"]+' "$APP_DIR/appsettings.json")
    if [ -z "$PGCONN" ]; then
        echo "WARNING: could not parse ConnectionStrings:PostgreSQL - skipping (app auto-migrates on startup)."
    else
        PGHOST=$(echo "$PGCONN" | grep -oP 'Host=\K[^;]+')
        PGPORT=$(echo "$PGCONN" | grep -oP 'Port=\K[^;]+')
        PGDB=$(echo "$PGCONN"   | grep -oP 'Database=\K[^;]+')
        PGUSER=$(echo "$PGCONN" | grep -oP 'Username=\K[^;]+')
        PGPASS=$(echo "$PGCONN" | grep -oP 'Password=\K[^;]+')
        PGPASSWORD="$PGPASS" psql -h "$PGHOST" -p "${PGPORT:-5432}" -U "$PGUSER" -d "$PGDB" \
            -v ON_ERROR_STOP=1 -f "$APP_DIR/ddl/schema.sql" \
            && echo "Migrations applied." \
            || echo "WARNING: migration apply failed - app will still try to auto-migrate on startup."
    fi
else
    echo "No ddl/schema.sql or psql not installed - relying on app auto-migrate on startup."
fi

# --- 3. Start ----------------------------------------------------------
echo "Starting application..."
ASPNETCORE_ENVIRONMENT=Production nohup "$DOTNET" "$APP_NAME" --urls "$APP_URLS" > "$LOG_FILE" 2>&1 &
sleep 3

if pgrep -f "$APP_NAME" > /dev/null; then
    echo "Deployment successful! (PID: $(pgrep -f "$APP_NAME"))"
else
    echo "WARNING: app may not have started - check $LOG_FILE"
fi

echo "-------------------------------------"
if [ -t 1 ]; then
    echo "Tailing logs (Ctrl+C stops the tail, not the app)..."
    tail -f "$LOG_FILE"
fi
