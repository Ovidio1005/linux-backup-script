#!/bin/bash

# ------------------------------ #
# Parse command line arguments   #
# ------------------------------ #
function message () {
    if [[ $NOLOG != true ]]; then
        echo "$@" >> "$LOGSDIR/log"
    fi

    if [[ $VERBOSE == true ]] || [[ $NOLOG == true ]] then
        echo "$@"
    fi
}

function error() {
    unset BORG_PASSPHRASE

    if [[ $NOLOG != true ]]; then
        if [[ -n "$@" ]]; then
            echo "$@" >> "$LOGSDIR/log"
        fi
        echo "--- BACKUP PROCESS FINISHED ---" >> "$LOGSDIR/log"
    fi

    if [[ $VERBOSE == true ]] || [[ $NOLOG == true ]]; then
        if [[ -n "$@" ]]; then
            echo "$@" >&2
        fi
        echo "--- BACKUP PROCESS FINISHED ---"
    fi

    if [[ $IGNORE_LOCK != true ]]; then
        rm "$CONF_DIR/.lock"
    fi

    exit 1
}

# Defaults
INTERACTIVE=false
VERBOSE=false
DRYRUN=false
SKIP_BORG=false
SKIP_RCLONE=false
SKIP_PACKAGES=false
IGNORE_ERRS=false
IGNORE_TIMESTAMP=false
IGNORE_LOCK=false
CONF_DIR="/backup"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --interactive|-i)
            INTERACTIVE=true
            ;;
        --verbose|-v)
            VERBOSE=true
            ;;
        --dry-run|-d)
            DRYRUN=true
            SKIP_RCLONE=true
            SKIP_PACKAGES=true
            ;;
        --skip-borg)
            SKIP_BORG=true
            ;;
        --skip-rclone)
            SKIP_RCLONE=true
            ;;
        --skip-packages)
            SKIP_PACKAGES=true
            ;;
        --ignore-errors)
            IGNORE_ERRS=true
            ;;
        --ignore-timestamp)
            IGNORE_TIMESTAMP=true
            ;;
        --ignore-lock)
            IGNORE_LOCK=true
            ;;
        --conf-dir)
            # Next argument must be the directory path
            if [[ -n "$2" ]]; then
                CONF_DIR="$2"
                shift
            else
                echo "Error: --conf-dir requires a path argument" >&2
                exit 1
            fi
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
    shift
done

# Borg options
if [[ $VERBOSE == true ]] &&  [[ $DRYRUN == true ]]; then
    BORG_CREATE_OPTS="--dry-run --progress"
    BORG_PRUNE_OPTS="--dry-run --progress --list"
elif [[ $VERBOSE == true ]]; then
    BORG_CREATE_OPTS="--progress --stats"
    BORG_PRUNE_OPTS="--progress --list --stats"
    BORG_COMPACT_OPTS="--progress"
elif [[ $DRYRUN == true ]]; then
    BORG_CREATE_OPTS="--dry-run"
    BORG_PRUNE_OPTS="--dry-run"
fi

# Rclone Options
if [[ $VERBOSE == true ]]; then
    RCLONE_OPTS="--progress"
fi

TIMESTAMP_FILE="$CONF_DIR/last_backup"
NOW=$(date +%s)
MAX_AGE=$((12*3600))  # 12 hours in seconds

if ! [[ $IGNORE_TIMESTAMP == true ]]; then
    if [[ -r "$TIMESTAMP_FILE" ]]; then
        TIMESTAMP=$(cat "$TIMESTAMP_FILE")
        AGE=$((NOW - TIMESTAMP))
        if (( AGE < MAX_AGE )); then
            echo "Last backup is still fresh (age=$AGE, max=$MAX_AGE)"
            exit 0
        fi
    fi
fi

# Check and create lock file
if [[ $IGNORE_LOCK != true ]]; then
    if [[ -f "$CONF_DIR/.lock" ]]; then
        echo "Another backup is already in progress"
        exit 0
    else
        trap 'rm -f "$CONF_DIR/.lock"; unset BORG_PASSPHRASE; exit 1;' SIGHUP SIGINT SIGQUIT SIGABRT SIGTERM EXIT
        touch "$CONF_DIR/.lock"
    fi
fi

#------------------------------#
# Create log dirs              #
#------------------------------#
LOGSDIR="$CONF_DIR/logs/$(date +"%F")"
mkdir -p "$LOGSDIR"
if (( $? != 0 )); then
    echo "Unable to create logs directory '$LOGSDIR', proceeding without logs" >&2
    NOLOG=true
