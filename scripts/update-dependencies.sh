#!/usr/bin/env bash
#
# Dependency Update Script for docker-crontab
#
# This script updates various dependencies in the project:
# - Docker base images in Dockerfile
# - rq binary version
# - GitHub Actions versions
#
# Usage:
#   ./scripts/update-dependencies.sh [OPTIONS]
#
# Options:
#   --no-backup     Skip creating backup files
#   --dry-run       Show what would be updated without making changes
#   --help          Show this help message
#

set -euo pipefail

# Script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Configuration
BACKUP_SUFFIX=".backup-$(date +%Y%m%d-%H%M%S)"
DRY_RUN=false
NO_BACKUP=false

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() { echo -e "${BLUE}ℹ${NC} $*"; }
log_success() { echo -e "${GREEN}✓${NC} $*"; }
log_warning() { echo -e "${YELLOW}⚠${NC} $*"; }
log_error() { echo -e "${RED}✗${NC} $*" >&2; }

# Help message
show_help() {
    cat << 'EOF'
Dependency Update Script for docker-crontab

This script updates various dependencies in the project:
- Docker base images in Dockerfile
- rq binary version
- GitHub Actions versions

Usage:
  ./scripts/update-dependencies.sh [OPTIONS]

Options:
  --no-backup     Skip creating backup files
  --dry-run       Show what would be updated without making changes
  --help          Show this help message

Examples:
  ./scripts/update-dependencies.sh --dry-run
  ./scripts/update-dependencies.sh --no-backup
EOF
    exit 0
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --no-backup)
            NO_BACKUP=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --help|-h)
            show_help
            ;;
        *)
            log_error "Unknown option: $1"
            show_help
            ;;
    esac
done

# Backup file function
backup_file() {
    local file="$1"
    if [[ "$NO_BACKUP" == "false" ]] && [[ "$DRY_RUN" == "false" ]]; then
        cp "$file" "${file}${BACKUP_SUFFIX}"
        log_info "Created backup: ${file}${BACKUP_SUFFIX}"
    fi
}

# Update file function
update_file() {
    local file="$1"
    local old_pattern="$2"
    local new_value="$3"
    local description="$4"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would update $description in $file"
        return 0
    fi

    if grep -q "$old_pattern" "$file"; then
        backup_file "$file"
        sed -i.tmp "s|$old_pattern|$new_value|g" "$file" && rm "${file}.tmp"
        log_success "Updated $description in $file"
        return 0
    else
        log_warning "Pattern not found for $description in $file"
        return 1
    fi
}

# Check for required tools
check_requirements() {
    local missing=()

    for cmd in curl jq sed grep; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing[*]}"
        log_error "Please install missing tools and try again"
        exit 1
    fi
}

# Get latest Docker image tag
get_latest_docker_tag() {
    local image="$1"
    local repo="${image%%:*}"

    # Query Docker Hub API for official images
    if [[ "$repo" == "alpine" ]]; then
        # For Alpine, get the latest stable version
        curl -s "https://hub.docker.com/v2/repositories/library/alpine/tags?page_size=100" | \
            jq -r '.results[].name' | \
            grep -E '^[0-9]+\.[0-9]+$' | \
            sort -V | \
            tail -1
    elif [[ "$repo" == "docker" ]]; then
        # For Docker dind, get the latest version matching pattern
        curl -s "https://hub.docker.com/v2/repositories/library/docker/tags?page_size=100" | \
            jq -r '.results[].name' | \
            grep -E '^[0-9]+\.[0-9]+\.[0-9]+-dind-alpine[0-9.]+$' | \
            sort -V | \
            tail -1
    else
        log_warning "Unknown image repository: $repo"
        return 1
    fi
}

# Get latest rq version from GitHub
get_latest_rq_version() {
    curl -s "https://api.github.com/repos/dflemstr/rq/releases/latest" | \
        jq -r '.tag_name' | \
        sed 's/^v//'
}

# Get latest GitHub Action version (major version only)
get_latest_action_version() {
    local repo="$1"

    # Get the latest tag and extract major version only (e.g., v6.0.1 -> v6)
    local latest_tag
    latest_tag=$(curl -s "https://api.github.com/repos/${repo}/releases/latest" | jq -r '.tag_name')

    # Extract major version (e.g., v6 from v6.0.1)
    echo "$latest_tag" | sed -E 's/^(v[0-9]+).*/\1/'
}

# Update summary tracking
declare -a UPDATE_SUMMARY=()

add_to_summary() {
    UPDATE_SUMMARY+=("$1")
}

# Main update functions

