FROM php:8.4.27-fpm-alpine

LABEL org.opencontainers.image.title="VidLii" \
      org.opencontainers.image.description="VidLii video sharing platform (PHP + MariaDB)"

# OS refresh + web server, database and media tooling, plus the build headers
# required to compile the PHP extensions the application needs.
RUN echo "os-refresh 2026-11-18" && apk upgrade --no-cache && apk add --no-cache \
      nginx \
      mariadb \
      mariadb-client \
      ffmpeg \
      tzdata \
      icu-dev \
      libpng-dev \
      libjpeg-turbo-dev \
      freetype-dev \
      libzip-dev \
 && docker-php-ext-configure gd --with-freetype --with-jpeg \
 && docker-php-ext-install -j"$(nproc)" intl gd mysqli pdo_mysql zip exif bcmath opcache \
 && apk del icu-dev libpng-dev libjpeg-turbo-dev freetype-dev libzip-dev \
 && rm -rf /usr/src/php.tar.xz /tmp/pear

# Non-root runtime user (hosting runs containers without privileges).
RUN addgroup -g 10001 -S app \
 && adduser -u 10001 -S -G app -h /app app

COPY docker/php.ini /usr/local/etc/php/conf.d/zz-vidlii.ini
COPY docker/www.conf /usr/local/etc/php-fpm.d/www.conf
COPY docker/nginx.conf /etc/nginx/nginx.conf

WORKDIR /app
COPY --chown=app:app . /app

# Writable runtime directories: media storage, template cache, embedded DB data.
RUN mkdir -p /app/usfi/v /app/usfi/thmp /app/usfi/conv /app/usfi/conv_2 /app/usfi/prvw \
             /app/cache /app/.dbdata \
 && chmod +x /app/docker/entrypoint.sh \
 && chown -R app:app /app

ENV PORT=8080
EXPOSE 8080
USER app

CMD ["/app/docker/entrypoint.sh"]
