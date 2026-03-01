#!/bin/bash
cd /home/container

# Setup Nginx
cat > /etc/nginx/http.d/panel.conf << EOF
server {
    listen ${WEB_PORT:-8080};
    root /home/container/public;
    index index.php;
    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }
    location ~ \.php$ {
        fastcgi_pass unix:/run/php-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }
}
EOF

# Update .env
sed -i "s|DB_HOST=.*|DB_HOST=${DB_HOST}|" .env
sed -i "s|DB_PORT=.*|DB_PORT=${DB_PORT}|" .env

# Generate key
php artisan key:generate --force

# Start
php-fpm -D
nginx -g 'daemon off;'
