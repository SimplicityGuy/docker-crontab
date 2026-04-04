FROM alpine:3.23 AS builder

ARG BUILD_DATE=""

LABEL org.opencontainers.image.title="crontab builder" \
      org.opencontainers.image.description="crontab builder" \
      org.opencontainers.image.authors="robert@simplicityguy.com" \
      org.opencontainers.image.source="https://github.com/SimplicityGuy/docker-crontab/blob/main/Dockerfile" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.base.name="docker.io/library/alpine"

# Platform arguments provided by Docker Buildx
ARG TARGETPLATFORM
ARG TARGETOS
ARG TARGETARCH
ARG TARGETVARIANT

ENV RQ_VERSION=1.0.2
WORKDIR /usr/bin/rq/

SHELL ["/bin/ash", "-o", "pipefail", "-c"]

#hadolint ignore=DL3018
RUN apk update --quiet && \
    apk upgrade --quiet && \
    apk add --quiet --no-cache \
        upx && \
    rm /var/cache/apk/* && \
    # Map Docker platform to rq release platform
    case "${TARGETPLATFORM}" in \
        "linux/amd64") \
            RQ_PLATFORM="x86_64-unknown-linux-musl" && \
            RQ_SHA256="7b35f0b7399b874bbffcdcbb2a374843138318c806019d1a0bae7be2d23d31a4" \
            ;; \
        "linux/arm64") \
            RQ_PLATFORM="aarch64-unknown-linux-gnu" && \
            RQ_SHA256="d56aeea8ac5dae436279696799b18ddfae5d6c51ac21e40e20c8ca9f4abd8b4f" \
            ;; \
        "linux/arm/v7") \
            RQ_PLATFORM="armv7-unknown-linux-gnueabihf" && \
            RQ_SHA256="de59ee0b2c514fd902fa29ff8d5297bdc731a986ef09e2d3cfd095ce548e67c0" \
            ;; \
        "linux/arm/v6") \
            RQ_PLATFORM="arm-unknown-linux-gnueabi" && \
            RQ_SHA256="e7aa94606be95d6b04bf822343778e2deb6952addd99b5585e689add7f2e21bf" \
            ;; \
        *) \
            echo "Warning: Unknown platform ${TARGETPLATFORM}, defaulting to x86_64-unknown-linux-musl" && \
            RQ_PLATFORM="x86_64-unknown-linux-musl" && \
            RQ_SHA256="7b35f0b7399b874bbffcdcbb2a374843138318c806019d1a0bae7be2d23d31a4" \
            ;; \
    esac && \
    wget --quiet "https://github.com/dflemstr/rq/releases/download/v${RQ_VERSION}/rq-v${RQ_VERSION}-${RQ_PLATFORM}.tar.gz" && \
    echo "${RQ_SHA256}  rq-v${RQ_VERSION}-${RQ_PLATFORM}.tar.gz" | sha256sum -c - && \
    tar -xvf "rq-v${RQ_VERSION}-${RQ_PLATFORM}.tar.gz" && \
    upx --brute rq

FROM docker:29.3.1-dind-alpine3.23 AS release

ARG BUILD_DATE=""

LABEL org.opencontainers.image.title="crontab" \
      org.opencontainers.image.description="A docker job scheduler (aka crontab for docker)." \
      org.opencontainers.image.authors="robert@simplicityguy.com" \
      org.opencontainers.image.source="https://github.com/SimplicityGuy/docker-crontab/blob/main/Dockerfile" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.created="${BUILD_DATE}" \
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
        gcompat \
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
    # Validate DOCKER_GID is a number
    case "${DOCKER_GID}" in \
        ''|*[!0-9]*) echo "DOCKER_GID must be a number, got: '${DOCKER_GID}'"; exit 1 ;; \
    esac && \
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
# -d 0: debug level 0 (most verbose)
# -c: crontabs directory
CMD ["crond", "-f", "-d", "0", "-c", "/opt/crontab/crontabs"]
