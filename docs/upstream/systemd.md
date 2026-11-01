# Optional systemd supervision

The [user service template](../systemd/dsv41-tensorfold.service) supervises the existing two-rank launcher on the head.
It runs as your user, with your existing Docker and SSH permissions. Nothing installs or enables it automatically;
the normal `./start.sh` workflow is unchanged. This addresses issue [#32](https://github.com/MiaAI-Lab/DeepSeek-v4.1-Flash-1017-2x-DGX-Sparks/issues/32), proposed by **m-naoki-m**.

The service sets `FOREGROUND=1` and `PREPARE=0`. A nonzero launcher exit, including a rank killed by memguard,
triggers another start after 60 seconds. At most three starts are allowed within systemd's 30-minute rate-limit interval, including
the first start; reaching that limit leaves the service failed until you intervene. A successful exit does not restart
it. The delay and limit contain retries; they do not make an oversized workload fit in memory.

## Prepare and configure

First prepare and test the recipe interactively on the head, using the same user and checkout you will run under
systemd. Put persistent settings in `scripts/local.sh` or the recipe's `.env`; systemd does not run your interactive
shell or source `~/.bashrc`. Check that Docker works and that the worker is reachable without a password, key
passphrase prompt or host-key confirmation. If SSH depends on a desktop agent, arrange its environment for your
user manager before relying on unattended restarts.

Copy the unit from the checkout:

```bash
mkdir -p ~/.config/systemd/user
cp systemd/dsv41-tensorfold.service ~/.config/systemd/user/
```

Edit the copied unit's `WorkingDirectory` to the **absolute path** of your checkout. For example:

```ini
WorkingDirectory="/home/alex/TF/DeepSeek-v4.1-Flash-1017-2x-DGX-Sparks-TensorFold"
```

Use a literal absolute path rather than `$HOME` or `~`. Escape any literal `%` in the path as `%%` for systemd.
The relative script arguments are resolved inside this working directory; no other path edits are needed.
Keep `PREPARE=0`: a supervised restart must not build images, download checkpoints or rewrite weight files.
Changed pins or missing prepared files may therefore fail startup; prepare them manually before starting the service.

Validate and load the copied unit:

```bash
systemd-analyze --user verify ~/.config/systemd/user/dsv41-tensorfold.service
systemctl --user daemon-reload
```

This user service does not manage the system Docker daemon or wait on a system network target. Docker and the link
must be ready before starting it; the launcher's existing checks still apply. There is no service on the worker:
the head starts and stops rank 1 over SSH.

## Hand over and start

Finish current requests, then stop a manually launched server before starting supervision:

```bash
./stop.sh
systemctl --user start dsv41-tensorfold.service
systemctl --user status dsv41-tensorfold.service
journalctl --user -u dsv41-tensorfold.service -f
```

Do not leave the same server running manually: `start.sh` exits successfully when both ranks are already running,
so the service would become inactive rather than adopt them. `Type=simple` reports the launcher as active before the
model has loaded; check your configured API's `/v1/models` and a completion for readiness. The existing foreground
mode follows the rank log and does not run the launcher's later smoke test.

Starting the unit does not enable it for future logins. If you want that, explicitly run:

```bash
systemctl --user enable dsv41-tensorfold.service
```

The user manager normally follows your login lifecycle. Running before login or after the last logout requires the
host's user-lingering policy to be configured separately; this recipe does not change it.

## Stop, recover and update

While supervised, use `systemctl --user stop dsv41-tensorfold.service` instead of `./stop.sh` or killing a container.
An explicit systemd stop runs `stop.sh` for both ranks and suppresses automatic restarts. It cuts off active requests,
as the manual stop does. To stop supervision and remove login activation:

```bash
systemctl --user disable --now dsv41-tensorfold.service
```

If the start limit is reached, inspect the journal and saved rank logs, then fix the underlying cause (for example,
an oversized workload, missing artifacts, Docker or the worker link). Clear the failure and start again:

```bash
systemctl --user reset-failed dsv41-tensorfold.service
systemctl --user start dsv41-tensorfold.service
```

For settings or recipe updates, stop the service first, update and prepare/test interactively, then stop that manual
test server before starting the service again. Use `daemon-reload` if you edited the unit itself. Keep one supervisor
for this pair; do not combine it with a separate restart watcher or per-container restart policy.

## Validation

`python3 scripts/test_systemd_unit.py` validates the unit with `systemd-analyze` when available. Optional lifecycle
tests use temporary stub scripts and transient user units, with shorter test-only timers:

```bash
RUN_SYSTEMD_LIFECYCLE_TESTS=1 python3 scripts/test_systemd_unit.py
```

They cover failure exits, the restart limit, successful exit, an explicit stop and the preparation/foreground
environment. They do not launch Docker, contact the worker, load a model, or install/enable the real service.