else
    touch "$LOGSDIR/log"
    touch "$LOGSDIR/borg_stderr"
    touch "$LOGSDIR/rclone_stderr"

    chmod 700 "$LOGSDIR"
    find "$LOGSDIR" -type f -exec chmod 600 {} \;
fi

message "--- STARTING BACKUP PROCESS ---"

#------------------------------#
# Get config                   #
#------------------------------#
if [[ -r "$CONF_DIR/conf/repo_path" ]]; then
    read -r REPO < "$CONF_DIR/conf/repo_path"
fi

if [[ -r "$CONF_DIR/conf/remote_path" ]]; then
    read -r REMOTE < "$CONF_DIR/conf/remote_path"
elif [[ $SKIP_RCLONE != true ]] && [[ $DRYRUN != true ]]; then
    error "File '$CONF_DIR/conf/remote_path' not found or not readable, aborting"
fi

if [[ -r "$CONF_DIR/conf/packages_path" ]]; then
    read -r PACKAGES_BASE_DIR < "$CONF_DIR/conf/packages_path"
elif [[ $SKIP_PACKAGES != true ]] && [[ $DRYRUN != true ]]; then
    error "File '$CONF_DIR/conf/packages_path' not found or not readable, aborting"
fi

if [[ -r "$CONF_DIR/conf/paths" ]]; then
    readarray -t PATHS < "$CONF_DIR/conf/paths"
fi

if [[ -r "$CONF_DIR/conf/archive_prefix" ]]; then
    read -r ARCHIVE_NAME < "$CONF_DIR/conf/archive_prefix"
else
    ARCHIVE_NAME="backup"
fi

if [[ -r "$CONF_DIR/conf/passw" ]]; then
    read -r BORG_PASSPHRASE < "$CONF_DIR/conf/passw"
    export BORG_PASSPHRASE
fi

message "Repo: $REPO"
message "Remote: $REMOTE"
message "Packages: $PACKAGES_BASE_DIR"
message "Paths: ${PATHS[@]}"
if [[ -r "$CONF_DIR/conf/exclude" ]]; then
    message "Exclude:"
    message "$( cat "$CONF_DIR/conf/exclude" )"
fi

#------------------------------#
# Export packages              #
#------------------------------#
if [[ $SKIP_PACKAGES != true ]]; then
    # Output directory with timestamp
    PACKAGES_DIR="$PACKAGES_BASE_DIR/AppConfig-$(date +%Y%m%dT%H%M%S)"

    if [[ $INTERACTIVE == true ]]; then
        do_packages=""
        while [[ "$do_packages" != y ]] && [[ "$do_packages" != n ]]; do
            read -p "Exporting package/service configuration to '$PACKAGES_DIR'. Proceed? [y/n]: " do_packages
        done
    else
        do_packages=y
    fi

    if [[ $do_packages == y ]]; then
        rm -r "$PACKAGES_BASE_DIR/AppConfig"-* 2>/dev/null
        mkdir -p "$PACKAGES_DIR"

        if (( $? != 0 )); then
            message "Failed to create directory '$PACKAGES_DIR'"
            if [[ $IGNORE_ERRS != true ]]; then
                error
            fi
        else
            message "Exporting system information to: $PACKAGES_DIR"

            # 1. All installed APT packages with installation type
            # dpkg-query + apt-mark to distinguish manual vs. auto-installed
            apt-mark showmanual | sort > "$PACKAGES_DIR/apt_manual.txt"
            apt-mark showauto   | sort > "$PACKAGES_DIR/apt_auto.txt"
            dpkg-query -W -f='${Package}\t${Status}\n' > "$PACKAGES_DIR/dpkg_all.txt"

            # 2. Installed snaps
            snap list > "$PACKAGES_DIR/snaps.txt" 2>/dev/null || echo "No snap support detected" > "$PACKAGES_DIR/snaps.txt"

            # 3. Installed flatpaks
            flatpak list --columns=application,ref,origin,installation > "$PACKAGES_DIR/flatpaks.txt" 2>/dev/null || echo "No flatpak support detected" > "$PACKAGES_DIR/flatpaks.txt"

            # 5. Docker containers
            docker ps -a > "$PACKAGES_DIR/docker_containers.txt" 2>/dev/null || echo "Docker not installed or not running" > "$PACKAGES_DIR/docker_containers.txt"

            # 6. Services and their enabled/disabled state
            systemctl list-unit-files --type=service > "$PACKAGES_DIR/services.txt"

            message "Package list exported"
        fi
    fi
fi

