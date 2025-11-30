# Linux Backup Script

This is a bash script I created to automate backups of my PC and home server with [BorgBackup](https://www.borgbackup.org/). I figured it might be useful to other people, so I'm putting it here on GitHub.

## Table of contents

- [How it works](#How it works)
- [Usage](#Usage)
- [Configuration](#Configuration)
	- [Further customisation](#Further customisation)
- [Command line options](#Command line options)
	- [`-i` or `--interactive`](#`-i` or `--interactive`)
	- [`-v` or `--verbose`](#`-v` or `--verbose`)
	- [`--dry-run`](#`--dry-run`)
	- [`--skip-borg`](#`--skip-borg`)
	- [`--skip-rclone`](#`--skip-rclone`)
	- [`--skip-packages`](#`--skip-packages`)
	- [`--ignore-errors`](#`--ignore-errors`)
	- [`--ignore-timestamp`](#`--ignore-timestamp`)
	- [`--ignore-lock`](#`--ignore-lock`)
	- [`--conf-dir [PATH]`](#`--conf-dir [PATH]`|`--conf-dir [PATH]`)
- [Requirements](#Requirements)
- [See also](#See also)

## How it works

The script is meant to be ran on a schedule through `cron`, a `systemd` timer, or similar, and relies on a single directory for configuration, logs, and state (by default `/backup`, it can be changed with the `--conf-dir` option). When ran, it:

- Checks the timestamp of the last successful run. The script will not run more than once every 12 hours, unless the `--ignore-timestamp` option is provided.
    + This is to allow the script to be used on machines that are not always on at known times, like personal computers. Simply set it to run at short intervals with `cron`, and it will automatically avoid excessive executions.
- Reads configuration files from `/backup/conf` (see [Configuration](#Configuration) for details).
- Exports a list of all installed packages, snaps, flatpaks, running docker containers, and systemd services.
- Creates a new archive in the BorgBackup repository
- Prunes the repository and compacts it, keeping the most recent:  
    + 7 daily backups
    + 4 weekly backups
    + 12 monthly backups
    + 8 yearly backups
- Syncs the repository with cloud storage with `rclone`

> [!note]
> The script exports installed packages with `apt-mark` and `dpkg-query`. If you use a different package manager, your list of packages won't be exported unless you edit the script yourself (see [Further customisation](#Further customisation)).

Logs are created in `/backup/logs`. The script prevents simultaneous runs by creating a lock file at `/backup/.lock` and deleting it when finished.

## Usage

First, download `backup.sh` from this repository, place it at a location of your choosing, and make it executable.

Create a BorgBackup repository if you haven't set one up already (see the [BorgBackup docs](https://borgbackup.readthedocs.io/en/stable/) if you don't know how to do that). If you want to sync the backups to cloud storage as well, configure `rclone` with your cloud solution of choice (see the [rclone docs](https://rclone.org/docs/) if you don't know how to do that); if you use a remote borg server like [BorgBase](https://www.borgbase.com/), you likely want to skip this step and run the script with `--skip-rclone` instead.

Then, download one of the configurations from the `examples` folder and place it at `/backup` (or somewhere else and run the script with `--conf-dir [PATH]`), and edit it to match your needs (see the [Configuration](#Configuration) section below).

> [!warning]
> Be careful about permissions for `conf/passw`, as that's where you'll store the password for the BorgBackup repository.

Finally, set up automation in whichever way you prefer. The `examples` folder contains example crontabs that you can use to set it up through `cron`; just run `crontab -e` and copy-paste the line from the example into your crontab. Note that the provided examples assume the script is stored at `/backup/backup.sh`. You should probably run the script manually and with `--verbose` once before setting up automation, to check that everything works correctly.

> [!info]
> If you want to back up the whole system, you will probably need to run the script as root.

## Configuration

> [!info]
> The following section assumes using the default configuration directory, `/backup`. You can provide a different one with `--conf-dir`.

The script relies on seven configuration files, all stored in `/backup/conf`, with the following names:

- `repo_path`
    + Contains the path to the borg repository. Its contents will be read and passed to `borg` commands as a command-line argument.
- `remote_path`
    + Path to the remote location to sync to with `rclone`, in the format `remote:path/to/directory`. This file is optional if the `--skip-rclone` option is used.
- `paths`
    + List of paths that should be backed up, one per line. This file is read and each of its lines is passed directly to `borg` commands as a command-line argument, so it cannot contain comments.
- `passw`
    + Password for the BorgBackup repository. If present, its contents will be exported to the `BORG_PASSPHRASE` variable for `borg` commands. You can omit it if you already export `BORG_PASSPHRASE` in some other way. Note that leaving it as an empty file rather than removing it will result in `BORG_PASSPHRASE` being set to the empty string.
- `packages_path`
    + Path where the list of packages, snaps etc. should be exported; make sure it is at a path that is backed up by your `paths` configuration, so it gets saved to the repository. This file is optional if the `--skip-packages` option is used.
- `exclude`
    + Patterns to exclude from backups, one per line. This file will be passed to `borg` commands through the `--exclude-from` option, and as such may contain comments in the form of lines starting with '#'. See [borg help patterns](https://borgbackup.readthedocs.io/en/stable/usage/help.html) for more information.
- `archive-prefix`
    + Prefix for the name of the archives created in the repository. The names will follow the pattern `prefix-yyyyMMddTHHmmss`, for example: `MyBackup-20251130T204602`. If this file is absent, the default prefix of "backup" is used; if this file is present and empty, the prefix will be the empty string.

### Further customisation
If you are comfortable with bash scripting, you can edit the script to change its functionality. The parts you're most likely to be interested in are:

- Timestamp logic at lines 119-132
- Package export logic at lines 210-256
- `borg create` command at line 272
- `borg prune` command at line 300
- `rclone sync` command at line 365

## Command line options

### `-i` or `--interactive`

Causes the script to prompt the user for confirmation before each step.

### `-v` or `--verbose`

Causes log messages to be printed to the terminal as well as the log files, and increases the verbosity of `borg` and `rclone` commands.

### `--dry-run`

Skips package export and `rclone`, and performs a dry run of only the `borg` borg commands; no local or remote files will be changed. You probably want to pair this with `--verbose`.

### `--skip-borg`

Skips all the BorgBackup-related parts of the script.

### `--skip-rclone`

Skips the `rclone` remote synchronization.

### `--skip-packages`

Skips exporting the list of installed packages, snaps etc.

### `--ignore-errors`

Normally the script aborts execution if an error occurs at any point. This option causes it to continue regardless.

### `--ignore-timestamp`

Causes the script to ignore the saved timestamp of the last successful execution. Without this option, the script will refuse to run if it completed successfully within the last 12 hours.

### `--ignore-lock`

Causes the script to ignore the presence of a `/backup/.lock` file, which normally prevents simultaneous executions. Not recommended.

Note that running with `--ignore-lock` will not remove the `.lock` file from a concurrent or previous run. If you get stuck with a leftover `.lock` file, you will need to remove it manually; this can happen if the system loses power while a backup is in progress or if the process is terminated with `SIGKILL`.

### `--conf-dir [PATH]`

Allows you to provide a custom path to the configuration directory, as opposed to the defauls `/backup`.

The script will look for configuration files in the `conf` subdirectory of this path, and write logs to the `logs` subdirectory of this path. This path is also where the lock and timestamp files will be created.

## Requirements

- Bash
- BorgBackup
- RCLONE

## See also

- **BorgBackup**
    + [Official website](https://www.borgbackup.org/)
    + [GitHub](https://github.com/borgbackup/borg)
- **RCLONE**
    + [Official website](https://rclone.org/)
    + [GitHub](https://github.com/rclone/rclone)
