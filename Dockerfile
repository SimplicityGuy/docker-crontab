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
        gettext \
        jq \
        su-exec \
        tini \
        wget \
        yq-go \
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

COPY entrypoint.sh /opt

ENTRYPOINT ["/sbin/tini", "--", "/opt/entrypoint.sh"]

HEALTHCHECK --interval=5s --timeout=3s \
    CMD ps aux | grep '[c]rond' || exit 1

# Run crond with custom crontabs directory owned by docker user
# -f: foreground mode
# -d 0: debug level 0 (most verbose)
# -c: crontabs directory
CMD ["crond", "-f", "-d", "0", "-c", "/opt/crontab/crontabs"]
