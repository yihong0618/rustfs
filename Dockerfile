# Copyright 2024 RustFS Team
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Multi-stage Alpine build for minimal runtime image
FROM rust:1.85-alpine AS builder

# Build arguments for dynamic artifact download
ARG VERSION=""
ARG BUILD_TYPE="release"
ARG TARGETARCH

# Install build dependencies
RUN apk add --no-cache \
    musl-dev \
    pkgconfig \
    openssl-dev \
    openssl-libs-static \
    curl \
    unzip \
    bash \
    wget \
    ca-certificates

# Install protoc
RUN wget https://github.com/protocolbuffers/protobuf/releases/download/v31.1/protoc-31.1-linux-x86_64.zip \
    && unzip protoc-31.1-linux-x86_64.zip -d protoc3 \
    && mv protoc3/bin/* /usr/local/bin/ && chmod +x /usr/local/bin/protoc \
    && mv protoc3/include/* /usr/local/include/ && rm -rf protoc-31.1-linux-x86_64.zip protoc3

# Install flatc
RUN wget https://github.com/google/flatbuffers/releases/download/v25.2.10/Linux.flatc.binary.g++-13.zip \
    && unzip Linux.flatc.binary.g++-13.zip \
    && mv flatc /usr/local/bin/ && chmod +x /usr/local/bin/flatc \
    && rm -rf Linux.flatc.binary.g++-13.zip

# Download pre-built binary (VERSION is required)
RUN if [ -z "$VERSION" ]; then \
        echo "❌ ERROR: VERSION build argument is required"; \
        echo "Please provide VERSION (e.g., main-latest, latest, v1.0.0, dev-abc123)"; \
        exit 1; \
    fi; \
    \
    # Map TARGETARCH to our naming convention
    case "${TARGETARCH}" in \
        amd64) ARCH="x86_64" ;; \
        arm64) ARCH="aarch64" ;; \
        *) echo "❌ Unsupported architecture: ${TARGETARCH}" && exit 1 ;; \
    esac; \
    \
    # Handle VERSION with different patterns
    if [[ "$VERSION" == "main-latest" ]]; then \
        DOWNLOAD_PATH="artifacts/rustfs/dev"; \
        FILENAME="rustfs-linux-${ARCH}-main-latest.zip"; \
    elif [[ "$VERSION" == "latest" ]]; then \
        DOWNLOAD_PATH="artifacts/rustfs/release"; \
        FILENAME="rustfs-linux-${ARCH}-latest.zip"; \
    elif [[ "$VERSION" == dev-* ]]; then \
        DOWNLOAD_PATH="artifacts/rustfs/dev"; \
        FILENAME="rustfs-linux-${ARCH}-dev-${VERSION#dev-}.zip"; \
    else \
        DOWNLOAD_PATH="artifacts/rustfs/release"; \
        FILENAME="rustfs-linux-${ARCH}-v${VERSION}.zip"; \
    fi; \
    \
    # Download the binary
    DOWNLOAD_URL="https://dl.rustfs.com/${DOWNLOAD_PATH}/${FILENAME}"; \
    echo "🔽 Downloading RustFS binary from: ${DOWNLOAD_URL}"; \
    \
    # Download with clear error handling
    if ! curl -fsSL --connect-timeout 30 --max-time 120 -o /tmp/rustfs.zip "${DOWNLOAD_URL}"; then \
        echo "❌ Failed to download binary from: ${DOWNLOAD_URL}"; \
        echo "💡 Please ensure the binary exists or trigger a build first"; \
        echo "💡 Available options:"; \
        echo "   - For main-latest: Push to main branch or run build workflow"; \
        echo "   - For latest: Create a release tag"; \
        echo "   - For dev-xxx: Run build workflow with specific commit"; \
        exit 1; \
    fi; \
    \
    # Extract binary
    if ! unzip -o /tmp/rustfs.zip -d /tmp >/dev/null 2>&1; then \
        echo "❌ Failed to extract downloaded binary"; \
        exit 1; \
    fi; \
    \
    # Install binary
    mv /tmp/rustfs /usr/local/bin/rustfs; \
    chmod +x /usr/local/bin/rustfs; \
    rm -rf /tmp/*; \
    \
    echo "✅ Successfully downloaded and installed RustFS binary (${VERSION})"

# Final Alpine runtime image
FROM alpine:3.18

RUN apk add --no-cache \
    ca-certificates \
    tzdata \
    bash

# Create rustfs user for security
RUN addgroup -g 1000 rustfs && \
    adduser -D -u 1000 -G rustfs rustfs

WORKDIR /app

# Copy binary from builder
COPY --from=builder /usr/local/bin/rustfs /app/rustfs
RUN chmod +x /app/rustfs && chown rustfs:rustfs /app/rustfs

# Create data directories
RUN mkdir -p /data && chown -R rustfs:rustfs /data /app

# Switch to non-root user
USER rustfs

# Environment variables
ENV RUSTFS_ACCESS_KEY=rustfsadmin \
    RUSTFS_SECRET_KEY=rustfsadmin \
    RUSTFS_ADDRESS=":9000" \
    RUSTFS_CONSOLE_ENABLE=true \
    RUSTFS_VOLUMES=/data \
    RUST_LOG=warn

EXPOSE 9000

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD wget --no-verbose --tries=1 --spider http://localhost:9000/health || exit 1

CMD ["/app/rustfs"]