update_dockerfile() {
    log_info "Checking Dockerfile dependencies..."

    local dockerfile="$PROJECT_ROOT/Dockerfile"

    # Update Alpine base image
    local current_alpine
    current_alpine=$(grep 'FROM alpine:' "$dockerfile" | head -1 | sed -E 's/.*FROM alpine:([^ ]+).*/\1/')
    local latest_alpine
    latest_alpine=$(get_latest_docker_tag "alpine")

    if [[ "$current_alpine" != "$latest_alpine" ]]; then
        log_info "Alpine: $current_alpine → $latest_alpine"
        update_file "$dockerfile" "FROM alpine:${current_alpine}" "FROM alpine:${latest_alpine}" "Alpine base image"
        add_to_summary "• Alpine: $current_alpine → $latest_alpine"
    else
        log_success "Alpine is up to date: $current_alpine"
    fi

    # Update Docker dind image
    local current_docker
    current_docker=$(grep 'FROM docker:' "$dockerfile" | head -1 | sed -E 's/.*FROM docker:([^ ]+).*/\1/')
    local latest_docker
    latest_docker=$(get_latest_docker_tag "docker")

    if [[ "$current_docker" != "$latest_docker" ]]; then
        log_info "Docker: $current_docker → $latest_docker"
        update_file "$dockerfile" "FROM docker:${current_docker}" "FROM docker:${latest_docker}" "Docker dind image"
        add_to_summary "• Docker: $current_docker → $latest_docker"
    else
        log_success "Docker is up to date: $current_docker"
    fi

    # Update RQ version
    local current_rq
    current_rq=$(grep 'ENV RQ_VERSION=' "$dockerfile" | sed -E 's/.*ENV RQ_VERSION=([^ ]+).*/\1/')
    local latest_rq
    latest_rq=$(get_latest_rq_version)

    if [[ "$current_rq" != "$latest_rq" ]]; then
        log_info "rq: $current_rq → $latest_rq"
        update_file "$dockerfile" "ENV RQ_VERSION=${current_rq}" "ENV RQ_VERSION=${latest_rq}" "rq version"
        add_to_summary "• rq: $current_rq → $latest_rq"
    else
        log_success "rq is up to date: $current_rq"
    fi
}

update_github_actions() {
    log_info "Checking GitHub Actions dependencies..."

    local workflow_file="$PROJECT_ROOT/.github/workflows/build.yml"

    # Define actions to update as space-separated pairs: "repo:current_version"
    local actions=(
        "actions/checkout:v4"
        "docker/login-action:v3"
        "docker/metadata-action:v5"
        "docker/setup-qemu-action:v3"
        "docker/setup-buildx-action:v3"
        "docker/build-push-action:v6"
    )

    for action in "${actions[@]}"; do
        local repo="${action%%:*}"
        local current_version="${action##*:}"
        local latest_version
        latest_version=$(get_latest_action_version "$repo")

        if [[ -n "$latest_version" ]] && [[ "$current_version" != "$latest_version" ]]; then
            log_info "$repo: $current_version → $latest_version"
            update_file "$workflow_file" "uses: ${repo}@${current_version}" "uses: ${repo}@${latest_version}" "$repo action"
            add_to_summary "• $repo: $current_version → $latest_version"
        else
            log_success "$repo is up to date: $current_version"
        fi
    done
}

# Print update summary
print_summary() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Update Summary"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if [[ ${#UPDATE_SUMMARY[@]} -eq 0 ]]; then
        log_success "All dependencies are already up to date!"
    else
        echo ""
        echo "The following updates were made:"
        echo ""
        for update in "${UPDATE_SUMMARY[@]}"; do
            echo "$update"
        done
        echo ""

        if [[ "$DRY_RUN" == "false" ]]; then
            if [[ "$NO_BACKUP" == "false" ]]; then
                echo "Backup files created with suffix: $BACKUP_SUFFIX"
                echo ""
            fi

            log_info "Next Steps:"
            echo "  1. Review the changes with: git diff"
            echo "  2. Test the build: docker build -t crontab ."
            echo "  3. Commit changes: git commit -am 'chore: update dependencies'"
        fi
    fi

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# Main execution
main() {
    log_info "Starting dependency update process..."

    # Check requirements
    check_requirements

    # Change to project root
    cd "$PROJECT_ROOT"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_warning "Running in DRY RUN mode - no changes will be made"
    fi

    # Run updates
    update_dockerfile
    update_github_actions

    # Print summary
    print_summary

    if [[ ${#UPDATE_SUMMARY[@]} -gt 0 ]]; then
        exit 0
    else
        exit 0
    fi
}

# Run main function
main
