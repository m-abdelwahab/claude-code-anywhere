FROM ubuntu:24.04

LABEL org.opencontainers.image.title="Agents Anywhere" \
      org.opencontainers.image.description="Persistent SSH container with Claude Code on Railway"

ENV DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Base system packages + external repos (NodeSource, GitHub CLI)
RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl wget vim jq tmux zip unzip \
    ripgrep tree less sudo \
    ca-certificates gnupg python3 python3-pip \
    openssh-server \
    && curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
       | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
       | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
    && apt-get update && apt-get install -y --no-install-recommends nodejs gh \
    && rm -rf /var/lib/apt/lists/*

# Global CLI tools (available to all users via system PATH)
RUN npm install -g @anthropic-ai/claude-code \
    && arch="$(dpkg --print-architecture)" \
    && if [ "$arch" = "amd64" ]; then \
         npm install -g @railway/cli; \
       elif [ "$arch" = "arm64" ]; then \
         tag="$(curl -fsSL https://api.github.com/repos/railwayapp/cli/releases/latest | jq -r '.tag_name')" \
         && asset="railway-${tag}-aarch64-unknown-linux-musl.tar.gz" \
         && curl -fsSL -o /tmp/railway.tar.gz "https://github.com/railwayapp/cli/releases/download/${tag}/${asset}" \
         && tar -xzf /tmp/railway.tar.gz -C /tmp \
         && install -m 0755 /tmp/railway /usr/local/bin/railway \
         && rm -f /tmp/railway /tmp/railway.tar.gz; \
       else \
         echo "WARNING: Unsupported architecture for Railway CLI auto-install: $arch"; \
       fi

# Create non-root user with sudo access (Claude Code works better as non-root)
RUN useradd -m -s /bin/bash user \
    && printf '%s\n' "user ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/agents-anywhere \
    && chmod 0440 /etc/sudoers.d/agents-anywhere \
    && mkdir /run/sshd \
    && mkdir -p /opt/default-skills \
    && chown -R user:user /opt/default-skills

USER user
WORKDIR /home/user

# User-local tools (install scripts write to ~/.local/bin or ~/.bun/bin)
RUN curl -fsSL https://bun.sh/install | bash

# Ensure user-local bin dirs are in PATH for SSH sessions
ENV PATH="/home/user/.bun/bin:/home/user/.local/bin:${PATH}"

# Install agent skills from registry, then stage them to /opt so the
# entrypoint can copy them into the persistent volume on each boot.
RUN npx -y skills add railwayapp/railway-skills --all \
    && if [ -d .agents/skills ] && [ -n "$(ls -A .agents/skills 2>/dev/null)" ]; then \
         cp -r .agents/skills/* /opt/default-skills/; \
         echo "Staged $(ls -1d /opt/default-skills/*/ 2>/dev/null | wc -l) skills to /opt/default-skills"; \
       else \
         echo "WARNING: No skills found after install — agents will start without Railway skills"; \
       fi

RUN mkdir -p ~/.ssh && chmod 700 ~/.ssh

COPY --chown=user:user entrypoint.sh /home/user/entrypoint.sh
RUN chmod +x /home/user/entrypoint.sh

EXPOSE 22

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD pgrep -x sshd > /dev/null || exit 1

ENTRYPOINT ["/home/user/entrypoint.sh"]
