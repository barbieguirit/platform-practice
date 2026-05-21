#!/bin/bash
set -e

# Map MYSQL_URL to DATABASE_URL if not set (common sa Railway)
if [ -z "$DATABASE_URL" ] && [ -n "$MYSQL_URL" ]; then
    export DATABASE_URL="$MYSQL_URL"
    echo "Exported DATABASE_URL from MYSQL_URL"
fi

if [ -z "$DATABASE_URL" ]; then
    echo "ERROR: No DATABASE_URL or MYSQL_URL set!"
    exit 1
fi

echo "DATABASE_URL is: $DATABASE_URL"

# Wait for MySQL to be ready
echo "Waiting for database connection..."
MAX_TRIES=30
COUNT=0
until php bin/console dbal:run-sql "SELECT 1" > /dev/null 2>&1; do
    COUNT=$((COUNT + 1))
    if [ $COUNT -ge $MAX_TRIES ]; then
        echo "ERROR: Database not reachable after $MAX_TRIES attempts. Giving up."
        exit 1
    fi
    echo "Database not ready yet (attempt $COUNT/$MAX_TRIES), retrying in 2s..."
    sleep 2
done

echo "Database ready!"

echo "Running database migrations..."
php bin/console doctrine:migrations:migrate --no-interaction --allow-no-migration

echo "Starting PHP-FPM..."
php-fpm -F &
PHP_PID=$!

echo "Waiting for PHP-FPM to start..."
sleep 2

echo "Starting Nginx..."
nginx -g "daemon off;"

wait $PHP_PID