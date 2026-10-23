<<<<<<< HEAD
Something
=======
# stack.sh — Debian 13 Server Stack Installer and Updater

`stack.sh` is an interactive Bash script for installing or updating a Debian 13 (Trixie) web-server stack. It lets an administrator select available PHP, MariaDB, and Nginx package versions, choose PHP extensions and optional development services, review an APT simulation, and approve the final package installation.

> **Important:** This script changes system packages and services. Test it on a disposable Debian 13 VM and arrange an independent, restorable backup before using it on a production server. It is **not** a zero-downtime upgrader or an automatic rollback tool.

## Requirements

- Debian **13 (Trixie)** with `systemd` and APT.
- Root access and an **interactive terminal** (`/dev/tty`). The script is not designed for unattended cron execution.
- Working APT repositories for the desired package versions. PHP packages must be available under version-specific names such as `php8.4-cli`, `php8.4-common`, and `php8.4-fpm`.
- Network access to the configured APT repositories and `https://endoflife.date/api/` (used to filter supported release branches).
- Existing prerequisite commands: `apt-get`, `apt-cache`, `dpkg-query`, `dpkg`, `systemctl`, `tar`, `gzip`, `sha256sum`, `flock`, `awk`, `sed`, `grep`, `sort`, `find`, `tee`, `curl`, `python3`, and `date`.
- Enough free disk space for configuration archives, an SQL dump if MariaDB is already installed, and APT operations.

The script **does not configure additional APT repositories** for PHP, MariaDB, Nginx, or Node.js. Versions and packages that are absent from configured repositories cannot be selected.

## Quick start

```bash
chmod +x stack.sh
sudo ./stack.sh
```

For a custom backup directory:

```bash
sudo BACKUP_ROOT=/srv/backups/stack ./stack.sh
```

The default backup directory is `/developer/backups`. Run it from a terminal and answer each prompt; entering `0` in a version menu cancels the run.

## Interactive workflow

1. **Check the host:** confirm Debian 13/Trixie, root privileges, an interactive terminal, required commands, and an exclusive lock at `/run/lock/update-stack.lock`.
2. **Back up configuration:** archive existing `/etc/nginx`, `/etc/php`, `/etc/mysql`, `/etc/redis`, and `/etc/apt`; save a pre-installation package inventory.
3. **Refresh APT metadata:** run `apt-get update`.
4. **Check upstream support:** retrieve PHP, MariaDB, and Nginx release-lifecycle data from endoflife.date; only offer supported branches found in APT.
5. **Choose PHP:** select a PHP branch and an exact Debian package version shared by `phpX.Y-cli`, `phpX.Y-common`, and `phpX.Y-fpm`.
6. **Choose PHP extensions:** answer a separate yes/no prompt for every compatible, available extension.
7. **Choose optional components:** detect existing software and offer missing APT packages for installation.
8. **Choose MariaDB and Nginx:** select offered package versions available from APT and eligible under the lifecycle filter.
9. **Review the plan:** run `apt-get -s install` and print the simulated changes. Abort if the simulation fails or shows package removals, downgrades, or recognized dependency problems.
10. **Approve:** request explicit final confirmation before any package installation.
11. **Back up existing MariaDB:** if `mariadb-server` is already installed, require an active MariaDB service and a successful SQL dump before continuing.
12. **Install:** execute `apt-get install -y` for the approved packages.
13. **Start and validate:** enable and start services, check Nginx/MariaDB/PHP, verify selected PHP modules and pinned package versions, and generate a report.

**Before the final approval, the script has already created backups, refreshed APT metadata, contacted the lifecycle API, and written its log.** The approval gate applies to package installation, not to all system changes.

## PHP extensions

The script offers these extensions when a suitable APT package exists:

| Extension | Package suffix | Runtime validation module |
| --- | --- | --- |
| MySQL | `mysql` | `mysqli` |
| cURL | `curl` | `curl` |
| mbstring | `mbstring` | `mbstring` |
| XML | `xml` | `dom` |
| ZIP | `zip` | `zip` |
| GD | `gd` | `gd` |
| Intl | `intl` | `intl` |
| BCMath | `bcmath` | `bcmath` |
| SOAP | `soap` | `soap` |
| OPcache | `opcache` | `Zend OPcache` |
| SQLite | `sqlite3` | `pdo_sqlite` |
| Readline | `readline` | `readline` |
| Imagick | `imagick` | `imagick` |

Most extensions must have the **same Debian package version** as the selected PHP core packages. Imagick is handled separately because its package uses its own version numbering. A selected extension is checked using `phpX.Y -m` after installation.

Selecting an extension adds it to the installation plan even when its package is already installed; APT determines whether a change is required. Not selecting an already installed extension does **not** uninstall it.

## Optional components

