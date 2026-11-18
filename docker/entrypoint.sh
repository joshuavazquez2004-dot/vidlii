#!/bin/sh
# VidLii container bootstrap: prepare a self-contained MariaDB instance,
# import the schema, seed the admin account and start PHP-FPM + nginx.
set -eu

APP_ROOT="/app"
DB_DIR="$APP_ROOT/.dbdata"
SOCKET="/tmp/mysqld.sock"
DB_HOST="127.0.0.1"
DB_PORT="3306"
DB_NAME="${DB_NAME:-vidlii}"
DB_USER="${DB_USER:-vidlii}"
ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@example.com}"
UPLOAD_LIMIT="${UPLOAD_LIMIT:-536870912}"
PORT="${PORT:-8080}"

log() { echo "[vidlii] $*"; }

random_string() { od -An -tx1 -N"${1:-12}" /dev/urandom | tr -d ' \n'; }

# --- writable runtime paths -------------------------------------------------
mkdir -p "$APP_ROOT/usfi/v" "$APP_ROOT/usfi/thmp" "$APP_ROOT/usfi/conv" \
         "$APP_ROOT/usfi/conv_2" "$APP_ROOT/usfi/prvw" "$APP_ROOT/cache"
mkdir -p /tmp/nginx/client_body /tmp/nginx/proxy /tmp/nginx/fastcgi \
         /tmp/nginx/uwsgi /tmp/nginx/scgi

# --- database credentials ---------------------------------------------------
# Keep the generated password stable across container restarts.
DB_PASS="${DB_PASSWORD:-}"
if [ -z "$DB_PASS" ] && [ -f "$APP_ROOT/.env" ]; then
    DB_PASS="$(sed -n 's/^password *= *"\(.*\)"$/\1/p' "$APP_ROOT/.env" | head -n1)"
fi
if [ -z "$DB_PASS" ]; then
    DB_PASS="$(random_string 16)"
fi

# --- MariaDB bootstrap ------------------------------------------------------
if [ ! -d "$DB_DIR/mysql" ]; then
    log "initializing database directory"
    mkdir -p "$DB_DIR"
    if command -v mariadb-install-db >/dev/null 2>&1; then
        mariadb-install-db --user="$(id -un)" --datadir="$DB_DIR" \
            --auth-root-authentication-method=normal --skip-test-db >/dev/null
    else
        mysql_install_db --user="$(id -un)" --datadir="$DB_DIR" \
            --auth-root-authentication-method=normal --skip-test-db >/dev/null
    fi
fi

log "starting MariaDB"
mariadbd --datadir="$DB_DIR" \
    --socket="$SOCKET" \
    --pid-file=/tmp/mysqld.pid \
    --bind-address="$DB_HOST" \
    --port="$DB_PORT" \
    --skip-name-resolve \
    --skip-log-bin \
    --character-set-server=utf8mb4 \
    --collation-server=utf8mb4_unicode_ci \
    --innodb-buffer-pool-size=128M \
    --max-connections=50 \
    --performance-schema=OFF \
    --log-error=/tmp/mariadb.err &
DB_PID=$!

db_ready=0
i=0
while [ "$i" -lt 90 ]; do
    if mariadb --socket="$SOCKET" -u root -e "SELECT 1" >/dev/null 2>&1; then
        db_ready=1
        break
    fi
    if ! kill -0 "$DB_PID" 2>/dev/null; then
        break
    fi
    i=$((i + 1))
    sleep 1
done

if [ "$db_ready" -ne 1 ]; then
    log "database failed to start"
    tail -n 40 /tmp/mariadb.err 2>/dev/null || true
    exit 1
fi

mariadb --socket="$SOCKET" -u root <<SQL
CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$DB_USER'@'$DB_HOST' IDENTIFIED BY '$DB_PASS';
ALTER USER '$DB_USER'@'$DB_HOST' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'$DB_HOST';
FLUSH PRIVILEGES;
SQL

# --- schema + first-run seed ------------------------------------------------
HAS_USERS="$(mariadb --socket="$SOCKET" -u root -N -B -e \
    "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$DB_NAME' AND table_name='users'")"

if [ "$HAS_USERS" = "0" ]; then
    log "importing schema.sql"
    mariadb --socket="$SOCKET" -u root "$DB_NAME" < "$APP_ROOT/schema.sql"

    ADMIN_PASS="${ADMIN_PASSWORD:-}"
    GENERATED=0
    if [ -z "$ADMIN_PASS" ]; then
        ADMIN_PASS="$(random_string 8)"
        GENERATED=1
    fi
    ADMIN_HASH="$(php -r 'echo password_hash($argv[1], PASSWORD_BCRYPT);' "$ADMIN_PASS")"

    mariadb --socket="$SOCKET" -u root "$DB_NAME" <<SQL || log "WARNING: could not create the initial admin account"
INSERT INTO users (username, displayname, email, password, reg_date, last_login, birthday, \`1st_latest_ip\`, country, partner, is_admin, is_mod)
VALUES ('$ADMIN_USERNAME', '$ADMIN_USERNAME', '$ADMIN_EMAIL', '$ADMIN_HASH', NOW(), NOW(), '1910-01-01', '127.0.0.1', 'US', 1, 1, 1);
SQL

    if [ "$GENERATED" = "1" ]; then
        log "admin account created -> username: $ADMIN_USERNAME | password: $ADMIN_PASS"
        log "set ADMIN_PASSWORD in the environment to choose your own password"
    else
        log "admin account created -> username: $ADMIN_USERNAME (password from ADMIN_PASSWORD)"
    fi
fi

# --- application configuration ---------------------------------------------
# Always (re)written so a restart reuses the same database credentials.
cat > "$APP_ROOT/.env" <<ENVFILE
database = "mysqli://$DB_USER:$DB_PASS@$DB_HOST:$DB_PORT/$DB_NAME?charset=utf8mb4"
host = "$DB_HOST"
db = "$DB_NAME"
username = "$DB_USER"
password = "$DB_PASS"
uploadLimit = $UPLOAD_LIMIT
title = "${SITE_TITLE:-VidLii}"
slogan = "${SITE_SLOGAN:-Display Yourself!}"
ENVFILE
chmod 600 "$APP_ROOT/.env"

# --- PHP-FPM + nginx --------------------------------------------------------
if grep -q "listen 8080;" /etc/nginx/nginx.conf; then
    sed -i "s/listen 8080;/listen $PORT;/" /etc/nginx/nginx.conf
fi

log "starting PHP-FPM and nginx on port $PORT"
php-fpm -F -y /usr/local/etc/php-fpm.conf &

i=0
while [ "$i" -lt 30 ]; do
    if php -r '$s = @fsockopen("127.0.0.1", 9000); exit($s ? 0 : 1);' >/dev/null 2>&1; then
        break
    fi
    i=$((i + 1))
    sleep 1
done

exec nginx -c /etc/nginx/nginx.conf -g 'daemon off;'
