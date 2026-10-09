#!/usr/bin/env bash
# Docker resources remain tagged and contained under the installation's VM root.
MOLT_RUNTIME_VERSION=opencode-4

dockerfile_for_project() {
  cat >"$1" <<'DOCKERFILE'
FROM ubuntu:22.04
RUN apt-get update && apt-get install -y --no-install-recommends curl git ca-certificates libstdc++6 && rm -rf /var/lib/apt/lists/*
RUN git config --system --add safe.directory /workspace
ARG TARGETARCH
COPY tools.lock /tmp/tools.lock
RUN arch="${TARGETARCH:-$(uname -m)}"; case "$arch" in arm64|aarch64) asset=opencode-linux-arm64.tar.gz ;; amd64|x86_64) asset=opencode-linux-x64-baseline.tar.gz ;; *) printf "molt: unsupported container architecture: %s\n" "$arch" >&2; exit 1 ;; esac; curl -fL "https://github.com/anomalyco/opencode/releases/download/v1.18.34/$asset" -o /tmp/opencode.tar.gz && awk -v asset="$asset" '$2==asset {print $1 "  /tmp/opencode.tar.gz"}' /tmp/tools.lock | sha256sum -c - && mkdir -p /opt/opencode && tar -xzf /tmp/opencode.tar.gz -C /opt/opencode && rm /tmp/opencode.tar.gz
RUN node_arch="${TARGETARCH:-$(uname -m)}"; case "$node_arch" in arm64|aarch64) node_arch=arm64 ;; amd64|x86_64) node_arch=x64 ;; *) printf "molt: unsupported Node.js architecture: %s\n" "$node_arch" >&2; exit 1 ;; esac; asset="node-v24.21.0-linux-$node_arch.tar.gz"; curl -fL "https://nodejs.org/dist/v24.21.0/$asset" -o /tmp/node.tar.gz && awk -v asset="$asset" '$2==asset {print $1 "  /tmp/node.tar.gz"}' /tmp/tools.lock | sha256sum -c - && mkdir -p /opt/node && tar -xzf /tmp/node.tar.gz --strip-components=1 -C /opt/node && rm /tmp/node.tar.gz /tmp/tools.lock
ENV PATH="/opt/opencode:/opt/node/bin:${PATH}"
WORKDIR /workspace
CMD ["sh", "-c", "export OPENCODE_SERVER_PASSWORD=$(cat /molt-meta/opencode.password); exec opencode serve --hostname 0.0.0.0 --port 4096"]
DOCKERFILE
}

ensure_container() {
  local running version owner image_id expected_id config_version auth_version expected_auth_version
  expected_auth_version="$(remote_run "sha256sum $(quote_remote "$PROJECT_REMOTE_HOME/auth/auth.json") | cut -d ' ' -f1")"
  [[ "$expected_auth_version" =~ ^[a-f0-9]{64}$ ]] || die 'could not read VM provider credentials'
  running="$(remote_run "docker inspect -f '{{.State.Running}}' $(quote_remote "$PROJECT_CONTAINER") 2>/dev/null || true")"
  if [[ -n "$running" ]]; then
    owner="$(remote_run "docker inspect -f '{{index .Config.Labels \"io.molt.installation\"}}' $(quote_remote "$PROJECT_CONTAINER")")"
    [[ "$owner" == "$MOLT_INSTALL_ID" ]] || die 'container ownership mismatch'
    version="$(remote_run "docker inspect -f '{{index .Config.Labels \"io.molt.runtime\"}}' $(quote_remote "$PROJECT_CONTAINER")")"
    image_id="$(remote_run "docker inspect -f '{{.Image}}' $(quote_remote "$PROJECT_CONTAINER")")"
    expected_id="$(remote_run "docker image inspect -f '{{.Id}}' $(quote_remote "$PROJECT_IMAGE")")"
    config_version="$(remote_run "docker inspect -f '{{index .Config.Labels \"io.molt.config\"}}' $(quote_remote "$PROJECT_CONTAINER")")"
    auth_version="$(remote_run "docker inspect -f '{{index .Config.Labels \"io.molt.auth\"}}' $(quote_remote "$PROJECT_CONTAINER")")"
    if [[ "$version" == "$MOLT_RUNTIME_VERSION" && "$image_id" == "$expected_id" && "$config_version" == "$OPENCODE_CONFIG_VERSION" && "$auth_version" == "$expected_auth_version" ]]; then
      [[ "$running" == true ]] || remote_run "docker start $(quote_remote "$PROJECT_CONTAINER") >/dev/null"
      return 0
    fi
    # Recreate only the container; retain workspace, credentials, and session history.
    cancel_project_forwards
    remote_run "docker rm -f $(quote_remote "$PROJECT_CONTAINER")"
  fi
  remote_run "docker run -d --init --restart unless-stopped --name $(quote_remote "$PROJECT_CONTAINER") \
    --label io.molt.installation=$MOLT_INSTALL_ID --label io.molt.project=$PROJECT_ID --label io.molt.runtime=$MOLT_RUNTIME_VERSION --label io.molt.config=$OPENCODE_CONFIG_VERSION --label io.molt.auth=$expected_auth_version \
    --publish 127.0.0.1:$PROJECT_OPENCODE_PORT:4096 --workdir /workspace \
    --mount $(quote_remote "type=bind,src=$PROJECT_REMOTE_PATH,dst=/workspace") \
    --mount $(quote_remote "type=bind,src=$PROJECT_REMOTE_META,dst=/molt-meta,readonly") \
    --mount $(quote_remote "type=bind,src=$PROJECT_REMOTE_HOME/config,dst=/molt-config") \
    --mount $(quote_remote "type=bind,src=$PROJECT_REMOTE_HOME/cache/$PROJECT_ID,dst=/molt-cache") \
    --mount $(quote_remote "type=bind,src=$PROJECT_REMOTE_HOME/auth/auth.json,dst=/molt-cache/data/opencode/auth.json") \
    --env HOME=/molt-cache/home --env XDG_CONFIG_HOME=/molt-config --env XDG_DATA_HOME=/molt-cache/data \
    --env XDG_CACHE_HOME=/molt-cache/cache --env XDG_STATE_HOME=/molt-cache/state --env TMPDIR=/molt-cache/tmp \
    --env OPENCODE_CONFIG_DIR=/molt-config/opencode --env OPENCODE_DISABLE_AUTOUPDATE=1 $(quote_remote "$PROJECT_IMAGE") >/dev/null"
}

ensure_project_container() {
  ssh_up || { log 'VM connection unavailable; use MOLT_LOCAL=1 opencode, molt reset --local-only, or molt menu uninstall for local recovery'; return 1; }
  if [[ "$PROJECT_ACTIVE" != 1 || "$PROJECT_RUNTIME_VERSION" != "$MOLT_RUNTIME_VERSION" ]]; then
    log "Starting ${PROJECT_NAME}…"
    cmd_start "@$PROJECT_ID"
    load_project "@$PROJECT_ID"
  else
    prepare_project_dirs
    start_sync
    sync_opencode_config
    sync_password
    ensure_container
    wait_opencode_ready
    forward_opencode_port
  fi
}
