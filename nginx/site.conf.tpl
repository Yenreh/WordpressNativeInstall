# =============================================================================
# nginx site config for {{DOMAIN}} - rendered by bin/install-wordpress.
#
# Double-brace placeholders are replaced at render time. $host, $uri,
# $document_root and the other $-prefixed names are nginx variables: leave them alone.
# Regenerate with: bin/install-wordpress --config <site.env> (or bin/console nginx)
# =============================================================================

server {
    listen 80;
    listen [::]:80;
    server_name {{DOMAIN}};

    # Everything is served over TLS.
    return 301 https://$host$request_uri;
}

server {
    # Rendered per nginx version: `http2 on;` (>= 1.25.1) or `listen ... http2`.
    {{LISTEN_443}}
    server_name {{DOMAIN}};

    ssl_certificate     {{SSL_CERT}};
    ssl_certificate_key {{SSL_KEY}};
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 10m;

    root  {{DOCROOT}};
    index index.php index.html;

    access_log {{ACCESS_LOG}};
    error_log  {{ERROR_LOG}};

    # Keep in sync with upload_max_filesize / post_max_size in php.ini.
    client_max_body_size {{CLIENT_MAX_BODY_SIZE}};

    # Security headers (HSTS is intentionally left out while the cert is self-signed).
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    # WordPress permalinks.
    location / {
        try_files $uri $uri/ /index.php?$args;
    }

    # PHP via the PHP-FPM unix socket.
    location ~ \.php$ {
        try_files $uri =404;
        include fastcgi_params;
        fastcgi_pass unix:{{PHP_FPM_SOCK}};
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_read_timeout 300;
        fastcgi_buffers 16 16k;
        fastcgi_buffer_size 32k;
    }

    # Never execute PHP living under uploads.
    location ~* /wp-content/uploads/.*\.php$ {
        deny all;
    }

    # Static assets.
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot|webp|avif)$ {
        expires max;
        log_not_found off;
        add_header Cache-Control "public, immutable";
    }

    # Dotfiles (.git, .env, .htaccess, ...).
    location ~ /\. {
        deny all;
        access_log off;
        log_not_found off;
    }

    # XML-RPC is a common brute-force target. Comment out if Jetpack/app needs it.
    location = /xmlrpc.php {
        deny all;
        access_log off;
        log_not_found off;
    }

    location = /wp-config.php {
        deny all;
    }

    # Readable metadata files that leak the installed version.
    location ~* ^/(readme|license|wp-config-sample)\.(html|txt|php)$ {
        deny all;
    }
}
