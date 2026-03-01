#!/bin/bash
set -euo pipefail

# Pterodactyl Panel Web Only - Hardened Edition
# Created by ChikoDoe
# GitHub: https://github.com/ChikoDoe

cd /home/container

# ============================================
# BANNER
# ============================================
echo "=================================================="
echo "  Pterodactyl Panel Web Only - Hardened Edition"
echo "  Created by ChikoDoe"
echo "  GitHub: https://github.com/ChikoDoe"
echo "=================================================="

# ============================================
# HARDENING & SECURITY CHECKS
# ============================================
echo "[SEC] Starting hardened Pterodactyl Panel"

# Cek apakah running sebagai root (seharusnya tidak)
if [ "$(id -u)" = "0" ]; then
    echo "[SEC] WARNING: Running as root, but should be non-root. Fixing..."
    exec su container -c "$0"
    exit 0
fi

# Set timezone
if [ -n "${TZ}" ]; then
    echo "[i] Setting timezone to ${TZ}"
    ln -snf /usr/share/zoneinfo/${TZ} /etc/localtime
    echo ${TZ} > /etc/timezone
fi

# Cek read-only filesystem mode
if [ "${READ_ONLY_FS:-false}" = "true" ]; then
    echo "[SEC] Read-only FS mode: ensuring writable paths are mounted"
    # Pastikan direktori yang perlu write ada dan writable
    mkdir -p /tmp /run /home/container/storage/logs /home/container/storage/framework /home/container/bootstrap/cache
    chmod 1777 /tmp
    chmod 755 /run
fi

# ============================================
# PERSIAPAN ENVIRONMENT
# ============================================
echo "[i] Preparing environment"

# Buat direktori runtime
mkdir -p /run/nginx /run/php /tmp/nginx /tmp/php /home/container/storage/framework/{sessions,views,cache}
chmod 755 /run/nginx /run/php /tmp/nginx /tmp/php

# Set umask ketat
umask 027

# ============================================
# KONFIGURASI LARAVEL (.env)
# ============================================
echo "[i] Configuring Laravel environment"

# Backup .env dulu jika ada
if [ -f .env ]; then
    cp .env .env.backup
fi

# Update konfigurasi dengan sed (aman)
for pair in \
    "APP_URL=${APP_URL}" \
    "APP_ENV=${APP_ENV}" \
    "APP_DEBUG=${APP_DEBUG}" \
    "DB_HOST=${DB_HOST}" \
    "DB_PORT=${DB_PORT}" \
    "DB_DATABASE=${DB_DATABASE}" \
    "DB_USERNAME=${DB_USERNAME}" \
    "DB_PASSWORD=${DB_PASSWORD}"
do
    key="${pair%%=*}"
    value="${pair#*=}"
    if grep -q "^${key}=" .env 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${value}|" .env
    else
        echo "${key}=${value}" >> .env
    fi
done

# Generate APP_KEY jika belum ada
if ! grep -q "^APP_KEY=base64" .env 2>/dev/null; then
    echo "[i] Generating APP_KEY..."
    php artisan key:generate --force --no-interaction
fi

# Set permission ketat untuk .env
chmod 640 .env

# ============================================
# OPTIONAL MIGRATION
# ============================================
if [ "${AUTO_MIGRATE}" = "true" ]; then
    echo "[i] Running database migrations..."
    php artisan migrate --force --isolated
fi

# ============================================
# OPTIMASI LARAVEL (production)
# ============================================
echo "[i] Optimizing Laravel..."
php artisan config:cache
php artisan route:cache
php artisan view:cache
php artisan event:cache

# ============================================
# PERMISSIONS (strict)
# ============================================
echo "[SEC] Setting strict permissions..."
chown -R container:container storage bootstrap/cache
chmod -R 750 storage bootstrap/cache
chmod 770 storage/logs storage/framework
find storage -type f -exec chmod 640 {} \;
find bootstrap/cache -type f -exec chmod 640 {} \;

# ============================================
# NGINX CONFIG (HARDENED)
# ============================================
echo "[SEC] Generating hardened Nginx config..."

# Set port dari environment variable
WEB_PORT=${WEB_PORT:-8080}

