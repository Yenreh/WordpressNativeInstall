# =============================================================================
# nginx site config for {{DOMAIN}} - rendered by bin/install-wordpress.
#
# Double-brace placeholders are replaced at render time. $host, $uri,
# $document_root and the other $-prefixed names are nginx variables: leave them alone.
# Regenerate with: bin/install-wordpress --config <site.env> (or bin/console nginx)
#
# LOCATION ORDER MATTERS. nginx tries regex locations in the order they appear
# and stops at the first match, so every `deny` on a .php path must sit ABOVE
# the generic `location ~ \.php$` block or it will never be reached.
# =============================================================================

# Brute-force budget for the login form. One zone per site: the rendered file is
# included at http level, and two sites sharing a zone name would fail nginx -t.
limit_req_zone $binary_remote_addr zone=wplogin-{{SITE_KEY}}:1m rate=30r/m;

server {
    listen 80;
    listen [::]:80;
    server_name {{DOMAIN}};

    # Everything is served over TLS, except the ACME challenge: certbot follows
    # redirects, but keeping the challenge on :80 avoids depending on that.
    location ^~ /.well-known/acme-challenge/ {
        root {{DOCROOT}};
    }

    location / {
        return 301 https://$host$request_uri;
    }
}

server {
    # Rendered per nginx version: `http2 on;` (>= 1.25.1) or `listen ... http2`.
    {{LISTEN_443}}
    server_name {{DOMAIN}};

    # Do not advertise the nginx version on error pages and in the Server header.
    server_tokens off;

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
    # nginx does not merge add_header across levels: any location that defines its
    # own add_header must repeat these three.
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    # WordPress permalinks.
    location / {
        try_files $uri $uri/ /index.php?$args;
    }

    # -------------------------------------------------------------------------
    # Denials. All of these MUST stay above `location ~ \.php$`.
    # -------------------------------------------------------------------------

    # Never execute PHP living under uploads: the whole point is to neutralize a
    # file that an upload bug managed to write there.
    location ~* ^/wp-content/uploads/.*\.php$ {
        deny all;
    }

    # Readable metadata files that leak the installed version.
    location ~* ^/(readme|license|wp-config-sample)\.(html|txt|php)$ {
        deny all;
    }

    # Dotfiles (.git, .env, .htaccess, ...), except the ACME challenge directory.
    location ~ /\.(?!well-known/) {
        deny all;
        access_log off;
        log_not_found off;
    }

    location = /wp-config.php {
        deny all;
    }

    # XML-RPC is a common brute-force target. Comment out if Jetpack/app needs it.
    location = /xmlrpc.php {
        deny all;
        access_log off;
        log_not_found off;
    }

    # -------------------------------------------------------------------------
    # PHP
    # -------------------------------------------------------------------------

    # The login form, rate limited. An exact-match location wins over every
    # regex, so the fastcgi block below has to be repeated here; keep the two
    # in sync.
    location = /wp-login.php {
        limit_req zone=wplogin-{{SITE_KEY}} burst=5 nodelay;
        limit_req_status 429;

        try_files $uri =404;
        include fastcgi_params;
        fastcgi_pass unix:{{PHP_FPM_SOCK}};
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_read_timeout 300;
        fastcgi_buffers 16 16k;
        fastcgi_buffer_size 32k;
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

    # Static assets. The add_header here replaces the server-level ones, so they
    # are repeated.
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot|webp|avif)$ {
        expires max;
        log_not_found off;
        add_header Cache-Control "public, immutable";
        add_header X-Content-Type-Options "nosniff" always;
        add_header X-Frame-Options "SAMEORIGIN" always;
        add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    }
}
