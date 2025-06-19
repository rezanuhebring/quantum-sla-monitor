# Use an official PHP image with Apache
FROM php:8.2-apache # Or your preferred PHP version (e.g., 8.1, 8.3)

# Set environment variables for non-interactive frontend
ENV DEBIAN_FRONTEND=noninteractive

# Install system dependencies
# git for composer or some php extensions, iputils-ping & dnsutils if central server runs monitor_internet.sh
RUN apt-get update && apt-get install -y --no-install-recommends \
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
    # Speedtest CLI (Ookla official - needed if central server itself monitors its connection)
    # The script.deb.sh will try to install 'speedtest'
    && curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash \
    && apt-get install -y --no-install-recommends speedtest \
    && docker-php-ext-install pdo pdo_sqlite sqlite3 zip \
    && apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false \
    && apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Enable Apache modules
RUN a2enmod rewrite headers ssl expires

# Set up web root and copy application files
# Application will be served from /var/www/html/ (Apache's default)
# We will place our app files into a 'sla_status' subdirectory.
WORKDIR /var/www/html/sla_status

COPY ./index.html ./get_sla_stats.php ./
COPY ./api/ ./api/
# Note: sla_config.env and the SQLite DB will be mounted as volumes, not copied here.

# Set permissions for the web application directory AFTER copying files
# Apache runs as www-data (uid 33, gid 33 in standard php:apache images)
RUN chown -R www-data:www-data /var/www/html/sla_status && \
    find /var/www/html/sla_status -type d -exec chmod 755 {} \; && \
    find /var/www/html/sla_status -type f -exec chmod 644 {} \;

# Optional: If you need a custom Apache vhost configuration (e.g., to change DocumentRoot)
# COPY your-apache-vhost.conf /etc/apache2/sites-available/000-default.conf
# RUN a2ensite 000-default.conf # Ensure it's enabled

# Expose port 80 (Apache default) and 443 for SSL (if you add SSL later inside container)
EXPOSE 80
EXPOSE 443

# Healthcheck
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s \
  CMD curl -f http://localhost/sla_status/index.html || exit 1

# The default CMD for php:apache image is to start apache in foreground