cat >/etc/nginx/http.d/panel.conf <<EOF
server {
    listen ${WEB_PORT};
    server_name _;
    root /home/container/public;
    index index.php;
    
    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Permissions-Policy "geolocation=(), microphone=(), camera=()" always;
    
    # Hide Nginx version
    server_tokens off;
    
    # Rate limiting
    limit_req_zone \$binary_remote_addr zone=login:10m rate=5r/m;
    limit_req_zone \$binary_remote_addr zone=api:10m rate=30r/m;
    
    # Logging
    access_log /home/container/storage/logs/nginx-access.log;
    error_log /home/container/storage/logs/nginx-error.log warn;
    
    # Upload size
    client_max_body_size ${MAX_UPLOAD_SIZE:-100M};
    
    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
        
        # Prevent access to hidden files
        location ~ /\.(?!well-known) {
            deny all;
            return 404;
        }
    }
    
    # Block access to sensitive directories
    location ~ ^/(\.env|\.git|storage\/logs|storage\/framework|bootstrap\/cache) {
        deny all;
        return 404;
    }
    
    location ~ \.php$ {
        # Rate limiting untuk login dan API
        if (\$request_uri ~* "/auth/login") {
            set \$rate_limit_zone login;
        }
        if (\$request_uri ~* "^/api/") {
            set \$rate_limit_zone api;
        }
        limit_req zone=\$rate_limit_zone burst=5 nodelay;
        
        include fastcgi_params;
        fastcgi_pass unix:/run/php/php-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param PHP_VALUE "
            session.cookie_httponly=1
            session.cookie_secure=0
            session.use_strict_mode=1
            session.cookie_samesite=Lax
            max_execution_time=300
            max_input_time=300
            memory_limit=${PHP_MEMORY_LIMIT:-256M}
            post_max_size=${MAX_UPLOAD_SIZE:-100M}
            upload_max_filesize=${MAX_UPLOAD_SIZE:-100M}
        ";
        
        # Timeouts
        fastcgi_read_timeout 300;
        fastcgi_connect_timeout 60;
        fastcgi_send_timeout 300;
    }
    
    # Cache static assets
    location ~* \.(jpg|jpeg|png|gif|ico|css|js|woff2?)$ {
        expires 7d;
        add_header Cache-Control "public, immutable";
        access_log off;
    }
}
EOF

# ============================================
# PHP-FPM CONFIG (HARDENED)
# ============================================
echo "[SEC] Generating hardened PHP-FPM config..."
cat >/usr/local/etc/php-fpm.d/www.conf <<'EOF'
[www]
user = container
group = container
listen = /run/php/php-fpm.sock
listen.owner = container
listen.group = container
listen.mode = 0660

pm = dynamic
pm.max_children = 10
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 3
pm.max_requests = 500

; Security limits
request_terminate_timeout = 300s
request_slowlog_timeout = 30s
slowlog = /home/container/storage/logs/php-slow.log

; Environment hardening
catch_workers_output = no
clear_env = yes

; PHP values
php_admin_value[open_basedir] = /home/container:/tmp:/run
php_admin_value[disable_functions] = exec,passthru,shell_exec,system,proc_open,popen,curl_exec,curl_multi_exec,parse_ini_file,show_source
php_admin_value[expose_php] = Off
php_admin_value[upload_tmp_dir] = /tmp
php_admin_value[session.save_path] = /tmp
EOF

# ============================================
# NGINX MAIN CONFIG (hardening tambahan)
# ============================================
cat >/etc/nginx/nginx.conf <<'EOF'
user container container;
worker_processes auto;
pid /run/nginx/nginx.pid;
error_log /home/container/storage/logs/nginx-error.log warn;

events {
    worker_connections 1024;
    multi_accept on;
    use epoll;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    
    # Basic security
    server_tokens off;
    client_max_body_size 100M;
    client_body_buffer_size 128k;
    client_header_buffer_size 1k;
    large_client_header_buffers 4 8k;
    
    # Timeouts
    client_body_timeout 30;
    client_header_timeout 30;
    keepalive_timeout 30 30;
    send_timeout 30;
    
    # Limits
    limit_req_log_level warn;
    limit_conn_log_level warn;
    
    # Buffers
    output_buffers 2 32k;
    postpone_output 1460;
    
    # Compression
    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_types text/plain text/css text/xml text/javascript application/javascript application/xml+rss application/json;
    
    # Logging
    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for"';
    
    access_log /home/container/storage/logs/nginx-access.log main buffer=32k flush=5s;
    
    # Include panel config
    include /etc/nginx/http.d/*.conf;
}
EOF

# ============================================
# CLOUDFLARE TUNNEL (optional)
# ============================================
if [ "${CF_TUNNEL_ENABLED:-false}" = "true" ] && [ -n "${CF_TUNNEL_TOKEN:-}" ]; then
    echo "[i] Setting up Cloudflare Tunnel..."
    
    # Download cloudflared jika belum ada
    if [ ! -f cloudflared ]; then
        echo "[i] Downloading cloudflared..."
        curl -L --fail --progress-bar https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o cloudflared
        chmod 750 cloudflared
    fi
    
    # Verifikasi binary
    if file cloudflared | grep -q "ELF"; then
        echo "[i] Cloudflared binary verified"
        
        # Jalankan tunnel di background
        ./cloudflared tunnel --no-autoupdate run --token "${CF_TUNNEL_TOKEN}" > storage/logs/cloudflared.log 2>&1 &
        echo "[i] Cloudflare Tunnel started (PID: $!)"
        
        # Catat di log
        echo "$(date): Cloudflare Tunnel started with token: ${CF_TUNNEL_TOKEN:0:10}..." >> storage/logs/cloudflared.log
    else
        echo "[ERROR] Cloudflared binary corrupt"
    fi
fi

# ============================================
# VERIFIKASI FINAL
# ============================================
echo "[SEC] Final permission check..."
chmod -R 750 /home/container/storage/framework
chmod -R 750 /home/container/bootstrap/cache

# ============================================
# START SERVICES
# ============================================
echo "[i] Starting PHP-FPM..."
php-fpm -D -y /usr/local/etc/php-fpm.conf

echo "[i] Starting Nginx on port ${WEB_PORT}..."
exec nginx -g "daemon off;"
