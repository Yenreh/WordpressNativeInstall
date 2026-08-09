#!/bin/bash

# ==========================
# CONFIGURATION
# ==========================

WP_CONTAINER_NAME="wordpress-fpm"
FPM_PORT="9000"

DB_HOST="127.0.0.1"
DB_PORT="3306"
DB_NAME="example_db"
DB_USER="example_wp_admin"
DB_PASSWORD="changeme"

WP_VOLUME="wp_data"

# Path where WordPress files will be stored on the host
# (required for host Nginx to serve static files)
WP_HOST_PATH="/apps/example_wp"

# Nginx configuration paths on the host
NGINX_CONF_PATH="/etc/nginx/sites-available"
NGINX_ENABLED_PATH="/etc/nginx/sites-enabled"
NGINX_SITE_NAME="wordpress-example"

# SSL certificate paths
SSL_PATH="/apps/ssl/example_wp"
SSL_CERT="$SSL_PATH/server.crt"
SSL_KEY="$SSL_PATH/server.key"

SERVER_NAME="example_wp.com"

# ==========================
# DO NOT EDIT BELOW
# ==========================

echo "Starting WordPress (FPM) for use with host Nginx"

# Check if running as root (required to write to /etc/nginx)
if [ "$EUID" -ne 0 ]; then
  echo "This script requires root permissions to configure Nginx"
  echo "Run with: sudo $0"
  exit 1
fi

# Create WordPress directory on host if it doesn't exist
if [ ! -d "$WP_HOST_PATH" ]; then
  echo "Creating WordPress directory: $WP_HOST_PATH"
  mkdir -p "$WP_HOST_PATH"
fi

# Create SSL directory and generate self-signed certificate if it doesn't exist
if [ ! -d "$SSL_PATH" ]; then
  echo "Creating SSL directory: $SSL_PATH"
  mkdir -p "$SSL_PATH"
fi

if [ ! -f "$SSL_CERT" ] || [ ! -f "$SSL_KEY" ]; then
  echo "Generating self-signed SSL certificate..."
  openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout "$SSL_KEY" \
    -out "$SSL_CERT" \
    -subj "/C=US/ST=State/L=City/O=Organization/CN=$SERVER_NAME"
  echo "SSL certificate generated at: $SSL_PATH"
fi

docker pull wordpress:6.9-php8.4-fpm-alpine

docker rm -f "$WP_CONTAINER_NAME" 2>/dev/null

docker volume create "$WP_VOLUME" >/dev/null

# Create Nginx configuration for the host
echo "Creating Nginx configuration..."
cat > "$NGINX_CONF_PATH/$NGINX_SITE_NAME" <<EOF
server {
    listen 80;
    server_name $SERVER_NAME;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name $SERVER_NAME;

    ssl_certificate $SSL_CERT;
    ssl_certificate_key $SSL_KEY;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    root $WP_HOST_PATH;
    index index.php index.html;

    access_log /var/log/nginx/${NGINX_SITE_NAME}_access.log;
    error_log /var/log/nginx/${NGINX_SITE_NAME}_error.log;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php\$ {
        include fastcgi_params;
        fastcgi_pass 127.0.0.1:$FPM_PORT;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_read_timeout 300;
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)\$ {
        expires max;
        log_not_found off;
    }

    location ~ /\. {
        deny all;
    }
}
EOF

# Enable the site in Nginx
ln -sf "$NGINX_CONF_PATH/$NGINX_SITE_NAME" "$NGINX_ENABLED_PATH/$NGINX_SITE_NAME"

# Validate Nginx configuration before starting WordPress container
echo "Validating Nginx configuration..."
nginx -t

if [ $? -ne 0 ]; then
  echo "Error: Nginx configuration is invalid. Please review manually."
  echo "Removing created configuration..."
  rm -f "$NGINX_CONF_PATH/$NGINX_SITE_NAME"
  rm -f "$NGINX_ENABLED_PATH/$NGINX_SITE_NAME"
  exit 1
fi

echo "Nginx configuration is valid."

# Start WordPress FPM container exposing port 9000
echo "Starting WordPress FPM container..."
docker run -d \
  --name "$WP_CONTAINER_NAME" \
  --restart always \
  -p "$FPM_PORT:9000" \
  -e WORDPRESS_DB_HOST="$DB_HOST:$DB_PORT" \
  -e WORDPRESS_DB_NAME="$DB_NAME" \
  -e WORDPRESS_DB_USER="$DB_USER" \
  -e WORDPRESS_DB_PASSWORD="$DB_PASSWORD" \
  -v "$WP_HOST_PATH:/var/www/html" \
  wordpress:6.9-php8.4-fpm-alpine

# Wait for WordPress to initialize files
echo "Waiting for WordPress to initialize files..."
sleep 10

# Reload Nginx
echo "Reloading Nginx..."
systemctl reload nginx

echo ""
echo "✓ WordPress is available at https://$SERVER_NAME"
echo "✓ WordPress files located at: $WP_HOST_PATH"
echo "✓ SSL certificates at: $SSL_PATH"
echo "✓ Nginx configuration at: $NGINX_CONF_PATH/$NGINX_SITE_NAME"
