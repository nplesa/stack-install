#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a LC_ALL=C

BACKUP_ROOT="${BACKUP_ROOT:-/developer/backups}"
LOG="/var/log/update-stack.log"
STAMP="$(date +%Y%m%d-%H%M%S)-$$"
BACKUP="$BACKUP_ROOT/$STAMP"
REPORT="$BACKUP/final-report.txt"
SIMULATION="$BACKUP/apt-simulation.txt"
FINALIZED=0
INSTALL_STARTED=0
BOOTSTRAP_STATUS="not performed"
DB_BACKUP_STATUS="not performed"
PHP_VERSION="" PHP_FULL_VERSION="" PHP_BASE="" MARIADB_VERSION="" NGINX_VERSION=""
declare -a ACTIONS=() WARNINGS=() PACKAGES=() SERVICES=() PHP_PACKAGES=() PHP_SELECTED=()
declare -a OPTIONAL_SELECTED=() OPTIONAL_SKIPPED=() VALIDATE_MODULES=() PHP_BASES=() VERSIONS=()
declare -A SELECTED_EXTENSIONS=()

record() { ACTIONS+=("$*"); echo "[OK] $*"; }
warn() { WARNINGS+=("$*"); echo "[WARNING] $*" >&2; }
die() { WARNINGS+=("$*"); echo "[ERROR] $*" >&2; exit 1; }
installed() { [[ "$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null || :)" == installed ]]; }
version_installed() { dpkg-query -W -f='${Version}' "$1" 2>/dev/null || :; }
apt_candidate() { apt-cache policy "$1" | awk '/^[[:space:]]*Candidate:/ && !found {value=$2; found=1} END {if (found) print value}'; }
apt_versions() { apt-cache madison "$1" | awk '{print $3}' | sort -Vu; }
has_version() { apt_versions "$1" | awk -v wanted="$2" '$0 == wanted {found=1} END {exit !found}'; }
apt_available() { local v; v="$(apt_candidate "$1")"; [[ -n "$v" && "$v" != '(none)' ]]; }

