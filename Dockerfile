# Multi-stage build: builder nag-install ng dependencies, nag-prepare ng Symfony assets, at nag-warm ng production cache.
FROM php:8.3-fpm AS builder

# I-set ang working directory para sa lahat ng sunod na commands.
WORKDIR /app

# Mag-install ng kailangan na tools para sa Composer, Git, at frontend build assets.
RUN apt-get update && apt-get install -y \
    git \
    unzip \
    curl \
    nodejs \
    npm \
    && docker-php-ext-install pdo pdo_mysql \
    && rm -rf /var/lib/apt/lists/*

# Mag-install ng Composer globally para available ang Composer commands.
RUN curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

# I-allow ang Composer na tumakbo bilang root sa container.
ENV COMPOSER_ALLOW_SUPERUSER=1

# I-copy ang dependency manifests muna para leverage ang Docker caching.
COPY composer.json composer.lock ./

# Mag-install ng PHP dependencies pero huwag i-execute ang project scripts pa.
RUN composer install --no-interaction --no-scripts --optimize-autoloader

# I-copy ang application source pagkatapos na ma-cache ang dependencies.
COPY . .

# Gumawa ng default .env file kung wala pa man.
RUN if [ ! -f /app/.env ]; then \
    DB_URL=${DATABASE_URL:-${MYSQL_URL:-mysql://root@127.0.0.1:3306/app_db?serverVersion=8.0}}; \
    echo "APP_ENV=${APP_ENV:-prod}\nAPP_DEBUG=${APP_DEBUG:-false}\nAPP_SECRET=${APP_SECRET:-ChangeMe}\nDEFAULT_URI=${DEFAULT_URI:-http://localhost}\nDATABASE_URL=$DB_URL\nMAILER_DSN=${MAILER_DSN:-null://null}\nMESSENGER_TRANSPORT_DSN=${MESSENGER_TRANSPORT_DSN:-doctrine://default?auto_setup=0}\n" > /app/.env; \
    fi

# I-reinstall ang dependencies at i-optimize ang autoloader para sa production.
RUN composer install --no-interaction --optimize-autoloader --no-ansi || true

# Mag-prepare ng frontend importmap assets para sa Symfony.
RUN php bin/console importmap:install --no-interaction

# Mag-warm ng Symfony cache sa production mode para mas mabilis ang startup.
RUN php bin/console cache:warmup --env=prod --no-debug || true


FROM php:8.3-fpm AS runtime

# I-set ang working directory sa loob ng runtime container.
WORKDIR /app

# Mag-install ng nginx at curl para sa request handling at health checks.
RUN apt-get update && apt-get install -y \
    nginx \
    curl \
    && rm -rf /var/lib/apt/lists/*

# I-copy ang prepared application mula sa builder stage.
COPY --from=builder /app /app

# 1. I-extract ng safe lang ang ONLY extension configurations na generated ng docker-php-ext-install
COPY --from=builder /usr/local/etc/php/conf.d/ /usr/local/etc/php/conf.d/
COPY --from=builder /usr/local/lib/php/extensions/ /usr/local/lib/php/extensions/
# 2. I-extract ang directory na naglalaman ng actual compiled shared object (*.so) binaries
COPY --from=builder /usr/local/lib/php/extensions /usr/local/lib/php/extensions

# Gumawa ng runtime directories at i-fix ang permissions para sa web server user.
RUN mkdir -p /app/var && \
    chown -R www-data:www-data /app && \
    chmod -R 755 /app && \
    chmod -R 775 /app/var

# Gamitin ang main nginx configuration file para sa Symfony app.
COPY nginx-main.conf /etc/nginx/nginx.conf

# Tanggalin ang default nginx site configs at mag-add ng Symfony site configuration.
RUN rm -rf /etc/nginx/conf.d/* /etc/nginx/sites-enabled /etc/nginx/sites-available
COPY nginx.conf /etc/nginx/conf.d/symfony.conf

# I-copy at i-enable ang container entrypoint script.
COPY entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# Healthcheck nag-verify na ang app ay nag-serve ng HTTP ng tama.
HEALTHCHECK --interval=10s --timeout=3s --start-period=10s --retries=3 \
    CMD curl -f http://localhost/ || exit 1

# I-expose ang HTTP port 80 mula sa container.
EXPOSE 80

# I-start ang container gamit ang custom entrypoint.
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]