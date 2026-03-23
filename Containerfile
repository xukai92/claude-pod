FROM registry.fedoraproject.org/fedora:latest

ARG USERNAME
ARG USER_UID
ARG USER_GID
ARG USER_SHELL=bash
ARG HOME_DIR

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
    groupadd -g "${USER_GID}" "${USERNAME}" && \
    SHELL_PATH="$(command -v "${USER_SHELL}")" && \
    if [ -z "$SHELL_PATH" ]; then echo "error: shell '${USER_SHELL}' not found in image" >&2; exit 1; fi && \
    mkdir -p "$(dirname "${HOME_DIR}")" && \
    useradd -m -u "${USER_UID}" -g "${USER_GID}" -d "${HOME_DIR}" -s "$SHELL_PATH" "${USERNAME}"

ENV HOME=${HOME_DIR}

# Entrypoint wrapper: runs Claude, then optionally notifies via ntfy
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

USER ${USERNAME}
WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
