# Use an official PHP image with Apache
FROM php:8.2-apache 

# Install system dependencies
RUN apt-get update && apt-get install -y \
    sqlite3 \
    libsqlite3-dev \
    libzip-dev \
    zip \
    unzip \
    curl \
    jq \
    bc \
    git \
    iputils-ping \
    dnsutils \
    # Speedtest CLI (Ookla official - often preferred)
    # The script.deb.sh will try to install 'speedtest'
    && curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash \
    && apt-get install -y speedtest \
    && docker-php-ext-install pdo pdo_sqlite sqlite3 zip \
    && apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Enable Apache modules
RUN a2enmod rewrite headers ssl expires

# Set up web root and copy application files from 'app' subdirectory of build context
WORKDIR /app_build_temp 
# 'app/' is relative to the Dockerfile's location (the build context)
COPY ./app/ /app_build_temp/

RUN mkdir -p /var/www/html/sla_status && cp -R /app_build_temp/* /var/www/html/sla_status/ && \
    rm -rf /app_build_temp && \
    chown -R www-data:www-data /var/www/html/sla_status && \
    find /var/www/html/sla_status -type d -exec chmod 755 {} \; && \
    find /var/www/html/sla_status -type f -exec chmod 644 {} \;

# Configure Apache to serve from /var/www/html/sla_status 
RUN echo "<VirtualHost *:80>\n\
    ServerAdmin webmaster@localhost\n\
    DocumentRoot /var/www/html/sla_status\n\
    <Directory /var/www/html/sla_status>\n\
        Options Indexes FollowSymLinks\n\
        AllowOverride All\n\
        Require all granted\n\
    </Directory>\n\
    ErrorLog \${APACHE_LOG_DIR}/error.log\n\
    CustomLog \${APACHE_LOG_DIR}/access.log combined\n\
</VirtualHost>" > /etc/apache2/sites-available/000-default.conf

EXPOSE 80
EXPOSE 443

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s \
  CMD curl -f http://localhost/index.html || exit 1