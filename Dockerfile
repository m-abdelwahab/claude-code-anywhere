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
    openssh-server fail2ban \
    && curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
       | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
       | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
    && apt-get update && apt-get install -y --no-install-recommends nodejs gh \
    && rm -rf /var/lib/apt/lists/*

# Railway CLI
RUN curl -fsSL https://raw.githubusercontent.com/railwayapp/cli/master/install.sh | bash

# Create non-root user with sudo access (Claude Code works better as non-root)
RUN useradd -m -s /bin/bash user \
    && printf '%s\n' "user ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/agents-anywhere \
    && chmod 0440 /etc/sudoers.d/agents-anywhere \
    && mkdir /run/sshd \
    && mkdir -p /opt/default-skills /opt/claude-local/bin \
    && chown -R user:user /opt/default-skills /opt/claude-local

USER user
WORKDIR /home/user

# User-local tools — each is symlinked into /usr/local/bin so it's in the
# default system PATH for all contexts (SSH sessions, cron, scripts).
RUN curl -fsSL https://bun.sh/install | bash \
    && sudo ln -sf /home/user/.bun/bin/bun /usr/local/bin/bun \
    && sudo ln -sf /home/user/.bun/bin/bunx /usr/local/bin/bunx

# Claude Code — staged to /opt so it survives the entrypoint's
# ~/.local → /data/.local symlink swap, then linked into /usr/local/bin.
RUN curl -fsSL https://claude.ai/install.sh | bash \
    && cp /home/user/.local/bin/claude /opt/claude-local/bin/claude \
    && sudo ln -sf /opt/claude-local/bin/claude /usr/local/bin/claude

# OpenAI Codex CLI
RUN sudo npm install -g @openai/codex

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
