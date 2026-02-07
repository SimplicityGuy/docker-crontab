#hadolint ignore=DL3007
FROM alpine:3.23 AS builder

LABEL org.opencontainers.image.title="crontab builder" \
      org.opencontainers.image.description="crontab builder" \
      org.opencontainers.image.authors="robert@simplicityguy.com" \
      org.opencontainers.image.source="https://github.com/SimplicityGuy/docker-crontab/blob/main/Dockerfile" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.created="$(date +'%Y-%m-%d')" \
      org.opencontainers.image.base.name="docker.io/library/alpine"

# Platform arguments provided by Docker Buildx
ARG TARGETPLATFORM
ARG TARGETOS
ARG TARGETARCH
ARG TARGETVARIANT

ENV RQ_VERSION=1.0.2
WORKDIR /usr/bin/rq/

#hadolint ignore=DL3018,SC2086
RUN apk update --quiet && \
    apk upgrade --quiet && \
    apk add --quiet --no-cache \
        upx && \
    rm /var/cache/apk/* && \
    # Map Docker platform to rq release platform
    case "${TARGETPLATFORM}" in \
        "linux/amd64") \
            RQ_PLATFORM="x86_64-unknown-linux-musl" \
            ;; \
        "linux/arm64") \
            RQ_PLATFORM="aarch64-unknown-linux-gnu" \
            ;; \
        "linux/arm/v7") \
            RQ_PLATFORM="armv7-unknown-linux-gnueabihf" \
            ;; \
        "linux/arm/v6") \
            RQ_PLATFORM="arm-unknown-linux-gnueabi" \
            ;; \
        *) \
            echo "Warning: Unknown platform ${TARGETPLATFORM}, defaulting to x86_64-unknown-linux-musl" && \
            RQ_PLATFORM="x86_64-unknown-linux-musl" \
            ;; \
    esac && \
    wget --quiet https://github.com/dflemstr/rq/releases/download/v${RQ_VERSION}/rq-v${RQ_VERSION}-${RQ_PLATFORM}.tar.gz && \
    tar -xvf rq-v${RQ_VERSION}-${RQ_PLATFORM}.tar.gz && \
    upx --brute rq

#hadolint ignore=DL3007
FROM docker:29.2.1-dind-alpine3.23 AS release

LABEL org.opencontainers.image.title="crontab" \
      org.opencontainers.image.description="A docker job scheduler (aka crontab for docker)." \
      org.opencontainers.image.authors="robert@simplicityguy.com" \
      org.opencontainers.image.source="https://github.com/SimplicityGuy/docker-crontab/blob/main/Dockerfile" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.created="$(date +'%Y-%m-%d')" \
      org.opencontainers.image.base.name="docker.io/library/docker"

# Build argument for docker group ID, default to 999 which is common
ARG DOCKER_GID=999

ENV HOME_DIR=/opt/crontab

# Set shell with pipefail option to ensure pipe failures are caught
SHELL ["/bin/ash", "-o", "pipefail", "-c"]

#hadolint ignore=DL3018
RUN apk update --quiet && \
    apk upgrade --quiet && \
    apk add --quiet --no-cache \
        bash \
        coreutils \
        curl \
        gettext \
        jq \
        su-exec \
        tini \
        wget \
        shadow && \
    rm /var/cache/apk/* && \
    rm -rf /etc/periodic /etc/crontabs/root && \
    # Set SUID on crontab command so it can modify crontab files
    chmod u+s /usr/bin/crontab && \
    # Remove docker group if it exists
    getent group docker > /dev/null && delgroup docker || true && \
    # Check if GID is in use, if so use a different one
    (getent group | grep -q ":${DOCKER_GID}:" && addgroup docker || addgroup -g ${DOCKER_GID} docker) && \
    # Create docker user and add to docker group
    adduser -S docker -D -G docker && \
    mkdir -p ${HOME_DIR}/jobs ${HOME_DIR}/crontabs && \
    chown -R docker:docker ${HOME_DIR}

COPY --from=builder /usr/bin/rq/rq /usr/local/bin
COPY entrypoint.sh /opt

ENTRYPOINT ["/sbin/tini", "--", "/opt/entrypoint.sh"]

HEALTHCHECK --interval=5s --timeout=3s \
    CMD ps aux | grep '[c]rond' || exit 1

# Run crond with custom crontabs directory owned by docker user
# -f: foreground mode
# -d 7: debug level 7 (highest)
# -c: crontabs directory
CMD ["crond", "-f", "-d", "7", "-c", "/opt/crontab/crontabs"]
