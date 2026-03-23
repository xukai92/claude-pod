FROM registry.fedoraproject.org/fedora:latest

ARG USERNAME
ARG USER_UID
ARG USER_GID
ARG USER_SHELL=bash
ARG HOME_DIR
ARG INSTALL_CLAUDE=0

# Runtime deps and tools (all three shells installed so any can be used)
RUN dnf install -y \
    git \
    bash \
    zsh \
    fish \
    gcc \
    gcc-c++ \
    make \
    python3 \
    ripgrep \
    fd-find \
    jq \
    curl \
    && dnf clean all

# Create user matching the host user (after shell packages are installed)
# Resolve shell name to its path inside the container (host path may differ)
RUN case "${USER_SHELL}" in bash|zsh|fish) ;; *) echo "error: invalid USER_SHELL '${USER_SHELL}'. Allowed: bash, zsh, fish" >&2; exit 1;; esac && \
    (getent group "${USER_GID}" >/dev/null 2>&1 || groupadd -g "${USER_GID}" "${USERNAME}") && \
    SHELL_PATH="$(command -v "${USER_SHELL}")" && \
    if [ -z "$SHELL_PATH" ]; then echo "error: shell '${USER_SHELL}' not found in image" >&2; exit 1; fi && \
    mkdir -p "$(dirname "${HOME_DIR}")" && \
    useradd -m -u "${USER_UID}" -g "${USER_GID}" -d "${HOME_DIR}" -s "$SHELL_PATH" "${USERNAME}"

ENV HOME=${HOME_DIR}

# Entrypoint wrapper: runs Claude, then optionally notifies via ntfy
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Install Claude Code to /usr/local/bin (needed on macOS where host binaries are Mach-O).
# Installed as root to a system path so the host's ~/.claude bind mount doesn't shadow it.
RUN if [ "${INSTALL_CLAUDE}" = "1" ]; then \
        GCS_BUCKET="https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases" && \
        ARCH="$(uname -m)" && case "$ARCH" in x86_64|amd64) ARCH="x64" ;; arm64|aarch64) ARCH="arm64" ;; esac && \
        PLATFORM="linux-${ARCH}" && \
        VERSION="$(curl -fsSL "$GCS_BUCKET/latest")" && \
        curl -fsSL -o /usr/local/bin/claude "$GCS_BUCKET/$VERSION/$PLATFORM/claude" && \
        chmod +x /usr/local/bin/claude; \
    fi

USER ${USERNAME}
WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
