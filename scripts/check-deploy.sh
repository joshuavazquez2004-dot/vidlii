#!/bin/sh
# Verifies the VidLii deployment artifacts in this repository.
# Exits nonzero when any deploy requirement is not met.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT" || exit 1

fail=0
ok()  { printf 'ok   - %s\n' "$1"; }
bad() { printf 'FAIL - %s\n' "$1"; fail=1; }

# has <file> <extended-regex> <description>
has() {
    if [ ! -f "$1" ]; then
        bad "$3 ($1 is missing)"
    elif grep -Eq "$2" "$1"; then
        ok "$3"
    else
        bad "$3 (pattern not found in $1)"
    fi
}

# lacks <file> <extended-regex> <description>
lacks() {
    if [ ! -f "$1" ]; then
        bad "$3 ($1 is missing)"
    elif grep -Eq "$2" "$1"; then
        bad "$3 (forbidden pattern found in $1)"
    else
        ok "$3"
    fi
}

echo "== entrypoint =="
if sh -n docker/entrypoint.sh 2>/dev/null; then
    ok "docker/entrypoint.sh parses as POSIX shell"
else
    bad "docker/entrypoint.sh has shell syntax errors"
fi
has  docker/entrypoint.sh 'sed .*listen \$PORT'      "entrypoint renders the listen port from PORT"
has  docker/entrypoint.sh '> /tmp/nginx\.conf'       "entrypoint writes the nginx config to a writable path"
has  docker/entrypoint.sh 'nginx -c /tmp/nginx\.conf' "entrypoint starts nginx with the rendered config"
has  docker/entrypoint.sh 'php-fpm'                  "entrypoint starts php-fpm"
has  docker/entrypoint.sh '127\.0\.0\.1.*9000'       "entrypoint waits for php-fpm on port 9000"
has  docker/entrypoint.sh 'schema\.sql'              "entrypoint imports the database schema"
lacks docker/entrypoint.sh 'sed -i .*/etc/nginx'     "entrypoint never edits /etc/nginx as non-root"

echo "== nginx =="
has  docker/nginx.conf 'listen 8080;'                          "nginx listens on the exposed port"
has  docker/nginx.conf 'root /app;'                            "nginx serves the application root"
has  docker/nginx.conf 'include /etc/nginx/fastcgi_params;'     "fastcgi_params is included by absolute path"
lacks docker/nginx.conf 'include fastcgi_params;'              "no relative fastcgi_params include remains"
has  docker/nginx.conf 'fastcgi_pass 127\.0\.0\.1:9000'         "php requests are proxied to php-fpm"
has  docker/nginx.conf 'rewrite \^ /index\.php last'            "unknown paths fall through to the front controller"
has  docker/nginx.conf 'location \^~ /vendor/ \{ deny all; \}'   "vendor/ is not downloadable"
has  docker/nginx.conf 'location \^~ /_includes/ \{ deny all; \}' "application internals are not downloadable"
has  docker/nginx.conf 'location \^~ /docker/ \{ deny all; \}'   "docker/ is not downloadable"
has  docker/nginx.conf 'location = /schema\.sql \{ deny all; \}' "schema.sql is not downloadable"
has  docker/nginx.conf 'location ~ /\\\.\(\?!well-known\)'        "dotfiles such as .env are not downloadable"
has  docker/nginx.conf 'client_body_temp_path /tmp/nginx'        "nginx temp paths are writable by the app user"

echo "== php =="
has  docker/php.ini 'short_open_tag\s*=\s*On'                    "short_open_tag is enabled for the legacy templates"
has  docker/www.conf 'listen\s*=\s*127\.0\.0\.1:9000'              "php-fpm listens on 9000"

echo "== image =="
has  Dockerfile '^FROM php:[0-9.]+-fpm-alpine'                    "final image is Alpine based"
lacks Dockerfile '^FROM .*(slim|bookworm|bullseye|debian)'        "no Debian-based stage is used"
has  Dockerfile 'apk upgrade --no-cache'                          "OS packages are upgraded at build time"
has  Dockerfile 'EXPOSE 8080'                                     "image exposes the deployment port"
has  Dockerfile '^USER app'                                       "image runs as a non-root user"
has  Dockerfile '(CMD|ENTRYPOINT).*entrypoint\.sh'                "image starts through the entrypoint"
lacks Dockerfile 'rm -rf /var/cache/apk'                          "apk cache is preserved for the image scan"
has  Dockerfile 'chown -R app:app /app'                           "application files are owned by the app user"

echo "== dependencies =="
if php -r 'exit(json_decode(file_get_contents("composer.json")) === null ? 1 : 0);'; then
    ok "composer.json is valid JSON"
else
    bad "composer.json is not valid JSON"
fi
if php -r 'exit(json_decode(file_get_contents("composer.lock")) === null ? 1 : 0);'; then
    ok "composer.lock is valid JSON"
else
    bad "composer.lock is not valid JSON"
fi
if php -r '
    $lock = json_decode(file_get_contents("composer.lock"), true);
    $locked = array();
    foreach (array_merge($lock["packages"] ?? array(), $lock["packages-dev"] ?? array()) as $p) {
        $locked[$p["name"]] = true;
    }
    $manifest = json_decode(file_get_contents("composer.json"), true);
    foreach (array_keys($manifest["require"] ?? array()) as $name) {
        if ($name !== "php" && strpos($name, "ext-") !== 0 && !isset($locked[$name])) {
            fwrite(STDERR, "not locked: $name\n");
            exit(1);
        }
    }
    exit(0);
'; then
    ok "every required package is locked in composer.lock"
else
    bad "composer.json requires packages that composer.lock does not contain"
fi

echo "== php syntax =="
php_files=0
php_bad=0
# The legacy templates rely on <? short tags, so lint with short_open_tag=On,
# matching docker/php.ini. Without it php -l misreads ?> and reports false errors.
for f in $(find . -name '*.php' -not -path './vendor/*' -not -path './.git/*'); do
    php_files=$((php_files + 1))
    if ! php -d short_open_tag=On -l "$f" >/dev/null 2>&1; then
        php_bad=$((php_bad + 1))
        printf 'FAIL - php syntax error in %s\n' "$f"
    fi
done
if [ "$php_bad" -eq 0 ]; then
    ok "all $php_files application PHP files pass php -l"
else
    bad "$php_bad of $php_files PHP files failed php -l"
fi

echo "== front controller =="
has index.php 'vendor/autoload\.php' "index.php boots through the Composer autoloader"

if [ "$fail" -ne 0 ]; then
    echo "RESULT: FAILED"
    exit 1
fi
echo "RESULT: PASSED"