| Component | Detection and behavior |
| --- | --- |
| Git | Use existing `git` command, or offer the `git` APT package. |
| Composer | Use existing `composer` command, or offer `composer`. |
| Node.js | Use existing `node` command, or offer `nodejs`. |
| npm | Use existing `npm` command, or offer `npm`. |
| Redis Server | Check whether `redis-server` is installed; otherwise offer installation. |
| PHP Redis extension | Check `phpX.Y-redis` for the selected PHP branch; otherwise offer that package if available. |

These are **optional**, not installed automatically without selection. Existing commands may come from outside APT; the script reports them as available and does not explicitly reinstall them. Redis Server and the PHP Redis extension are independent choices.

## Backup files and log

Each run uses a timestamped directory with a process ID, by default:

```text
/developer/backups/YYYYMMDD-HHMMSS-PID/
├── etc_nginx.tar.gz          # if /etc/nginx exists
├── etc_php.tar.gz            # if /etc/php exists
├── etc_mysql.tar.gz          # if /etc/mysql exists
├── etc_redis.tar.gz          # if /etc/redis exists
├── etc_apt.tar.gz            # if /etc/apt exists
├── packages-before.tsv
├── php-eol.json
├── mariadb-eol.json
├── nginx-eol.json
├── php-supported.txt
├── mariadb-supported.txt
├── nginx-supported.txt
├── apt-simulation.txt        # once the APT simulation runs
├── mariadb-all.sql.gz        # only for existing MariaDB
├── mariadb-all.sql.gz.sha256 # only when the SQL backup succeeds
├── mariadb-dump.stderr       # only for existing MariaDB
├── php-modules.txt           # after PHP validation runs
├── packages-after.tsv        # after installation/validation
└── final-report.txt
```

Files are created only when the corresponding step runs. The script writes a cumulative log to:

```text
/var/log/update-stack.log
```

It applies restrictive permissions (`umask 077`, backup directory mode `0700`, log mode `0600`). Backups may contain credentials and other secrets; keep them protected and include them in your retention policy.

### MariaDB backup

If MariaDB was already installed, the script uses `mariadb-dump --all-databases --single-transaction --routines --events --triggers --hex-blob`, compresses the dump, tests gzip integrity, and creates a SHA-256 checksum. Failure stops installation.

**Gzip integrity and a checksum do not prove that the SQL backup can be restored.** Test recovery separately. `--single-transaction` does not ensure a consistent snapshot of every possible storage engine or concurrent schema change.

## Post-installation checks

The script attempts to enable and start these services:

- `mariadb`
- `phpX.Y-fpm` for the selected PHP branch
- `nginx`
- `redis-server` if the package is installed

It runs `nginx -t`, `mariadb-admin ping`, `phpX.Y -v`, selected-module checks using `phpX.Y -m`, version checks for explicitly pinned PHP packages, and service-active checks. It also prints versions of available Git, Composer, Node.js, and npm commands. A Redis `redis-cli ping` failure is a **warning** (for example, if authentication or a custom port is configured).

The report records selected/installed versions, chosen and skipped components, backups, actions, warnings, and service status. An interrupted run produces a `FAILED / INCOMPLETE` report when reporting is available.

## Operational limitations

- **No automatic rollback:** if APT installation or post-installation validation fails, previously applied changes remain. Restore manually from a verified backup or snapshot.
- **Services may restart:** package maintenance and `systemctl enable --now` can interrupt active requests. Plan a maintenance window.
- **Nginx/PHP-FPM integration is not migrated:** a virtual host that points to an older PHP-FPM socket will not automatically be reconfigured to use the new version.
- **Existing PHP branches are not removed:** multiple PHP versions may remain installed; the default `php` alternative is not explicitly changed.
- **APT can change installed packages through dependencies:** even if an optional command already exists and was not explicitly selected, APT may still adjust related packages.
- **Limited APT safety scan:** the simulation blocks recognized removals, downgrades, and dependency errors, but is not a complete analysis of all maintainer-script effects or configuration changes.
- **Lifecycle filtering depends on external data:** lack of network access or mismatches between APT packaging and endoflife.date release names can stop the script.
- **No repository bootstrap:** add and validate appropriate repositories yourself before running.
- **No unattended mode:** the script requires user input and cannot safely run non-interactively.

## Troubleshooting

Review the latest report, simulation, and log:

```bash
sudo less /var/log/update-stack.log
sudo ls -lt /developer/backups
sudo less /developer/backups/<run-directory>/final-report.txt
sudo less /developer/backups/<run-directory>/apt-simulation.txt
```

Inspect system services and PHP independently:

```bash
sudo systemctl status nginx mariadb redis-server
sudo nginx -t
php8.4 -v                  # replace with your selected PHP version
php8.4 -m                  # replace with your selected PHP version
sudo systemctl status php8.4-fpm
```

If the script reports that a required package version is unavailable, inspect your configured repositories with `apt-cache policy <package>` and `apt-cache madison <package>`. Do not bypass APT's dependency errors or force-install a mismatched PHP extension.

## License

No license is specified in the supplied script. Add one if you intend to distribute it.
>>>>>>> 810f7ff (Initial commit)
