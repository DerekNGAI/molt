#!/usr/bin/env bash
# Docker resources remain tagged and contained under the installation's VM root.
MOLT_RUNTIME_VERSION=opencode-1

dockerfile_for_project() {
  cat >"$1" <<'DOCKERFILE'
FROM ubuntu:22.04
RUN apt-get update && apt-get install -y --no-install-recommends curl git ca-certificates && rm -rf /var/lib/apt/lists/*
RUN git config --system --add safe.directory /workspace
ARG TARGETARCH
COPY tools.lock /tmp/tools.lock
RUN arch="${TARGETARCH:-$(uname -m)}"; case "$arch" in arm64|aarch64) asset=opencode-linux-arm64.tar.gz ;; amd64|x86_64) asset=opencode-linux-x64-baseline.tar.gz ;; *) printf "molt: unsupported container architecture: %s\n" "$arch" >&2; exit 1 ;; esac; curl -fL "https://github.com/anomalyco/opencode/releases/download/v1.18.33/$asset" -o /tmp/opencode.tar.gz && awk -v asset="$asset" '$2==asset {print $1 "  /tmp/opencode.tar.gz"}' /tmp/tools.lock | sha256sum -c - && mkdir -p /opt/opencode && tar -xzf /tmp/opencode.tar.gz -C /opt/opencode && rm /tmp/opencode.tar.gz /tmp/tools.lock
ENV PATH="/opt/opencode:${PATH}"
WORKDIR /workspace
CMD ["sh", "-c", "export OPENCODE_SERVER_PASSWORD=$(cat /molt-meta/opencode.password); exec opencode serve --hostname 0.0.0.0 --port 4096"]
DOCKERFILE
}

ensure_container() {
  local running version owner image_id expected_id
  running="$(remote_run "docker inspect -f '{{.State.Running}}' $(quote_remote "$PROJECT_CONTAINER") 2>/dev/null || true")"
  if [[ -n "$running" ]]; then
    owner="$(remote_run "docker inspect -f '{{index .Config.Labels \"io.molt.installation\"}}' $(quote_remote "$PROJECT_CONTAINER")")"
    [[ "$owner" == "$MOLT_INSTALL_ID" ]] || die 'container ownership mismatch'
    version="$(remote_run "docker inspect -f '{{index .Config.Labels \"io.molt.runtime\"}}' $(quote_remote "$PROJECT_CONTAINER")")"
    image_id="$(remote_run "docker inspect -f '{{.Image}}' $(quote_remote "$PROJECT_CONTAINER")")"
    expected_id="$(remote_run "docker image inspect -f '{{.Id}}' $(quote_remote "$PROJECT_IMAGE")")"
    if [[ "$version" == "$MOLT_RUNTIME_VERSION" && "$image_id" == "$expected_id" ]]; then
      [[ "$running" == true ]] || remote_run "docker start $(quote_remote "$PROJECT_CONTAINER") >/dev/null"
      return 0
    fi
    # Recreate only the container; retain workspace, credentials, and session history.
    cancel_project_forwards
    remote_run "docker rm -f $(quote_remote "$PROJECT_CONTAINER")"
  fi
  remote_run "docker run -d --init --restart unless-stopped --name $(quote_remote "$PROJECT_CONTAINER") \
    --label io.molt.installation=$MOLT_INSTALL_ID --label io.molt.project=$PROJECT_ID --label io.molt.runtime=$MOLT_RUNTIME_VERSION \
    --publish 127.0.0.1:$PROJECT_OPENCODE_PORT:4096 --workdir /workspace \
    --mount $(quote_remote "type=bind,src=$PROJECT_REMOTE_PATH,dst=/workspace") \
    --mount $(quote_remote "type=bind,src=$PROJECT_REMOTE_META,dst=/molt-meta,readonly") \
    --mount $(quote_remote "type=bind,src=$PROJECT_REMOTE_HOME/config,dst=/molt-config") \
    --mount $(quote_remote "type=bind,src=$PROJECT_REMOTE_HOME/cache/$PROJECT_ID,dst=/molt-cache") \
    --env HOME=/molt-cache/home --env XDG_CONFIG_HOME=/molt-config --env XDG_DATA_HOME=/molt-cache/data \
    --env XDG_CACHE_HOME=/molt-cache/cache --env XDG_STATE_HOME=/molt-cache/state --env TMPDIR=/molt-cache/tmp \
    --env OPENCODE_CONFIG_DIR=/molt-config/opencode --env OPENCODE_DISABLE_AUTOUPDATE=1 $(quote_remote "$PROJECT_IMAGE") >/dev/null"
}

ensure_project_container() {
  ssh_up
  if [[ "$PROJECT_ACTIVE" != 1 || "$PROJECT_RUNTIME_VERSION" != "$MOLT_RUNTIME_VERSION" ]]; then
    log "Starting ${PROJECT_NAME}…"
    cmd_start "@$PROJECT_ID"
    load_project "@$PROJECT_ID"
  else
    prepare_project_dirs
    start_sync
    sync_password
    ensure_container
    wait_opencode_ready
    forward_opencode_port
  fi
}
