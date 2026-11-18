# Deployment notes

This fork runs on AppJet as a single container.

- **Live URL:** https://gcchefac68.dev.ap-jt.com
- **Branch:** `appjet` (AppJet deploys from this branch)

## Stack

One image, built from `Dockerfile`:

| Component | Detail |
| --- | --- |
| Base | `php:8.4.27-fpm-alpine` |
| PHP-FPM | listens on `9000`, `short_open_tag=On` for the legacy templates |
| nginx | listens on `8080` (the exposed deployment port) |
| MariaDB | started inside the container by the entrypoint |
| ffmpeg | installed for video thumbnail generation |
| User | non-root `app` |

Because the container does not run as root, nginx cannot write its config into
`/etc/nginx`. The entrypoint renders the config to `/tmp/nginx.conf`, and any
`include fastcgi_params;` must use the absolute path
`/etc/nginx/fastcgi_params`, otherwise nginx resolves it against `/tmp` and
refuses to start.

## Startup provisioning

`docker/entrypoint.sh` runs on every container start and:

1. starts MariaDB and waits for it to accept connections,
2. imports `schema.sql` when the database is empty,
3. writes `.env` with the database credentials and site URL,
4. creates the admin account when it does not exist,
5. starts php-fpm and nginx in the foreground.

No environment variables are required: every value is generated inside the
container, so the app boots with no manual setup.

## Data persistence

The Free plan has no persistent disk, so **the database is recreated on every
deploy** — accounts and uploaded videos do not survive a redeploy. The admin
account is re-created automatically at startup.

Persistent disks and custom domains require Starter ($5/month) or Pro
(Settings → Billing).

## Verification

```sh
sh scripts/check-deploy.sh   # container, nginx, php, image, media fallbacks, composer lock, php -l
composer test                # same check, via Composer
```

`scripts/check-deploy.sh` exits non-zero and prints `RESULT: FAILED` when any
assertion breaks, so it is safe to use as a gate before deploying.

## Fixed in this deployment

- `_includes/_libs/PHPMailerAutoload.php` used `__autoload()`, which is a fatal
  error on PHP 8. Removed in favour of the Composer autoloader.
- Missing avatars and thumbnails returned 403 because the dotfile deny rule
  matched extensionless paths. Shipped `vi/ava/default.jpg` and
  `vi/default.jpg` placeholders and added `try_files` fallbacks that are
  matched **before** the deny rule. `user_avatar()` and `user_avatar2()` no
  longer emit an empty filename.
