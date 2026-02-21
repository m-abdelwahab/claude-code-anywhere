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
# Copies default skills into the persistent volume on each boot.
# User-installed skills in ~/.claude/skills/ are preserved.
if [ -d /opt/default-skills ] && [ -n "$(ls -A /opt/default-skills 2>/dev/null)" ]; then
    skill_count=$(ls -1d /opt/default-skills/*/ 2>/dev/null | wc -l | tr -d ' ')
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

# Collect public keys from all SSH_PUBLIC_KEY* env vars into authorized_keys
: > ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys

key_count=0
key_vars_found=false
while IFS= read -r env_line; do
    var_name="${env_line%%=*}"
    var_value="${env_line#*=}"
    [ -z "$var_value" ] && continue
    key_vars_found=true
    while IFS= read -r key_line; do
        [ -z "$key_line" ] && continue
        if echo "$key_line" | ssh-keygen -l -f /dev/stdin > /dev/null 2>&1; then
            echo "$key_line" >> ~/.ssh/authorized_keys
            key_count=$((key_count + 1))
        else
            echo "WARNING: Invalid SSH key in $var_name (first 40 chars): ${key_line:0:40}..."
        fi
    done <<< "$(echo "$var_value" | tr ',' '\n' | sed '/^\s*$/d')"
done < <(env | grep '^SSH_PUBLIC_KEY' | sort)

if [ "$key_count" -gt 0 ]; then
    echo "SSH public key(s) configured: $key_count key(s)."
    AUTH_CONFIGURED=true
elif [ "$key_vars_found" = true ]; then
    echo "==========================================================="
    echo "ERROR: SSH_PUBLIC_KEY variable(s) found but no valid keys."
    echo ""
    echo "  Expected format:"
    echo "    ssh-ed25519 AAAAC3NzaC1lZDI1NTE5... user@host"
    echo "    ssh-rsa AAAAB3NzaC1yc2EAAAA... user@host"
    echo ""
    echo "  Common mistakes:"
    echo "    - Pasting the PRIVATE key instead of the public key"
    echo "    - Extra line breaks or whitespace when pasting"
    echo "    - Missing the key type prefix (ssh-ed25519 or ssh-rsa)"
    echo ""
    echo "  Fix: Go to Railway → your service → Variables tab"
    echo "       and update your SSH_PUBLIC_KEY* variable with the"
    echo "       contents of: ~/.ssh/id_ed25519.pub (on your machine)"
    echo "==========================================================="
    rm -f ~/.ssh/authorized_keys
fi

# Set password for the user
if [ -n "${SSH_PASSWORD:-}" ]; then
    sudo chpasswd <<< "user:$SSH_PASSWORD"
    echo "SSH password configured."
    AUTH_CONFIGURED=true
    if [ ${#SSH_PASSWORD} -lt 16 ]; then
        echo "==========================================================="
        echo "WARNING: SSH_PASSWORD is shorter than 16 characters."
        echo "  The SSH port is exposed to the internet via Railway's TCP"
        echo "  proxy. Use a strong password or switch to key-based auth."
        echo "==========================================================="
    fi
fi

if [ "$AUTH_CONFIGURED" != "true" ]; then
    echo "==========================================================="
    echo "ERROR: No valid SSH authentication configured!"
    echo ""
    echo "  You must set at least one valid auth method in Railway Variables:"
    echo ""
    echo "  SSH_PUBLIC_KEY  — your public key (~/.ssh/id_ed25519.pub)"
    echo "                    For teams: SSH_PUBLIC_KEY_ALICE, SSH_PUBLIC_KEY_BOB, etc."
    echo ""
    echo "  SSH_PASSWORD    — any strong password for SSH login"
    echo ""
    echo "  Go to: Railway Dashboard → your service → Variables tab"
    echo "  After setting a variable, Railway will redeploy automatically."
    echo "==========================================================="
    exit 1
fi

# Enable/disable password auth in sshd
if [ -n "${SSH_PASSWORD:-}" ]; then
    sudo tee /etc/ssh/sshd_config.d/99-password-auth.conf > /dev/null <<'SSHCFG'
PasswordAuthentication yes
KbdInteractiveAuthentication yes
SSHCFG
else
    sudo tee /etc/ssh/sshd_config.d/99-password-auth.conf > /dev/null <<'SSHCFG'
PasswordAuthentication no
KbdInteractiveAuthentication no
SSHCFG
fi

# --- Persist environment variables for SSH sessions ------------------------
# SSH sessions don't inherit the container's env, so we write them to a
# separate file that .bashrc sources. We use > (overwrite) so tokens don't
# accumulate across container restarts.
ENV_SECRETS="$HOME/.env_secrets"
: > "$ENV_SECRETS"            # truncate / create
chmod 600 "$ENV_SECRETS"

ENV_VARS=(ANTHROPIC_API_KEY OPENAI_API_KEY)
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
command -v codex    >/dev/null 2>&1 && AGENT_LIST="${AGENT_LIST}  codex           — Codex CLI (OpenAI)\n"

SKILLS_COUNT=0
if [ -d /opt/default-skills ]; then
    SKILLS_COUNT=$(find /opt/default-skills -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
fi

sudo tee /etc/motd > /dev/null <<EOF

  ┌─────────────────────────────────────────────┐
  │          Agents Anywhere on Railway         │
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

  tmux (sessions survive disconnects):
  Ctrl+B D                    # detach — session stays running
  Ctrl+B [                    # scroll mode (q to exit)
  Just close the terminal to disconnect without losing work.
  Don't type 'exit' — it kills the session and your processes.

  Useful commands:
  agents-info                   # show this message again
  ll / la                       # list files (long / all)
  gs / gd                       # git status / git diff

  Storage: /data is persistent — clone repos there.

EOF

# --- tmux configuration ----------------------------------------------------
cat > "$HOME/.tmux.conf" <<'TMUX'
set -g mouse on
TMUX

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
alias cx='codex'
alias ghlogin='gh auth login && gh auth setup-git'

# Re-display the welcome MOTD
agents-info() {
    cat /etc/motd
}

# Auto-attach to tmux on SSH login
if [ -n "$SSH_CONNECTION" ] && command -v tmux &>/dev/null && [ -z "$TMUX" ]; then
    tmux new -A -s main
fi

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

# --- fail2ban (password auth only) ----------------------------------------
if [ -n "${SSH_PASSWORD:-}" ]; then
    sudo tee /etc/fail2ban/jail.d/sshd.conf > /dev/null <<'F2B'
[sshd]
enabled = true
port = 22
maxretry = 5
bantime = 600
findtime = 600
F2B
    sudo fail2ban-server start || true
fi

echo "Ready. SSH into this container on port 22."

# Run SSH server in foreground as PID 1.
exec sudo /usr/sbin/sshd -D -e