ask() {
    local answer
    while :; do
        printf '\n%s [yes/no]: ' "$1" > /dev/tty
        IFS= read -r answer < /dev/tty || die 'Unable to read terminal response.'
        case "${answer,,}" in yes|y) return 0;; no|n) return 1;; *) echo 'Enter yes or no.' > /dev/tty;; esac
    done
}
choose() {
    local prompt="$1" answer i; shift
    local -a choices=("$@")
    ((${#choices[@]})) || die "No choices for $prompt"
    printf '\n%s\n' "$prompt" > /dev/tty
    for i in "${!choices[@]}"; do printf '%d) %s\n' "$((i+1))" "${choices[$i]}" > /dev/tty; done
    while :; do
        printf 'Choose number (0 = cancel): ' > /dev/tty
        IFS= read -r answer < /dev/tty || die 'No terminal input.'
        [[ "$answer" =~ ^[0-9]{1,4}$ ]] || { echo 'Enter a valid number.' > /dev/tty; continue; }
        if ((10#$answer == 0)); then die 'Selection cancelled.'; fi
        if ((10#$answer >= 1 && 10#$answer <= ${#choices[@]})); then REPLY="${choices[$((10#$answer-1))]}"; return; fi
        echo 'Selection out of range.' > /dev/tty
    done
}
report() {
    local status="${1:-INCOMPLETE}" svc pkg
    (( FINALIZED == 0 )) || return 0
    FINALIZED=1
    [[ -d "$BACKUP" ]] || return 0
    {
        echo 'STACK UPDATE REPORT'
        echo "Date: $(date -Is)"
        echo "Result: $status"
        echo "OS: ${PRETTY_NAME:-unknown}"
        echo "PHP selected: ${PHP_VERSION:-not selected}; package version: ${PHP_FULL_VERSION:-not selected}"
        echo "MariaDB selected: ${MARIADB_VERSION:-not selected}"
        echo "Nginx selected: ${NGINX_VERSION:-not selected}"
        echo "Selected PHP extensions: ${PHP_SELECTED[*]:-none}"
        echo "Optional packages selected: ${OPTIONAL_SELECTED[*]:-none}"
        echo "Optional packages skipped: ${OPTIONAL_SKIPPED[*]:-none}"
        echo "SQL backup: $DB_BACKUP_STATUS"
        echo "Bootstrap dependencies: $BOOTSTRAP_STATUS"
        echo "Installation started: $INSTALL_STARTED"
        echo "Backup: $BACKUP"
        echo "Log: $LOG"
        echo; echo 'INSTALLED VERSIONS'
        for pkg in nginx mariadb-server "${PHP_BASE:-php}-cli" git composer nodejs npm redis-server "${PHP_BASE:-php}-redis"; do
            echo "$pkg: $(version_installed "$pkg")"
        done
        echo; echo 'SERVICES'
        for svc in "${SERVICES[@]}"; do
            echo "$svc: active=$(systemctl is-active "$svc" 2>/dev/null || :), enabled=$(systemctl is-enabled "$svc" 2>/dev/null || :)"
        done
        echo; echo 'ACTIONS'; printf ' - %s\n' "${ACTIONS[@]:-none}"
        echo; echo 'WARNINGS'; printf ' - %s\n' "${WARNINGS[@]:-none}"
        echo; echo 'BACKUP FILES'
        find "$BACKUP" -type f -printf '%p (%s bytes)\n' 2>/dev/null || :
    } > "$REPORT" || :
    cat "$REPORT"
}
on_exit() {
    local rc=$?
    trap - EXIT
    if (( rc != 0 )); then WARNINGS+=("Interrupted (exit status $rc)"); report 'FAILED / INCOMPLETE' || :
    elif (( FINALIZED == 0 )); then report 'INCOMPLETE' || :; fi
}

# Avoid any changes to the server until basic environment is checked.
(( EUID == 0 )) || { echo '[ERROR] Run as root.' >&2; exit 1; }
[[ -r /etc/os-release ]] || { echo '[ERROR] No /etc/os-release.' >&2; exit 1; }
. /etc/os-release
[[ "${ID:-}" == debian && "${VERSION_ID:-}" == 13 && "${VERSION_CODENAME:-}" == trixie ]] || {
    echo '[ERROR] This script requires Debian 13 Trixie.' >&2; exit 1;
}
[[ -r /dev/tty && -w /dev/tty ]] || { echo '[ERROR] An interactive terminal is required.' >&2; exit 1; }
# Only the bootstrap primitives must already exist. Other tools are installed below.
for cmd in apt-get dpkg-query dpkg mkdir date; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "[ERROR] Base Debian utility missing: $cmd" >&2; exit 1; }
done
mkdir -p /run/lock
# flock is supplied by util-linux on Debian; if missing, safely stop rather than run unlocked.
if ! command -v flock >/dev/null 2>&1; then
    apt-get update || { echo '[ERROR] APT update failed before installing flock.' >&2; exit 1; }
    apt-get install -y --no-install-recommends --no-remove util-linux || { echo '[ERROR] Cannot install flock.' >&2; exit 1; }
    command -v flock >/dev/null 2>&1 || { echo '[ERROR] flock still missing.' >&2; exit 1; }
fi
exec 9>/run/lock/update-stack.lock
flock -n 9 || { echo '[ERROR] Another stack.sh is running.' >&2; exit 1; }

# STEP 1: Bootstrap from existing Debian repositories, prior to using curl/gpg/tar.
# No third-party repository is used in this phase. Install only missing utilities.
echo '=== STACK BUILD: 2026-10-23-sigpipe-fix-v5 ==='
echo '=== STEP 1: BOOTSTRAP SCRIPT RUNTIME ==='
declare -a BOOTSTRAP_PACKAGES=(
    ca-certificates curl gnupg gpgv
    tar gzip coreutils findutils grep sed gawk util-linux
    python3 openssl dpkg apt
)
declare -a BOOTSTRAP_MISSING=()
for package in "${BOOTSTRAP_PACKAGES[@]}"; do
    if [[ "$(dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null || :)" != installed ]]; then
        BOOTSTRAP_MISSING+=("$package")
    fi
done
if ((${#BOOTSTRAP_MISSING[@]})); then
    printf 'Installing missing runtime packages: %s\n' "${BOOTSTRAP_MISSING[*]}"
    apt-get update || { echo '[ERROR] Cannot refresh base Debian APT metadata.' >&2; exit 1; }
    apt-get install -y --no-install-recommends --no-remove "${BOOTSTRAP_MISSING[@]}" || {
        echo '[ERROR] Unable to install bootstrap dependencies.' >&2; exit 1;
    }
else
    echo '[OK] All bootstrap dependencies already installed.'
fi
for cmd in apt-get apt-cache dpkg-query dpkg systemctl tar gzip sha256sum flock awk sed grep sort find tee curl python3 date gpg dpkg-deb mktemp install; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "[ERROR] Runtime utility still unavailable: $cmd" >&2; exit 1; }
done
BOOTSTRAP_STATUS='installed and verified'
mkdir -p "$BACKUP"
chmod 0700 "$BACKUP_ROOT" "$BACKUP"
touch "$LOG"; chmod 0600 "$LOG"
exec > >(tee -a "$LOG") 2>&1
trap on_exit EXIT

echo '=== SYSTEM ==='
echo "OS: $PRETTY_NAME"
echo "Architecture: $(dpkg --print-architecture)"

echo '=== CONFIGURATION BACKUP ==='
for path in etc/nginx etc/php etc/mysql etc/redis etc/apt; do
    if [[ -e "/$path" ]]; then
        tar -czpf "$BACKUP/${path//\//_}.tar.gz" -C / "$path" || die "Failed to back up /$path"
    fi
done
dpkg-query -W -f='${binary:Package}\t${Version}\t${db:Status-Status}\n' > "$BACKUP/packages-before.tsv"
record 'Configuration and initial package inventory backed up.'

echo '=== STEP 2: INSTALL REQUIRED REPOSITORIES ==='
# Configure trusted upstream repositories before retrieving APT metadata and listing versions.
# Never use apt-key or disable APT signature verification. Existing Debian sources stay intact.
# MariaDB is intentionally pinned to the 11.8 LTS *repository branch*; selecting a
# different MariaDB series requires adjusting MARIADB_REPO_BRANCH.
MARIADB_REPO_BRANCH="${MARIADB_REPO_BRANCH:-11.8}"
[[ "$MARIADB_REPO_BRANCH" == '11.8' ]] || die 'Only the verified MariaDB 11.8 repository branch is configured by this script.'
mkdir -p /etc/apt/keyrings /etc/apt/sources.list.d

# Warn and refuse to create duplicate/conflicting source definitions.
check_duplicate_repo() {
    local uri="$1" destination="$2" existing
    while IFS= read -r -d '' existing; do
        [[ "$existing" == "$destination" ]] && continue
        if grep -Fq -- "$uri" "$existing"; then
            die "Repository $uri already configured in $existing. Reconcile existing APT sources manually before proceeding."
        fi
    done < <(find /etc/apt -type f \( -name '*.list' -o -name '*.sources' \) -print0)
}

fetch_key() {
    local url="$1" destination="$2" expected_fingerprint="$3" tmp fingerprint
    tmp="$(mktemp)"
    if ! curl --fail --silent --show-error --location --retry 2 --connect-timeout 10 --max-time 45         "$url" -o "$tmp"; then
        rm -f "$tmp"
        die "Could not download signing key: $url"
    fi
    fingerprint="$(gpg --batch --show-keys --with-colons "$tmp" 2>/dev/null | awk -F: '$1=="fpr" {print $10}')"
    if [[ " $fingerprint " != *" $expected_fingerprint "* ]]; then
        rm -f "$tmp"
        die "Unexpected signing-key fingerprint for $url; received: ${fingerprint:-none}; expected: $expected_fingerprint"
    fi
    # APT accepts ASCII-armored keys with .asc extensions.
    install -m 0644 "$tmp" "$destination" || { rm -f "$tmp"; die "Cannot install signing key: $destination"; }
    rm -f "$tmp"
}

# nginx.org publishes three official signing keys in a single armored file.
# Require the EXACT set documented by nginx, not just one matching fingerprint.
fetch_nginx_key() {
    local url='https://nginx.org/keys/nginx_signing.key'
    local destination="$1" tmp fingerprints expected
    tmp="$(mktemp)" || die 'Cannot create temporary file for nginx signing keys.'
    if ! curl --fail --silent --show-error --location --retry 2 --connect-timeout 10 --max-time 45 "$url" -o "$tmp"; then
        rm -f "$tmp"
        die "Could not download nginx signing keys: $url"
    fi
    fingerprints="$(gpg --batch --show-keys --with-colons "$tmp" 2>/dev/null | awk -F: '$1=="fpr" {print toupper($10)}' | LC_ALL=C sort -u)"
    expected="$(printf '%s\n' \
        '8540A6F18833A80E9C1653A42FD21310B49F6B46' \
        '573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62' \
        '9E9BE90EACBCDE69FE9B204CBCDCD8A38D88A2B3' | LC_ALL=C sort -u)"
    if [[ "$fingerprints" != "$expected" ]]; then
        rm -f "$tmp"
        die "Unexpected nginx signing-key set; received: ${fingerprints:-none}; expected: $expected"
    fi
    install -m 0644 "$tmp" "$destination" || { rm -f "$tmp"; die "Cannot install nginx signing keys: $destination"; }
    rm -f "$tmp"
    record 'Nginx signing keys verified (all 3 official fingerprints).'
}

# MariaDB publishes both an armored key and an official keyring bundle.
# Verify the documented Community Server key fingerprint, then export ONLY that
# key into an isolated APT keyring. Never use a downloaded unverified key.
fetch_mariadb_key() {
    local destination="$1" expected='177F4010FE56CA3336300305F1656F24C74CD1D8'
    local url tmpdir keyfile fingerprints current
    local -a urls=(
        'https://mariadb.org/mariadb_release_signing_key.asc'
        'https://supplychain.mariadb.com/mariadb-keyring-2019.gpg'
    )
    tmpdir="$(mktemp -d)" || die 'Could not create MariaDB temporary key directory.'
    chmod 0700 "$tmpdir"
    for url in "${urls[@]}"; do
        keyfile="$tmpdir/downloaded-key"
        if ! curl --fail --silent --show-error --location --retry 2 --connect-timeout 10 --max-time 45 "$url" -o "$keyfile"; then
            warn "Unable to download MariaDB signing key: $url"
            continue
        fi
        fingerprints="$(gpg --batch --show-keys --with-colons "$keyfile" 2>/dev/null | awk -F: '$1=="fpr" {print toupper($10)}' || :)"
        if ! printf '%s\n' "$fingerprints" | grep -Fxq "$expected"; then
            warn "MariaDB key fingerprint mismatch from $url; received: ${fingerprints:-none}"
            continue
        fi
        # Import into an isolated temporary keyring and export only the pinned key.
        rm -f "$tmpdir/ring.gpg" "$tmpdir/ring.gpg~"
        if ! gpg --batch --no-default-keyring --keyring "$tmpdir/ring.gpg" --import "$keyfile" >/dev/null 2>&1; then
            warn "Could not parse MariaDB signing key from $url"
            continue
        fi
        if ! gpg --batch --no-default-keyring --keyring "$tmpdir/ring.gpg" --export "$expected" > "$tmpdir/verified.gpg"; then
            warn "Could not export verified MariaDB signing key from $url"
            continue
        fi
        if [[ ! -s "$tmpdir/verified.gpg" ]]; then
            warn "Exported MariaDB signing key is empty from $url"
            continue
        fi
        install -m 0644 "$tmpdir/verified.gpg" "$destination" || die "Cannot install verified MariaDB keyring: $destination"
        rm -rf -- "$tmpdir"
        record "MariaDB signing key verified: $expected"
        return 0
    done
    rm -rf -- "$tmpdir"
    die 'No official MariaDB key source provided the expected Community Server fingerprint; repository was not enabled.'
}

# PHP: use Sury's signed Debian archive-keyring package without executing code from it.
check_duplicate_repo 'packages.sury.org/php' /etc/apt/sources.list.d/update-stack-php.sources
SURY_PKG="$(mktemp --suffix=.deb)"
curl --fail --silent --show-error --location --retry 2 --connect-timeout 10 --max-time 45     'https://packages.sury.org/debsuryorg-archive-keyring.deb' -o "$SURY_PKG" || die 'Could not fetch Sury archive keyring package.'
SURY_TMP="$(mktemp -d)"
dpkg-deb -x "$SURY_PKG" "$SURY_TMP" || die 'Could not extract Sury keyring.'
[[ -s "$SURY_TMP/usr/share/keyrings/debsuryorg-archive-keyring.gpg" ]] || die 'Sury keyring missing from archive.'
install -m 0644 "$SURY_TMP/usr/share/keyrings/debsuryorg-archive-keyring.gpg"     /etc/apt/keyrings/update-stack-sury.gpg || die 'Could not install Sury keyring.'
rm -rf -- "$SURY_TMP" "$SURY_PKG"
cat > /etc/apt/sources.list.d/update-stack-php.sources <<EOF
Types: deb
URIs: https://packages.sury.org/php
Suites: trixie
Components: main
Signed-By: /etc/apt/keyrings/update-stack-sury.gpg
EOF
record 'PHP repository configured: packages.sury.org/php (Trixie).'

# MariaDB Community Server: upstream LTS repository.
check_duplicate_repo '/mariadb/repo/11.8/debian' /etc/apt/sources.list.d/update-stack-mariadb.sources
fetch_mariadb_key /etc/apt/keyrings/update-stack-mariadb.gpg
cat > /etc/apt/sources.list.d/update-stack-mariadb.sources <<EOF
Types: deb
URIs: https://deb.mariadb.org/11.8/debian
Suites: trixie
Components: main
Signed-By: /etc/apt/keyrings/update-stack-mariadb.gpg
EOF
record 'MariaDB repository configured: 11.8 LTS (Trixie).'

# Nginx official stable repository (not mainline).
check_duplicate_repo 'nginx.org/packages/debian' /etc/apt/sources.list.d/update-stack-nginx.sources
fetch_nginx_key /etc/apt/keyrings/update-stack-nginx.asc
cat > /etc/apt/sources.list.d/update-stack-nginx.sources <<EOF
Types: deb
URIs: https://nginx.org/packages/debian
Suites: trixie
Components: nginx
Signed-By: /etc/apt/keyrings/update-stack-nginx.asc
EOF
record 'Nginx stable repository configured: nginx.org (Trixie).'

printf '\n=== STEP 3: REFRESH APT FROM ALL REPOSITORIES ===\n'
apt-get update || die 'apt-get update failed.'
for pkg in php-cli mariadb-server nginx; do
    echo "APT policy for $pkg:"
    apt-cache policy "$pkg" || :
done

echo '=== SUPPORT LIFECYCLE ==='
# Only choose branches that are supported upstream and present in configured APT repositories.
for product in php mariadb nginx; do
    curl --fail --silent --show-error --location --retry 2 --connect-timeout 10 --max-time 30 \
        "https://endoflife.date/api/${product}.json" -o "$BACKUP/${product}-eol.json" || \
        die "Cannot verify lifecycle data for $product"
done
python3 - "$BACKUP" <<'PY'
import json
import sys
from datetime import date
from pathlib import Path
root = Path(sys.argv[1])
today = date.today()
for name in ('php','mariadb','nginx'):
    data = json.loads((root/f'{name}-eol.json').read_text())
    if not isinstance(data, list):
        raise SystemExit(f'Invalid lifecycle data for {name}')
    cycles = set()
    for entry in data:
        if not isinstance(entry,dict):
            continue
        cycle = str(entry.get('cycle',''))
        eol = entry.get('eol')
        if eol is False:
            if cycle: cycles.add(cycle)
        elif isinstance(eol, str):
            try:
                if date.fromisoformat(eol[:10]) >= today and cycle:
                    cycles.add(cycle)
            except ValueError:
                pass
    if not cycles:
        raise SystemExit(f'No supported cycles reported for {name}')
    (root/f'{name}-supported.txt').write_text('\n'.join(sorted(cycles))+'\n')
    print(f'{name}: {", ".join(sorted(cycles))}')
PY

echo '=== SELECT PHP BRANCH ==='
mapfile -t PHP_BASES < <(apt-cache pkgnames | grep -E '^php[0-9]+\.[0-9]+-cli$' | sed 's/-cli$//' | sort -Vu)
declare -a PHP_CHOICES=()
for base in "${PHP_BASES[@]}"; do
    cycle="${base#php}"
    grep -Fxq -- "$cycle" "$BACKUP/php-supported.txt" || continue
    [[ -n "$(apt_candidate "$base-cli")" ]] || continue
    if apt_available "$base-cli" && apt_available "$base-common" && apt_available "$base-fpm"; then
        PHP_CHOICES+=("$cycle")
    fi
done
((${#PHP_CHOICES[@]})) || die 'No supported PHP branch with CLI, common and FPM packages found.'
choose 'PHP branch:' "${PHP_CHOICES[@]}"
PHP_VERSION="$REPLY"; PHP_BASE="php$PHP_VERSION"

# Core PHP packages must have exactly identical Debian package versions.
mapfile -t VERSIONS < <(apt_versions "$PHP_BASE-cli")
declare -a PHP_FULL_CHOICES=()
for ver in "${VERSIONS[@]}"; do
    upstream="${ver#*:}"; upstream="${upstream%%-*}"
    [[ "$upstream" =~ ^${PHP_VERSION//./\.}\.[0-9]+$ ]] || continue
    has_version "$PHP_BASE-common" "$ver" || continue
    has_version "$PHP_BASE-fpm" "$ver" || continue
    PHP_FULL_CHOICES+=("$ver")
done
((${#PHP_FULL_CHOICES[@]})) || die 'No exact matching PHP CLI/common/FPM versions.'
choose 'Exact PHP package version:' "${PHP_FULL_CHOICES[@]}"
PHP_FULL_VERSION="$REPLY"
for suffix in cli common fpm; do PHP_PACKAGES+=("$PHP_BASE-$suffix=$PHP_FULL_VERSION"); done

# Debian's separately packaged extensions usually use the same exact version as PHP core.
# PECL packages (e.g. redis and imagick) have their own version numbering.
declare -a EXT_DEFS=(
    'mysql|MySQL (mysqli, pdo_mysql)|mysqli'
    'curl|cURL|curl'
    'mbstring|mbstring|mbstring'
    'xml|XML (dom, simplexml, xmlreader, xmlwriter)|dom'
    'zip|ZIP|zip'
    'gd|GD|gd'
    'intl|Intl|intl'
    'bcmath|BCMath|bcmath'
    'soap|SOAP|soap'
    'sqlite3|SQLite|pdo_sqlite'
    'readline|Readline|readline'
    'imagick|Imagick|imagick'
)

# OPcache is typically provided by PHP core packages on this repository; no standalone phpX.Y-opcache package is required.
echo '=== SELECT PHP EXTENSIONS ==='
for item in "${EXT_DEFS[@]}"; do
    IFS='|' read -r suffix label module <<< "$item"
    pkg="$PHP_BASE-$suffix"
    # For PHP 8.x, readline may be compiled in / supplied by the core; confirm by runtime later.
    available=no
    package_spec=""
    if [[ "$suffix" == imagick ]]; then
        if apt_available "$pkg"; then available=yes; package_spec="$pkg"; fi
    elif has_version "$pkg" "$PHP_FULL_VERSION"; then
        available=yes; package_spec="$pkg=$PHP_FULL_VERSION"
    fi
    if [[ "$available" == no ]]; then
        warn "$label: $pkg is not available in a compatible version; cannot select."
        continue
    fi
    current="not installed"
    if installed "$pkg"; then current="installed ($(version_installed "$pkg"))"; fi
    echo "$label: $pkg [$current]"
    if ask "Enable $label for PHP $PHP_VERSION?"; then
        PHP_PACKAGES+=("$package_spec")
        PHP_SELECTED+=("$label")
        VALIDATE_MODULES+=("$module")
        SELECTED_EXTENSIONS["$suffix"]=1
    fi
done

# Confirm core PHP Redis availability and presence independently of the Redis server.
echo '=== OPTIONAL COMPONENTS ==='
offer_optional() {
    local package="$1" name="$2" candidate
    if installed "$package"; then
        echo "[OK] $name already installed: $(version_installed "$package")"
        return
    fi
    if ! apt_available "$package"; then warn "$name is not installed and unavailable in APT ($package)."; return; fi
    candidate="$(apt_candidate "$package")"
    echo "$name missing. Candidate: $candidate"
    if ask "Install $name?"; then
        PACKAGES+=("$package")
        OPTIONAL_SELECTED+=("$name")
    else OPTIONAL_SKIPPED+=("$name"); fi
}
if command -v git >/dev/null 2>&1; then
    echo "[OK] Git already available: $(git --version)"
else
    offer_optional git 'Git'
fi
if command -v composer >/dev/null 2>&1; then
    echo '[OK] Composer already available.'
else
    offer_optional composer 'Composer'
fi
# Require both node and npm. If just one is missing, do not reinstall the existing component explicitly.
if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
    echo "[OK] Node.js $(node --version) and npm $(npm --version) are available."
else
    if ! command -v node >/dev/null 2>&1; then offer_optional nodejs 'Node.js'; fi
    if ! command -v npm >/dev/null 2>&1; then offer_optional npm 'npm'; fi
fi
offer_optional redis-server 'Redis Server'
REDIS_PHP_PACKAGE="$PHP_BASE-redis"
if installed "$REDIS_PHP_PACKAGE"; then
    echo "[OK] PHP Redis package already installed: $(version_installed "$REDIS_PHP_PACKAGE")"
elif apt_available "$REDIS_PHP_PACKAGE"; then
    offer_optional "$REDIS_PHP_PACKAGE" "PHP Redis extension for PHP $PHP_VERSION"
else
    warn "PHP Redis package $REDIS_PHP_PACKAGE unavailable; not selecting another PHP version's Redis extension."
fi

echo '=== SELECT MARIADB AND NGINX ==='
declare -a DB_CHOICES=() NGINX_CHOICES=()
while IFS= read -r ver; do
    normalized="${ver#*:}"; normalized="${normalized%%-*}"
    [[ "$normalized" =~ ^([0-9]+\.[0-9]+)\. ]] || continue
    grep -Fxq -- "${BASH_REMATCH[1]}" "$BACKUP/mariadb-supported.txt" && DB_CHOICES+=("$ver")
done < <(apt_versions mariadb-server)
((${#DB_CHOICES[@]})) || die 'No supported MariaDB version in configured APT sources.'
choose 'MariaDB version:' "${DB_CHOICES[@]}"; MARIADB_VERSION="$REPLY"
while IFS= read -r ver; do
    normalized="${ver#*:}"
    [[ "$normalized" =~ ^([0-9]+\.[0-9]+)\. ]] || continue
    grep -Fxq -- "${BASH_REMATCH[1]}" "$BACKUP/nginx-supported.txt" && NGINX_CHOICES+=("$ver")
done < <(apt_versions nginx)
((${#NGINX_CHOICES[@]})) || die 'No supported Nginx version in configured APT sources.'
choose 'Nginx version:' "${NGINX_CHOICES[@]}"; NGINX_VERSION="$REPLY"

PACKAGES+=("nginx=$NGINX_VERSION" "mariadb-server=$MARIADB_VERSION" "${PHP_PACKAGES[@]}")

echo '=== INSTALLATION PLAN ==='
printf ' - %s\n' "${PACKAGES[@]}"
echo "PHP extensions selected: ${PHP_SELECTED[*]:-none}"
echo "Optional components selected: ${OPTIONAL_SELECTED[*]:-none}"
echo '=== APT SIMULATION ==='
apt-get -s install "${PACKAGES[@]}" > "$SIMULATION" 2>&1 || die 'APT simulation failed (check simulation file).'
cat "$SIMULATION"
if grep -Eq '^[[:space:]]*(Remv|Purg)[[:space:]]' "$SIMULATION"; then
    die 'APT simulation proposes package removals.'
fi
if grep -Eiq 'downgrad|unmet dependencies|held broken packages' "$SIMULATION"; then
    die 'APT simulation proposes downgrades or dependency problems.'
fi

echo '=== FINAL APPROVAL ==='
echo 'APT metadata and configuration backups have been created; no packages installed yet.'
ask 'Approve the package installation plan above?' || die 'Cancelled; no package installation performed.'
record 'User approved installation.'

echo '=== DATABASE BACKUP ==='
if installed mariadb-server; then
    command -v mariadb-dump >/dev/null 2>&1 || die 'mariadb-dump missing on existing installation.'
    systemctl is-active --quiet mariadb || die 'Existing MariaDB is not active; backup is mandatory.'
    # Separate stderr allows failures to be reported without leaking SQL into the log.
    mariadb-dump --all-databases --single-transaction --routines --events --triggers \
        --hex-blob > "$BACKUP/mariadb-all.sql" 2> "$BACKUP/mariadb-dump.stderr" || die 'MariaDB dump failed.'
    [[ -s "$BACKUP/mariadb-all.sql" ]] || die 'MariaDB dump is empty.'
    gzip -c "$BACKUP/mariadb-all.sql" > "$BACKUP/mariadb-all.sql.gz" || die 'SQL gzip failed.'
    gzip -t "$BACKUP/mariadb-all.sql.gz" || die 'SQL gzip validation failed.'
    sha256sum "$BACKUP/mariadb-all.sql.gz" > "$BACKUP/mariadb-all.sql.gz.sha256"
    rm -f -- "$BACKUP/mariadb-all.sql"
    DB_BACKUP_STATUS="gzip verified: $BACKUP/mariadb-all.sql.gz"
    record 'Database backup completed, compressed, and integrity-checked.'
else
    DB_BACKUP_STATUS='MariaDB not previously installed'
fi

echo '=== PACKAGE INSTALLATION ==='
INSTALL_STARTED=1
apt-get install -y "${PACKAGES[@]}" || die 'apt-get install failed.'
record 'APT installation completed.'

echo '=== SERVICE STARTUP ==='
SERVICES=(mariadb "$PHP_BASE-fpm" nginx)
if installed redis-server; then SERVICES+=(redis-server); fi
for svc in "${SERVICES[@]}"; do
    systemctl enable --now "$svc" || die "Unable to start/enable $svc"
    systemctl is-active --quiet "$svc" || die "Service not active: $svc"
    systemctl is-enabled --quiet "$svc" || die "Service not enabled: $svc"
    record "Service active and enabled: $svc"
done

echo '=== VALIDATION ==='
nginx -t || die 'nginx -t failed.'
mariadb-admin ping || die 'MariaDB failed health check.'
"$PHP_BASE" -v || die 'Selected PHP CLI unavailable.'
"$PHP_BASE" -m > "$BACKUP/php-modules.txt" || die 'Unable to query PHP modules.'
# OPcache may be bundled with the selected PHP core build rather than separately packaged.
if "$PHP_BASE" -m | grep -Fixq 'Zend OPcache'; then
    record 'PHP OPcache available in selected PHP build.'
else
    warn 'PHP OPcache module not detected; check distribution packaging and php.ini before production.'
fi
for module in "${VALIDATE_MODULES[@]}"; do
    grep -Fixq -- "$module" "$BACKUP/php-modules.txt" || die "Selected PHP module not loaded: $module"
done
if installed "$REDIS_PHP_PACKAGE"; then "$PHP_BASE" --ri redis || die 'Redis PHP extension not loaded.'; fi
for spec in "${PHP_PACKAGES[@]}"; do
    [[ "$spec" == *=* ]] || continue
    pkg="${spec%%=*}"; version="${spec#*=}"
    [[ "$(version_installed "$pkg")" == "$version" ]] || die "Unexpected PHP package version: $pkg"
done
if installed redis-server; then
    if command -v redis-cli >/dev/null 2>&1; then
        redis-cli ping || warn 'Redis running but redis-cli ping failed (authentication/custom port possible).'
    else warn 'redis-cli not available; Redis network check omitted.'; fi
fi
for svc in "${SERVICES[@]}"; do systemctl is-active --quiet "$svc" || die "Service stopped: $svc"; done
for cmd in git composer node npm; do
    if command -v "$cmd" >/dev/null 2>&1; then
        case "$cmd" in git) git --version;; composer) composer --version;; node) node --version;; npm) npm --version;; esac
    else echo "[INFO] $cmd not installed."; fi
done
dpkg-query -W -f='${binary:Package}\t${Version}\t${db:Status-Status}\n' > "$BACKUP/packages-after.tsv"
record 'Final validation completed.'
report 'SUCCESS'
echo "Backup: $BACKUP"
echo "Log: $LOG"
echo "Report: $REPORT"
