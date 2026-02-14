#!/bin/bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Agents Anywhere — Entrypoint
# ---------------------------------------------------------------------------
# Initialises persistent storage, SSH authentication, agent tokens, Railway
# skills, a welcome MOTD, and shell customisations, then starts sshd.
# ---------------------------------------------------------------------------

# --- Persistent storage setup ----------------------------------------------
# /data is a Railway volume that survives redeploys.
# We symlink config directories there so settings persist.

PERSIST_DIRS=(.claude .config .local .npm .cache)

# Take ownership of the volume mount first (Railway mounts as root)
sudo chown user:user /data

# Create persistent directories if they don't exist
for dir in "${PERSIST_DIRS[@]}"; do
    mkdir -p "/data/$dir"
done

# Symlink each into the home directory
for dir in "${PERSIST_DIRS[@]}"; do
    # Remove existing dir/file in home (from the image layer)
    rm -rf "$HOME/$dir"
    ln -sf "/data/$dir" "$HOME/$dir"
done

# --- Sync Railway skills ---------------------------------------------------
# Mirrors on each boot so skills always match the deployed image version.
# - Claude Code reads from ~/.claude/skills/
if [ -d /opt/default-skills ] && [ -n "$(ls -A /opt/default-skills 2>/dev/null)" ]; then
    skill_count=$(find /opt/default-skills -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
    rm -rf /data/.claude/skills
    mkdir -p /data/.claude/skills
    cp -r /opt/default-skills/* /data/.claude/skills/
    echo "Synced $skill_count Railway skills to ~/.claude/skills."
else
    echo "WARNING: No default skills found in /opt/default-skills. Agents will start without Railway skills."
fi

# --- SSH host key persistence ----------------------------------------------
# Without this, every redeploy generates new host keys and clients see
# "Host key verification failed".
HOST_KEY_DIR="/data/.ssh_host_keys"
if [ -d "$HOST_KEY_DIR" ] && [ -n "$(ls -A "$HOST_KEY_DIR" 2>/dev/null)" ]; then
    sudo cp "$HOST_KEY_DIR"/ssh_host_* /etc/ssh/
else
    sudo ssh-keygen -A
    mkdir -p "$HOST_KEY_DIR"
    sudo cp /etc/ssh/ssh_host_* "$HOST_KEY_DIR"/
    sudo chown -R user:user "$HOST_KEY_DIR"
fi

# --- SSH authentication ----------------------------------------------------
AUTH_CONFIGURED=false

# Write the public key from env var into authorized_keys
if [ -n "${SSH_PUBLIC_KEY:-}" ]; then
    echo "$SSH_PUBLIC_KEY" > ~/.ssh/authorized_keys
    chmod 600 ~/.ssh/authorized_keys
    # Validate the key format
    if ssh-keygen -l -f ~/.ssh/authorized_keys > /dev/null 2>&1; then
        echo "SSH public key configured."
        AUTH_CONFIGURED=true
    else
        echo "==========================================================="
        echo "ERROR: SSH_PUBLIC_KEY is not a valid OpenSSH public key."
        echo ""
        echo "  Expected format:"
        echo "    ssh-ed25519 AAAAC3NzaC1lZDI1NTE5... user@host"
        echo "    ssh-rsa AAAAB3NzaC1yc2EAAAA... user@host"
        echo ""
        echo "  You provided (first 40 chars):"
        echo "    ${SSH_PUBLIC_KEY:0:40}..."
        echo ""
        echo "  Common mistakes:"
        echo "    - Pasting the PRIVATE key instead of the public key"
        echo "    - Extra line breaks or whitespace when pasting"
        echo "    - Missing the key type prefix (ssh-ed25519 or ssh-rsa)"
        echo ""
        echo "  Fix: Go to Railway → your service → Variables tab"
        echo "       and update SSH_PUBLIC_KEY with the contents of:"
        echo "       ~/.ssh/id_ed25519.pub (on your local machine)"
        echo "==========================================================="
        rm -f ~/.ssh/authorized_keys
    fi
fi

# Set password for the user
if [ -n "${SSH_PASSWORD:-}" ]; then
    sudo chpasswd <<< "user:$SSH_PASSWORD"
    echo "SSH password configured."
    AUTH_CONFIGURED=true
fi

if [ "$AUTH_CONFIGURED" != "true" ]; then
    echo "==========================================================="
    echo "ERROR: No valid SSH authentication configured!"
    echo ""
    echo "  You must set at least one valid auth method in Railway Variables:"
    echo ""
    echo "  SSH_PUBLIC_KEY  — valid contents of ~/.ssh/id_ed25519.pub"
    echo "                    (run: cat ~/.ssh/id_ed25519.pub)"
    echo ""
    echo "  SSH_PASSWORD    — any strong password for SSH login"
    echo ""
    echo "  Go to: Railway Dashboard → your service → Variables tab"
    echo "  After setting a variable, Railway will redeploy automatically."
    echo "==========================================================="
    exit 1
fi

# Enable password auth in sshd config only if a password is set
if [ -n "${SSH_PASSWORD:-}" ]; then
    echo "PasswordAuthentication yes" | sudo tee /etc/ssh/sshd_config.d/99-password-auth.conf > /dev/null
else
    echo "PasswordAuthentication no" | sudo tee /etc/ssh/sshd_config.d/99-password-auth.conf > /dev/null
fi

# --- Persist environment variables for SSH sessions ------------------------
# SSH sessions don't inherit the container's env, so we write them to a
# separate file that .bashrc sources. We use > (overwrite) so tokens don't
# accumulate across container restarts.
ENV_SECRETS="$HOME/.env_secrets"
: > "$ENV_SECRETS"            # truncate / create
chmod 600 "$ENV_SECRETS"

ENV_VARS=(ANTHROPIC_API_KEY)
for var in "${ENV_VARS[@]}"; do
    val="${!var:-}"
    if [ -n "$val" ]; then
        # Escape single quotes to prevent shell injection
        escaped_val="${val//\'/\'\\\'\'}"
        echo "export $var='${escaped_val}'" >> "$ENV_SECRETS"
    fi
done

# Source the secrets file from .bashrc (idempotent — only adds once)
if ! grep -q 'source.*\.env_secrets' "$HOME/.bashrc" 2>/dev/null; then
    echo '[ -f "$HOME/.env_secrets" ] && source "$HOME/.env_secrets"' >> "$HOME/.bashrc"
fi

# --- Git credential helper via gh CLI --------------------------------------
# If the user has previously run `gh auth login`, configure git to use gh
# for GitHub credentials. Idempotent — safe to run on every boot.
if command -v gh &>/dev/null && gh auth status &>/dev/null 2>&1; then
    gh auth setup-git
fi

# --- MOTD / welcome message ------------------------------------------------
AGENT_LIST=""
command -v claude   >/dev/null 2>&1 && AGENT_LIST="${AGENT_LIST}  claude          — Claude Code (Anthropic)\n"

SKILLS_COUNT=0
if [ -d /opt/default-skills ]; then
    SKILLS_COUNT=$(find /opt/default-skills -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
fi

sudo tee /etc/motd > /dev/null <<EOF

  ┌─────────────────────────────────────────────┐
  │          Agents Anywhere on Railway          │
  └─────────────────────────────────────────────┘

  Available agents:
$(echo -e "$AGENT_LIST")
  First time? Log in to your services:
    gh auth login                 # GitHub (clone, push, PRs)
    railway login                 # Railway (manage services)

  Then clone a repo and start coding:
    cd /data && git clone <repo-url> && cd <repo>
    claude                        # start Claude Code

  Railway skills: $SKILLS_COUNT installed (agents use them automatically)

  Useful commands:
  agents-info                   # show this message again
  ll / la                       # list files (long / all)
  gs / gd                       # git status / git diff

  Storage: /data is persistent — clone repos there.

EOF

# --- Shell customisations (.bashrc_agents) ---------------------------------
BASHRC_AGENTS="$HOME/.bashrc_agents"
cat > "$BASHRC_AGENTS" <<'SHELL'
# Agents Anywhere — shell customisations

# Colored prompt: agents-anywhere:/path$
export PS1='\[\033[1;36m\]agents-anywhere\[\033[0m\]:\[\033[1;34m\]\w\[\033[0m\]\$ '

# Aliases
alias ll='ls -lhF --color=auto'
alias la='ls -lAhF --color=auto'
alias gs='git status'
alias gd='git diff'
alias cc='claude'
alias ghlogin='gh auth login && gh auth setup-git'

# Re-display the welcome MOTD
agents-info() {
    cat /etc/motd
}

SHELL

# Source .bashrc_agents from .bashrc (idempotent)
if ! grep -q 'bashrc_agents' "$HOME/.bashrc" 2>/dev/null; then
    echo '[ -f "$HOME/.bashrc_agents" ] && source "$HOME/.bashrc_agents"' >> "$HOME/.bashrc"
fi

# --- Harden SSH daemon -----------------------------------------------------
sudo tee /etc/ssh/sshd_config.d/00-hardening.conf > /dev/null <<'SSHD'
PermitRootLogin no
MaxAuthTries 3
ClientAliveInterval 60
ClientAliveCountMax 3
AllowUsers user
PrintMotd yes
SSHD

echo "Ready. SSH into this container on port 22."

# Run SSH server in foreground as PID 1.
exec sudo /usr/sbin/sshd -D -e
