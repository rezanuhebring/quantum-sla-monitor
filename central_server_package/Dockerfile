# Use an official PHP image with Apache
FROM php:8.2-apache

ENV DEBIAN_FRONTEND=noninteractive

# Layer 1: System update and core build dependencies
RUN apt-get update -yqq && \
    apt-get install -y --no-install-recommends \
        apt-utils \
        gnupg \
        ca-certificates \
        procps \
        nano \
        less \
        build-essential \
        autoconf \
        pkg-config \
    && apt-get clean && rm -rf /var/lib/apt/lists/*
RUN echo "----> Layer 1: Basic utils & build tools OK"

# Layer 2: Install SQLite and Libzip development libraries
RUN apt-get update -yqq && \
    apt-get install -y --no-install-recommends \
        sqlite3 \
        libsqlite3-dev \
        libzip-dev \
        zlib1g-dev \
    && apt-get clean && rm -rf /var/lib/apt/lists/*
RUN echo "----> Layer 2: SQLite & Libzip dev libs OK"

# Layer 3: Install other CLI tools
RUN apt-get update -yqq && \
    apt-get install -y --no-install-recommends \
        curl \
        jq \
        bc \
        git \
        iputils-ping \
        dnsutils \
    && apt-get clean && rm -rf /var/lib/apt/lists/*
RUN echo "----> Layer 3: Other CLI tools OK"

# Layer 4: Install Speedtest CLI (Ookla official)
RUN echo "----> Attempting to install Ookla Speedtest CLI..." && \
    apt-get update -yqq && apt-get install -y --no-install-recommends curl ca-certificates gnupg; \
    curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash || \
    (echo "ERROR: Ookla script.deb.sh failed." && exit 1); \
    echo "----> Ookla repo script executed."; \
    apt-get update -yqq && \
    apt_output=$(apt-get install -y --no-install-recommends speedtest 2>&1) || \
    (echo "ERROR: Failed to install 'speedtest' package via apt. Output: $apt_output" && exit 1); \
    echo "----> Layer 4: Speedtest installation attempted."

# Layer 5: Install PHP extensions one by one
# Extract PHP source first, which might be needed for some bundled extensions if config.m4 is missing
RUN docker-php-source extract
RUN echo "----> PHP source extracted."

RUN echo "----> Attempting to install PHP extension: pdo..."
RUN docker-php-ext-install pdo || (echo "ERROR: Failed to install PHP extension pdo." && exit 1)
RUN echo "----> PHP pdo OK"

RUN echo "----> Attempting to install PHP extension: pdo_sqlite..."
# pdo_sqlite depends on pdo and libsqlite3-dev
RUN docker-php-ext-install pdo_sqlite || (echo "ERROR: Failed to install PHP extension pdo_sqlite." && exit 1)
RUN echo "----> PHP pdo_sqlite OK"

RUN echo "----> Attempting to install PHP extension: sqlite3..."
# sqlite3 depends on libsqlite3-dev
RUN docker-php-ext-install sqlite3 || (echo "ERROR: Failed to install PHP extension sqlite3." && exit 1)
RUN echo "----> PHP sqlite3 OK"
    
RUN echo "----> Attempting to install PHP extension: zip..."
# zip depends on libzip-dev and zlib1g-dev
RUN docker-php-ext-configure zip --with-libzip || \
    (echo "INFO: docker-php-ext-configure zip --with-libzip failed or not needed, trying without --with-libzip..." && \
     docker-php-ext-configure zip || \
     (echo "INFO: docker-php-ext-configure zip also failed without --with-libzip, proceeding to install directly..." && true) \
    )
RUN docker-php-ext-install zip || (echo "ERROR: Failed to install PHP extension zip." && exit 1)
RUN echo "----> PHP zip OK"
    
RUN echo "----> Layer 5: All specified PHP extensions attempted."
# Delete PHP source after extensions are built to save space
RUN docker-php-source delete
RUN echo "----> PHP source deleted."

RUN apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* # Final cleanup for this block

# Enable Apache modules
RUN a2enmod rewrite headers ssl expires

# Set up web root and copy application files
WORKDIR /app_build_temp 
COPY ./app/ /app_build_temp/
RUN mkdir -p /var/www/html/sla_status && cp -R /app_build_temp/* /var/www/html/sla_status/ && \
    rm -rf /app_build_temp && \
    chown -R www-data:www-data /var/www/html/sla_status && \
    find /var/www/html/sla_status -type d -exec chmod 755 {} \; && \
    find /var/www/html/sla_status -type f -exec chmod 644 {} \;
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