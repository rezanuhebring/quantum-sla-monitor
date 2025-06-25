# Use an official PHP image with Apache
FROM php:8.2-apache # Or your preferred PHP version

# Set DEBIAN_FRONTEND to noninteractive to avoid prompts during apt-get
ENV DEBIAN_FRONTEND=noninteractive

# Layer 1: Update and install basic utilities often needed for scripts
# These are generally good to have for troubleshooting within the container as well.
RUN apt-get update -yqq && \
    apt-get install -y --no-install-recommends \
        apt-utils \
        gnupg \
        ca-certificates \
        procps \
        nano \
        less \
    && apt-get clean && rm -rf /var/lib/apt/lists/*
RUN echo "----> Layer 1: Basic utils OK"

# Layer 2: Install SQLite and related dev packages (needed for pdo_sqlite, sqlite3 PHP extensions)
RUN apt-get update -yqq && \
    apt-get install -y --no-install-recommends \
        sqlite3 \
        libsqlite3-dev \
    && apt-get clean && rm -rf /var/lib/apt/lists/*
RUN echo "----> Layer 2: SQLite OK"

# Layer 3: Install Zip and related dev packages (needed for zip PHP extension)
RUN apt-get update -yqq && \
    apt-get install -y --no-install-recommends \
        libzip-dev \
        zip \
        unzip \
    && apt-get clean && rm -rf /var/lib/apt/lists/*
RUN echo "----> Layer 3: Zip utils OK"

# Layer 4: Install other CLI tools needed by monitor scripts or potentially by users
RUN apt-get update -yqq && \
    apt-get install -y --no-install-recommends \
        curl \
        jq \
        bc \
        git \
        iputils-ping \
        dnsutils \
    && apt-get clean && rm -rf /var/lib/apt/lists/*
RUN echo "----> Layer 4: Other CLI tools OK"

# Layer 5: Install Speedtest CLI (Ookla official)
RUN echo "----> Attempting to install Ookla Speedtest CLI..."
RUN apt-get update -yqq && \
    apt-get install -y --no-install-recommends curl ca-certificates gnupg # Ensure these are present for the script
RUN curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash || \
    (echo "ERROR: Ookla script.deb.sh failed." && exit 1)
RUN echo "----> Ookla repo script executed."
RUN apt-get update -yqq && \
    apt_output=$(apt-get install -y --no-install-recommends speedtest 2>&1) || \
    (echo "ERROR: Failed to install 'speedtest' package via apt. Output: $apt_output" && \
     echo "INFO: Speedtest might not be available from this repo for the base image's OS version." && exit 1)
RUN echo "----> Layer 5: Speedtest installation attempted."

# Layer 6: Install PHP extensions one by one for debugging
RUN echo "----> Attempting to install PHP extension: pdo..."
RUN docker-php-ext-install pdo || (echo "ERROR: Failed to install PHP extension pdo." && exit 1)
RUN echo "----> PHP pdo OK"

RUN echo "----> Attempting to install PHP extension: pdo_sqlite..."
RUN docker-php-ext-install pdo_sqlite || (echo "ERROR: Failed to install PHP extension pdo_sqlite." && exit 1)
RUN echo "----> PHP pdo_sqlite OK"

RUN echo "----> Attempting to install PHP extension: sqlite3..."
RUN docker-php-ext-install sqlite3 || (echo "ERROR: Failed to install PHP extension sqlite3." && exit 1)
RUN echo "----> PHP sqlite3 OK"
    
RUN echo "----> Attempting to install PHP extension: zip..."
# Some PHP versions/images might not need 'configure' for zip, or it might fail if libzip-dev isn't perfect.
# `|| true` allows the build to continue if configure fails but install might still work.
RUN docker-php-ext-configure zip --with-libzip || (echo "INFO: docker-php-ext-configure zip with explicit path failed or not needed, trying default..." && docker-php-ext-configure zip || true)
RUN docker-php-ext-install zip || (echo "ERROR: Failed to install PHP extension zip." && exit 1)
RUN echo "----> PHP zip OK"
    
RUN echo "----> Layer 6: All specified PHP extensions attempted."
RUN apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* # Final cleanup for this block

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

# The default CMD for php:apache image is to start apache in foreground