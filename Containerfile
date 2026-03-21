FROM registry.fedoraproject.org/fedora:latest

ARG USERNAME
ARG USER_UID
ARG USER_GID
ARG USER_SHELL=/usr/bin/fish

# Create user matching the host user
RUN groupadd -g ${USER_GID} ${USERNAME} && \
    useradd -m -u ${USER_UID} -g ${USER_GID} -s ${USER_SHELL} ${USERNAME}

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

# Entrypoint wrapper: runs Claude, then optionally notifies via ntfy
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

USER ${USERNAME}
WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