if [[ $SKIP_BORG != true ]]; then
    #------------------------------#
    # Create archive               #
    #------------------------------#
    if [[ $INTERACTIVE == true ]]; then
        do_bcreate=""
        while [[ "$do_bcreate" != y ]] && [[ "$do_bcreate" != n ]]; do
            read -p "Running 'borg create' with repository::archive '$REPO::$ARCHIVE_NAME-{now:%Y%m%dT%H%M%S}'. Proceed? [y/n]: " do_bcreate
        done
    else
        do_bcreate=y
    fi

    if [[ $do_bcreate == y ]]; then
        borg create $BORG_CREATE_OPTS --exclude-caches --exclude-from "$CONF_DIR/conf/exclude" "$REPO"::"$ARCHIVE_NAME"-{now:%Y%m%dT%H%M%S} "${PATHS[@]}" 2> >(tee -a "$LOGSDIR/borg_stderr" >&2)

        RES=$?
        if (( $RES == 0 )); then
            message "'borg create' completed successfully"
        elif (( $RES == 1 )); then
            message "'borg create' completed with warnings"
        else
            message "'borg create' failed"
            if [[ $IGNORE_ERRS != true ]]; then
                error
            fi
        fi
    fi

    #------------------------------#
    # Prune repo                   #
    #------------------------------#
    if [[ $INTERACTIVE == true ]]; then
        do_bprune=""
        while [[ "$do_bprune" != y ]] && [[ "$do_bprune" != n ]]; do
            read -p "Running 'borg prune' with repository '$REPO'. Proceed? [y/n]: " do_bprune
        done
    else
        do_bprune=y
    fi

    if [[ $do_bprune == y ]]; then
        borg prune $BORG_PRUNE_OPTS --keep-daily 7 --keep-weekly 4 --keep-monthly 12 --keep-yearly 8 "$REPO" 2> >(tee -a "$LOGSDIR/borg_stderr" >&2)

        RES=$?
        if (( $RES == 0 )); then
            message "'borg prune' completed successfully"
        elif (( $RES == 1 )); then
            message "'borg prune' completed with warnings"
        else
            message "'borg prune' failed"
            if [[ $IGNORE_ERRS != true ]]; then
                error
            fi
        fi
    fi

    #------------------------------#
    # Compact repo                 #
    #------------------------------#
    if [[ $DRYRUN != true ]]; then
        if $INTERACTIVE; then
            do_bcompact=""
            while [[ "$do_bcompact" != y ]] && [[ "$do_bcompact" != n ]]; do
                read -p "Running 'borg compact' with repository '$REPO'. Proceed? [y/n]: " do_bcompact
            done
        else
            do_bcompact=y
        fi

        if [[ $do_bcompact == y ]]; then
            borg compact $BORG_COMPACT_OPTS "$REPO" 2> >(tee -a "$LOGSDIR/borg_stderr" >&2)

            RES=$?
            if (( $RES == 0 )); then
                message "'borg compact' completed successfully"
            elif (( $RES == 1 )); then
                message "'borg compact' completed with warnings"
            else
                message "'borg compact' failed"
                if [[ $IGNORE_ERRS != true ]]; then
                    error
                fi
            fi
        fi
    fi
fi

#------------------------------#
# Unset passphrase             #
#------------------------------#
unset BORG_PASSPHRASE

#------------------------------#
# Sync with remote             #
#------------------------------#
if [[ $SKIP_RCLONE != true ]]; then
    if [[ $INTERACTIVE == true ]]; then
        do_rclone=""
        while [[ "$do_rclone" != y ]] && [[ "$do_rclone" != n ]]; do
            read -p "Running 'rclone sync $RCLONE_OPTS $REPO $REMOTE'. Proceed? [y/n]: " do_rclone
        done
    else
        do_rclone=y
    fi

    if [[ $do_rclone == y ]]; then
        rclone sync $RCLONE_OPTS $REPO $REMOTE 2> >(tee -a "$LOGSDIR/rclone_stderr" >&2)

        if (( $? == 0 )); then
            message "'rclone sync' completed successfully"
        else
            message "'rclone sync' failed"
            if [[ $IGNORE_ERRS != true ]]; then
                error
            fi
        fi
    fi
fi

if [[ $DRYRUN != true ]]; then
    if [[ $INTERACTIVE == true ]]; then
        save_timestamp=""
        while [[ "$save_timestamp" != y ]] && [[ "$save_timestamp" != n ]]; do
            read -p "Update the \"last backup\" timestamp? Non-interactive backups will wait at least 23 hours [y/n]: " save_timestamp
        done
    else
        save_timestamp=y
    fi

    if [[ $save_timestamp == y ]]; then
        date +%s > "$TIMESTAMP_FILE"
    fi
fi

if [[ $IGNORE_LOCK != true ]]; then
    rm "$CONF_DIR/.lock"
fi

message "--- BACKUP PROCESS FINISHED ---"
