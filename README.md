# Agents Anywhere

Run Claude Code in a persistent cloud container on Railway. SSH in from any device and start coding with AI. One-click deploy, persistent storage, and 13 pre-installed [Railway skills](https://docs.railway.com/ai/agent-skills).

- Runs 24/7. Reconnect from anywhere and pick up where you left off.
- Repos, settings, and session history are stored on a [volume](https://docs.railway.com/volumes) at `/data` and persist across redeploys.
- `tmux` is pre-installed. Run `tmux new -s main` to keep commands running if your connection drops, then `tmux a` to reattach.

---

## Quick Start

### 1. Deploy

You can deploy this project on Railway in a few clicks using a [Railway template](https://docs.railway.com/reference/templates). To get started, click the button below.

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/template/agents-anywhere)

When configuring the template, you'll find the following [environment variables](https://docs.railway.com/variables):

| Variable | Default | Description |
|---|---|---|
| `SSH_PASSWORD` | Auto-generated | Password for SSH access. Generated on deploy, but you can set your own. Note that the SSH port is exposed to the internet, so a weak password can be brute-forced, so use a strong password. Or use key-based auth instead. |
| `SSH_PUBLIC_KEY` | — | Your SSH public key. Optional, for key-based auth. |

---

### 2. Connect

Find your SSH connection details in the Railway dashboard under **Settings → Networking → [TCP Proxy](https://docs.railway.com/networking/tcp-proxy)**. You'll see a hostname and port like `roundhouse.proxy.rlwy.net:12345`.

> **Important:** Use the Railway-assigned port (e.g. `12345`), **not** port 22. Railway's [TCP proxy](https://docs.railway.com/networking/tcp-proxy) maps that external port to your container's internal port 22. Connecting on port 22 will reach the proxy itself and immediately close.

#### From your phone or tablet

Use any SSH app — [Termius](https://termius.com) (iOS, Android), [Echo](https://replay.software/echo) (iOS), or [Blink Shell](https://blink.sh) (iOS). Enter the hostname, Railway-assigned port, username `user`, and the `SSH_PASSWORD` from your service's **[Variables](https://docs.railway.com/variables)** tab.

#### From your laptop

```bash
ssh user@<hostname> -p <port>
```

Enter the `SSH_PASSWORD` when prompted. The hostname and port stay the same across redeploys.

<details>
<summary><strong>Using SSH key authentication</strong></summary>

To use key-based auth instead of a password, paste your public key into `SSH_PUBLIC_KEY`:

1. Run:
   ```bash
   cat ~/.ssh/id_ed25519.pub
   ```
2. If you get "No such file", generate a key first:
   ```bash
   ssh-keygen -t ed25519
   cat ~/.ssh/id_ed25519.pub
   ```
3. Copy the output (starts with `ssh-ed25519 ...`) and paste it into the `SSH_PUBLIC_KEY` field on Railway.

You can set both a password and a key. Useful if you want key auth from your computer and password auth from your phone.

</details>

---

### 3. Set Up

Once connected, log in to your services. Each is a one-time setup that persists across redeploys.

```bash
gh auth login         # GitHub — clone, push, create PRs
railway login         # Railway — manage services and deployments
```

Follow the device code prompts (you'll open a URL on any browser and enter a code). Claude Code will also prompt you to log in on first run.

---

### 4. Code

Clone a repo and start an agent:

```bash
cd /data
git clone https://github.com/youruser/yourrepo.git
cd yourrepo
claude
```

Start Claude Code with the `claude` command.

---

## Reset

To wipe persistent storage and start fresh:

1. Go to your service on Railway → **Settings → [Volume](https://docs.railway.com/volumes)**.
2. Click **Wipe Volume**.
3. Redeploy. The entrypoint reinitialises everything automatically.

<details>
<summary><strong>Selective reset</strong></summary>

SSH in and remove specific directories instead of wiping the full volume:

```bash
# Agent settings only (keeps repos)
rm -rf /data/.claude /data/.config

# SSH host keys (clients will need to accept the new key)
rm -rf /data/.ssh_host_keys

# Re-sync skills from the image without restarting
cp -r /opt/default-skills/* ~/.claude/skills/
```

</details>

---

## Security

- **SSH hardening** — root login disabled, max 3 auth attempts, only `user` can connect. Prefer SSH keys over passwords. The SSH port is exposed via Railway's [TCP proxy](https://docs.railway.com/networking/tcp-proxy).
- **Tokens on disk** — API keys are written to `~/.env_secrets` (mode 600) so SSH sessions can access them. The file is overwritten on each container start.
- **OAuth sessions** — `gh auth login` and `railway login` store sessions in `~/.config/` (persisted on the [volume](https://docs.railway.com/volumes)). Run `gh auth logout` or `railway logout` to revoke. Set spending caps on your Anthropic key.
- **Agent install scripts** — the Dockerfile installs Claude Code from npm at build time.

---

## Troubleshooting

<details>
<summary><strong>Authentication succeeds but connection closes immediately</strong></summary>

If your SSH client shows "Authentication succeeded" followed by "Connection closed with error: end of file", you're connecting on the **wrong port**.

Railway's [TCP proxy](https://docs.railway.com/networking/tcp-proxy) assigns a specific port (e.g. `25377`) that maps to your container's internal port 22. If you connect on port 22 instead, you'll reach the proxy's own SSH server — it authenticates you, but has nothing to forward to.

**Fix:** Use the port shown in **Settings → Networking → TCP Proxy** (e.g. `gondola.proxy.rlwy.net:25377`), not port 22.

</details>

<details>
<summary><strong>Connection refused</strong></summary>

- The container may still be starting. Wait 30–60 seconds after deploy and try again.
- Verify you're using the correct hostname and port from **Settings → Networking → [TCP Proxy](https://docs.railway.com/networking/tcp-proxy)** on Railway.

</details>

<details>
<summary><strong>Permission denied (publickey)</strong></summary>

- Make sure you set the **public** key (`~/.ssh/id_ed25519.pub`), not the private key, in the [`SSH_PUBLIC_KEY` variable](https://docs.railway.com/variables).
- Check that the key was pasted correctly with no extra whitespace or line breaks.
- Verify locally: `ssh-keygen -l -f ~/.ssh/id_ed25519.pub` should print the key fingerprint without errors.
- Try connecting with verbose output: `ssh -v user@<hostname> -p <port>` to see which keys are being tried.

</details>

<details>
<summary><strong>Permission denied (password)</strong></summary>

- Double-check the `SSH_PASSWORD` value in your Railway [environment variables](https://docs.railway.com/variables).
- Password auth is only enabled when `SSH_PASSWORD` is set. If you cleared it, redeploy.

</details>

<details>
<summary><strong>Host key verification failed</strong></summary>

This happens when the container got a new host key after redeployment. Remove the old key:

```bash
ssh-keygen -R "[<hostname>]:<port>"
```

Then connect again. Host keys are normally persisted across redeploys, so this should be rare.

</details>