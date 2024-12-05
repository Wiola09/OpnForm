# Bazni image za JavaScript build
FROM node:20-alpine AS javascript-builder
WORKDIR /app

# Dodavanje samo potrebnih fajlova za build
ADD client/package.json client/package-lock.json ./
RUN npm install --legacy-peer-deps

# Dodavanje ostatka klijentskog koda i build
ADD client /app/
RUN cp .env.docker .env
RUN npm run build

# Bazni image za PHP dependency instalaciju
FROM --platform=linux/amd64 ubuntu:22.04 AS php-dependency-installer

ARG PHP_PACKAGES

# Dodavanje PostgreSQL i drugih paketa
RUN apt-get update && apt-get install -y \
    wget gnupg2 lsb-release \
    && echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list \
    && wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | apt-key add - \
    && apt-get update && apt-get install -y \
    $PHP_PACKAGES composer postgresql-15 redis php8.1-fpm && \
    apt-get clean

WORKDIR /app
ADD composer.json composer.lock artisan ./

# Optimizacija za composer install bez ponovnog preuzimanja zavisnosti
RUN sed 's_@php artisan package:discover_/bin/true_;' -i composer.json
ADD app/helpers.php /app/app/helpers.php
RUN composer install --ignore-platform-req=php

# Dodavanje aplikacije
ADD app /app/app
ADD bootstrap /app/bootstrap
ADD config /app/config
ADD database /app/database
ADD public public
ADD routes routes
ADD tests tests

# Pokretanje artisan komandi
RUN php artisan package:discover --ansi

# Glavni bazni image za aplikaciju
FROM --platform=linux/amd64 ubuntu:22.04

# Komanda za pokretanje supervisora
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/supervisord.conf"]

WORKDIR /app

ARG PHP_PACKAGES

# Instalacija PHP, PostgreSQL, Redis i drugih paketa
RUN apt-get update && apt-get install -y \
    supervisor nginx sudo postgresql-15 redis \
    $PHP_PACKAGES php8.1-fpm wget && \
    apt-get clean

# Kreiranje korisnika za Nuxt aplikaciju
RUN useradd nuxt && mkdir ~nuxt && chown nuxt ~nuxt
RUN wget -qO- https://raw.githubusercontent.com/creationix/nvm/v0.39.3/install.sh | sudo -u nuxt bash
RUN sudo -u nuxt bash -c ". ~nuxt/.nvm/nvm.sh && nvm install --no-progress 20"

# Dodavanje wrapper skripti i konfiguracija
ADD docker/postgres-wrapper.sh docker/php-fpm-wrapper.sh docker/redis-wrapper.sh docker/nuxt-wrapper.sh docker/generate-api-secret.sh /usr/local/bin/
ADD docker/php-fpm.conf /etc/php/8.1/fpm/pool.d/
ADD docker/nginx.conf /etc/nginx/sites-enabled/default
ADD docker/supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# Dodavanje ostatka aplikacije
ADD . .
ADD .env.docker .env
ADD client/.env.docker client/.env

# Kopiranje buildovanog nuxt-a
COPY --from=javascript-builder /app/.output/ ./nuxt/
RUN cp -r nuxt/public .

# Kopiranje vendor foldera sa PHP zavisnostima
COPY --from=php-dependency-installer /app/vendor/ ./vendor/

# Podešavanje permisija i konfiguracija
RUN chmod a+x /usr/local/bin/*.sh /app/artisan \
    && ln -s /app/artisan /usr/local/bin/artisan \
    && useradd opnform \
    && echo "daemon off;" >> /etc/nginx/nginx.conf \
    && echo "daemonize no" >> /etc/redis/redis.conf \
    && echo "appendonly yes" >> /etc/redis/redis.conf \
    && echo "dir /persist/redis/data" >> /etc/redis/redis.conf

EXPOSE 80
