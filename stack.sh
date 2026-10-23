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
