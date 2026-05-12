# Builder stage - build SQLite, Brotli, and Nginx (use system PCRE2)
FROM php:8.4-fpm AS builder

ENV DEBIAN_FRONTEND=noninteractive
ARG NGINX_VERSION=1.28.0
ARG BROTLI_VERSION=master
ARG SQLITE_VER_NUM=3500400
ARG SQLITE_VERSION=3.50.4

# Install build dependencies and helpers (include libpcre2-dev and pcre2-utils)
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      build-essential \
      ca-certificates \
      curl \
      git \
      cmake \
      pkg-config \
      libssl-dev \
      zlib1g-dev \
      libpcre2-dev \
      pcre2-utils \
      wget \
      xz-utils \
    && rm -rf /var/lib/apt/lists/*

# Build and install SQLite 3.50.4 into /usr/local
RUN set -eux; \
    SQLITE_TARBALL="sqlite-autoconf-${SQLITE_VER_NUM}.tar.gz"; \
    curl -fsSL "https://www.sqlite.org/2025/${SQLITE_TARBALL}" -o /tmp/${SQLITE_TARBALL}; \
    tar -xzf /tmp/${SQLITE_TARBALL} -C /tmp; \
    cd /tmp/sqlite-autoconf-${SQLITE_VER_NUM}; \
    ./configure --prefix=/usr/local --enable-fts5; \
    make -j"$(nproc)"; \
    make install; \
    # ensure /usr/local/lib exists for downstream COPY and leave small marker so it's never empty
    mkdir -p /usr/local/lib && echo "# keep" > /usr/local/lib/.keep-sqlite; \
    rm -f /tmp/${SQLITE_TARBALL} && rm -rf /tmp/sqlite-autoconf-${SQLITE_VER_NUM}

# Nginx source
RUN curl -fsSL "http://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz" | tar -zx -C /tmp

# ngx_brotli module
RUN git clone --depth=1 --branch=${BROTLI_VERSION} https://github.com/google/ngx_brotli.git /tmp/ngx_brotli && \
    cd /tmp/ngx_brotli && git submodule update --init

# Build the Brotli library statically
RUN set -eux; \
    cd /tmp/ngx_brotli/deps/brotli; \
    mkdir -p out && cd out; \
    cmake -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DCMAKE_C_FLAGS="-O2 -fPIC" -DCMAKE_INSTALL_PREFIX=./installed ..; \
    make -j"$(nproc)"; \
    make install

# Configure, build and install Nginx (use system PCRE2 instead of building it)
RUN set -eux; \
    cd /tmp/nginx-${NGINX_VERSION}; \
    ./configure \
        --prefix=/etc/nginx \
        --sbin-path=/usr/sbin/nginx \
        --modules-path=/usr/lib/nginx/modules \
        --conf-path=/etc/nginx/nginx.conf \
        --error-log-path=/var/log/nginx/error.log \
        --http-log-path=/var/log/nginx/access.log \
        --pid-path=/var/run/nginx.pid \
        --lock-path=/var/run/nginx.lock \
        --http-client-body-temp-path=/var/cache/nginx/client_temp \
        --http-proxy-temp-path=/var/cache/nginx/proxy_temp \
        --http-fastcgi-temp-path=/var/cache/nginx/fastcgi_temp \
        --http-uwsgi-temp-path=/var/cache/nginx/uwsgi_temp \
        --http-scgi-temp-path=/var/cache/nginx/scgi_temp \
        --user=nginx \
        --group=nginx \
        --with-http_ssl_module \
        --with-http_realip_module \
        --with-http_addition_module \
        --with-http_sub_module \
        --with-http_dav_module \
        --with-http_flv_module \
        --with-http_mp4_module \
        --with-http_gunzip_module \
        --with-http_gzip_static_module \
        --with-http_random_index_module \
        --with-http_secure_link_module \
        --with-http_stub_status_module \
        --with-http_auth_request_module \
        --with-threads \
        --with-stream \
        --with-stream_ssl_module \
        --with-stream_realip_module \
        --with-stream_ssl_preread_module \
        --with-http_v2_module \
        --with-cc-opt='-O2 -fstack-protector-strong -Wformat -Werror=format-security -Wp,-D_FORTIFY_SOURCE=2 -fPIC' \
        --with-ld-opt='-Wl,-z,relro -Wl,-z,now -Wl,--as-needed -pie' \
        --with-pcre-jit \
        --add-module=/tmp/ngx_brotli && \
    make -j"$(nproc)" && \
    make install && \
    mkdir -p /usr/lib/nginx/modules && \
    # strip to reduce size (optional)
    command -v strip >/dev/null 2>&1 && strip --strip-all /usr/sbin/nginx || true

# (Optional) keep a minimal manifest of built items for later copy
RUN ls -l /usr/sbin/nginx /etc/nginx || true

# Final runtime stage
FROM php:8.4-fpm

ENV DEBIAN_FRONTEND=noninteractive

# Install PHP extensions https://github.com/mlocati/docker-php-extension-installer
ADD --chmod=0755 https://github.com/mlocati/docker-php-extension-installer/releases/latest/download/install-php-extensions /usr/local/bin/
RUN install-php-extensions gd imagick intl exif zip bcmath @composer

# Install runtime deps required for healthcheck/nginx
RUN apt-get update && apt-get install -y --no-install-recommends \
    libfcgi-bin \
    procps \
    libpcre2-8-0 \
    supervisor \
    ca-certificates \
    && apt-get autoremove -y && apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# nginx artifacts (modules dir now exists even if empty)
COPY --from=builder /usr/sbin/nginx /usr/sbin/nginx
COPY --from=builder /etc/nginx /etc/nginx
COPY --from=builder /usr/lib/nginx/modules /usr/lib/nginx/modules

# sqlite runtime artifacts (copy entire /usr/local/lib and /usr/local/bin if present)
COPY --from=builder /usr/local/bin/sqlite3 /usr/local/bin/sqlite3
COPY --from=builder /usr/local/lib /usr/local/lib
COPY --from=builder /usr/local/include /usr/local/include

# Download and install php-fpm health check script
RUN curl -fsSL -o /usr/local/bin/php-fpm-healthcheck \
    https://raw.githubusercontent.com/renatomefi/php-fpm-healthcheck/master/php-fpm-healthcheck \
    && chmod +x /usr/local/bin/php-fpm-healthcheck

# Enable PHP-FPM status page, required for the health check script
RUN sed -i '/\[www\]/a pm.status_path = /status' /usr/local/etc/php-fpm.d/zz-docker.conf

# Use the recommended production PHP configuration
RUN mv "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini"

# Create a user with UID 1000
RUN adduser --disabled-password --gecos '' --uid 1000 paze

COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# Make sure files/folders needed by the processes are accessible when they run under paze
RUN mkdir -p /var/www/html /run /var/lib/nginx /var/log/nginx /var/cache/nginx/client_temp && \
    chown -R paze:paze /var/www/html /run /var/lib/nginx /var/log/nginx /var/cache/nginx

# Copy custom Nginx configuration from build context (overwrites builder /etc/nginx/nginx.conf if present)
COPY ./nginx.conf /etc/nginx/nginx.conf

# switch to paze so logs end up owned correctly
USER paze

# Let supervisord start nginx & php-fpm
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]