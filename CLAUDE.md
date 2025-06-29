# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is `docker-crontab`, a Docker-based cron job scheduler that allows running complex cron jobs in other containers. It's a lightweight alternative to mcuadros/ofelia with enterprise features.

## Key Architecture

### Core Components

- **Dockerfile**: Multi-stage build using Alpine Linux base with Docker-in-Docker capability

  - Builder stage: Downloads and compresses `rq` tool for config parsing
  - Release stage: Based on `docker:dind-alpine` with cron and Docker client
  - Uses `su-exec` for proper user privilege handling
  - Configurable Docker group ID via `DOCKER_GID` build arg (default: 999)

- **entrypoint.sh**: Main orchestration script that:

  - Normalizes config files (JSON/YAML/TOML) using `rq` and `jq`
  - Processes shared settings via `~~shared-settings` key
  - Generates crontab entries and executable scripts
  - Supports both `image` (docker run) and `container` (docker exec) execution modes
  - Handles trigger chains and onstart commands

### Configuration System

- Supports JSON, YAML, and TOML config formats
- Config can be array or mapping (top-level keys ignored for organization)
- Special `~~shared-settings` key for shared configuration
- Key fields: `schedule`, `command`, `image`/`container`, `dockerargs`, `trigger`, `onstart`
- Schedule supports standard crontab syntax plus shortcuts (@hourly, @daily, @every 2m, etc.)
- Additional fields: `comment`, `name`, `environment`, `expose`, `networks`, `ports`, `volumes`

### Job Execution Flow

1. Config normalization: All formats converted to working JSON
1. Script generation: Each job becomes executable shell script in `/opt/crontab/jobs/`
1. Crontab creation: Standard crontab file generated with proper scheduling
1. Trigger processing: Post-job triggers executed in sequence
1. Onstart handling: Jobs marked with `onstart: true` run immediately

## Development Commands

### Building

```bash
# Basic build
docker build -t crontab .

# Build with custom Docker group ID
docker build --build-arg DOCKER_GID=$(stat -c '%g' /var/run/docker.sock) -t crontab .
```

### Running

```bash
# Command line execution
docker run -d \
    -v /var/run/docker.sock:/var/run/docker.sock:ro \
    -v ./config-samples/config.sample.json:/opt/crontab/config.json:ro \
    -v ./logs:/var/log/crontab:rw \
    crontab

# With host directory for persistent config/logs
# Container will create directories with proper permissions
docker run -d \
    -v /var/run/docker.sock:/var/run/docker.sock:ro \
    -v $PWD/crontab-config:/opt/crontab:rw \
    -v $PWD/crontab-logs:/var/log/crontab:rw \
    crontab

# Docker Compose
docker-compose up
```

### Testing

```bash
# Test with sample configuration
docker run -d \
    -v /var/run/docker.sock:/var/run/docker.sock:ro \
    -v ./config-samples/config.sample.json:/opt/crontab/config.json:ro \
    crontab

# Debug mode - view generated crontab and scripts
docker run --rm \
    -v /var/run/docker.sock:/var/run/docker.sock:ro \
    -v ./config-samples/config.sample.json:/opt/crontab/config.json:ro \
    -e TEST_MODE=1 \
    crontab bash -c "cat /tmp/crontab-docker-testing/test && ls -la /tmp/crontab-docker-testing/jobs/"
```

The repository includes sample configurations in `config-samples/` for testing different scenarios.

## Important Configuration Notes

- **Docker Socket Access**: Container requires read-only access to `/var/run/docker.sock`
- **User Permissions**: Uses `docker` user with configurable GID to match host Docker group
- **Volume Mounts**: Config and log directories should be mounted as volumes
- **Network Access**: For docker-compose usage, containers need network connectivity via `--network` in `dockerargs`

## Troubleshooting

### Common Issues

- **"failed switching to 'docker': operation not permitted"**: Docker group GID mismatch

  - Solution: Rebuild with correct GID using `--build-arg DOCKER_GID=$(stat -c '%g' /var/run/docker.sock)`

- **"Permission denied" creating directories**: Volume mount permissions issue

  - Solution: Ensure host directories have correct ownership before mounting
  - Quick fix: `sudo chown -R $(id -u):$(getent group docker | cut -d: -f3) /path/to/host/directory`
  - Or let container create directories (it runs as root initially, then drops privileges)

- **Jobs not executing**: Check crontab generation and script permissions

  - Debug: Use `TEST_MODE=1` environment variable to inspect generated files

- **Container networking issues**: Ensure proper network configuration in `dockerargs`

  - For docker-compose: Add `--network <compose_network_name>` to dockerargs

### File Locations

- Generated scripts: `/opt/crontab/jobs/`
- Working config: `/opt/crontab/config.working.json`
- Crontab file: `/etc/crontabs/docker`
- Logs: Container stdout/stderr (configure external logging as needed)

## Security Considerations

- Container runs as non-root `docker` user for security
- Docker socket access is read-only to prevent container escape
- Uses `su-exec` for privilege dropping instead of `sudo`
- Multi-stage build minimizes attack surface
- SBOM and provenance generation enabled in CI/CD

## CI/CD

GitHub Actions workflow (`.github/workflows/build.yml`):

- Builds on push to main and PRs
- Multi-platform support (linux/amd64)
- Publishes to GitHub Container Registry (`ghcr.io`)
- Includes security scanning with SBOM and provenance
- Discord notifications for build status
- Weekly scheduled builds for base image security updates
