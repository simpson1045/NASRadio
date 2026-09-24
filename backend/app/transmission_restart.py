"""
Auto-recover a flaky Transmission container.

Transmission (in a docker-compose stack on the Synology NAS) intermittently
shuts down. When the backend can't reach it, instead of just surfacing an error
to the app, we SSH into the NAS and bounce the stack the same way you would by
hand (`cd /docker/transmission && docker-compose down && docker-compose up -d`),
wait for the RPC port to answer again, and let the caller retry.

Guarded by a cooldown so a genuinely-dead container doesn't get hammered with
back-to-back restarts, and serialized by a lock so concurrent failing requests
trigger exactly one restart.
"""

import shlex
import threading
import time

import paramiko
import requests

from app.config import Config

# Serialize restarts and remember when we last did one (cooldown).
_restart_lock = threading.Lock()
_last_restart_ts = 0.0


def transmission_reachable(timeout=5):
    """True if Transmission's RPC endpoint answers at all (even with 401/409)."""
    cfg = Config()
    auth = None
    if cfg.TRANSMISSION_USER and cfg.TRANSMISSION_PASS:
        auth = (cfg.TRANSMISSION_USER, cfg.TRANSMISSION_PASS)
    try:
        resp = requests.get(
            f"{cfg.TRANSMISSION_URL.rstrip('/')}/transmission/rpc",
            auth=auth,
            timeout=timeout,
        )
        # 409 = needs session id (normal), 401 = auth, 200 = open: all "alive"
        return resp.status_code in (200, 401, 409)
    except Exception:
        return False


def _ssh_bounce_stack(cfg):
    """SSH to the NAS and restart the Transmission compose stack.

    Returns (ok, detail). Sources /etc/profile first so docker-compose is on
    PATH under the non-interactive SSH shell."""
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    try:
        client.connect(
            hostname=cfg.NAS_SSH_HOST,
            port=cfg.NAS_SSH_PORT,
            username=cfg.NAS_SSH_USER,
            password=cfg.NAS_SSH_PASSWORD,
            timeout=15,
            allow_agent=False,
            look_for_keys=False,
        )
        inner = (
            ". /etc/profile 2>/dev/null; "
            f"cd {cfg.TRANSMISSION_COMPOSE_DIR} && "
            "docker-compose down && docker-compose up -d"
        )
        if cfg.TRANSMISSION_RESTART_USE_SUDO:
            # -S reads the password from stdin; -p '' suppresses the prompt
            cmd = f"sudo -S -p '' sh -c {shlex.quote(inner)}"
        else:
            cmd = inner

        stdin, stdout, stderr = client.exec_command(cmd, timeout=120)
        if cfg.TRANSMISSION_RESTART_USE_SUDO:
            stdin.write(cfg.NAS_SSH_PASSWORD + "\n")
            stdin.flush()
        # Read to EOF (command completion) before grabbing the exit status,
        # so a chatty docker-compose can't deadlock on a full channel buffer.
        out = stdout.read().decode("utf-8", errors="replace").strip()
        err = stderr.read().decode("utf-8", errors="replace").strip()
        exit_status = stdout.channel.recv_exit_status()
        if exit_status == 0:
            return True, out or "compose restarted"
        return False, f"exit {exit_status}: {err or out or 'no output'}"
    finally:
        client.close()


def recover_transmission(wait_timeout=90, poll_interval=3):
    """
    Try to bring Transmission back. Returns True if it's reachable afterward.

    No-op (returns False) if auto-restart is disabled, no SSH password is
    configured, or we're still inside the cooldown window from a recent restart.
    """
    global _last_restart_ts
    cfg = Config()

    if not cfg.TRANSMISSION_AUTO_RESTART:
        return False
    if not cfg.NAS_SSH_PASSWORD:
        print("⚠️ Transmission unreachable but NAS_SSH_PASSWORD is not set — cannot auto-restart")
        return False

    with _restart_lock:
        # A concurrent request may have just restarted it — re-check first so
        # we don't bounce a container that's already coming back up.
        if time.time() - _last_restart_ts < cfg.TRANSMISSION_RESTART_COOLDOWN:
            if transmission_reachable():
                return True
            print("⏳ Transmission still down but within restart cooldown — not bouncing again yet")
            return False

        _last_restart_ts = time.time()
        print(f"🔁 Transmission unreachable — SSHing into {cfg.NAS_SSH_HOST} to bounce the stack...")
        try:
            ok, detail = _ssh_bounce_stack(cfg)
        except paramiko.AuthenticationException:
            print("❌ NAS SSH auth failed — check NAS_SSH_USER / NAS_SSH_PASSWORD")
            return False
        except Exception as e:
            print(f"❌ NAS SSH restart failed: {type(e).__name__}: {e}")
            return False

        if not ok:
            print(f"❌ docker-compose restart failed: {detail}")
            return False

        print(f"✅ Restart command sent ({detail}). Waiting for Transmission to come back...")

    # Poll outside the lock so other greenlets aren't blocked while we wait.
    deadline = time.time() + wait_timeout
    while time.time() < deadline:
        if transmission_reachable():
            print("✅ Transmission is reachable again")
            return True
        time.sleep(poll_interval)

    print(f"⚠️ Transmission still not reachable {wait_timeout}s after restart")
    return False
