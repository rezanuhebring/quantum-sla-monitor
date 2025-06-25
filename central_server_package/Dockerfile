# Use an official PHP image with Apache
FROM php:8.2-apache # Or your preferred PHP version

# Set DEBIAN_FRONTEND to noninteractive to avoid prompts during apt-get
ENV DEBIAN_FRONTEND=noninteractive

# Install system dependencies
# Break into logical groups for easier debugging
RUN apt-get update -yqq && \
    apt-get install -y --no-install-recommends \
        apt-utils \
        gnupg \
        ca-certificates \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN apt-get update -yqq && \
    apt-get install -y --no-install-recommends \
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
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Install Speedtest CLI (Ookla official)
# This part is often prone to issues if the repo structure changes or isn't available for the base image's Debian version
# Adding more error checking and logging here
RUN echo "Attempting to install Ookla Speedtest CLI..." && \
    curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash || \
    (echo "Ookla script.deb.sh failed, attempting fallback if any..." && exit 1)
RUN apt-get update -yqq && \
    apt-get install -y --no-install-recommends speedtest || \
    (echo "Failed to install 'speedtest' package via apt after adding repo. Speedtest might not be available." && \
     echo "Consider installing community 'speedtest-cli' as a fallback if Ookla's fails consistently.")
    # As a fallback for speedtest if Ookla fails:
    # RUN apt-get install -y speedtest-cli

# Install PHP extensions
RUN docker-php-ext-configure zip || true # some versions might not need configure
RUN docker-php-ext-install pdo pdo_sqlite sqlite3 zip \
    && apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Enable Apache modules
RUN a2enmod rewrite headers ssl expires

# Set up web root and copy application files from 'app' subdirectory of build context
WORKDIR /app_build_temp 
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

# Default command is to start apache in foreground (from base php:apache image)