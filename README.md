# findoc_linux_exporter

Installs the Findoc Monitoring agent on a Linux host: one package, one service, and **no
listening network port**.

## Install

```bash
git clone https://github.com/ankittshrmaa/findoc_linux_exporter.git
cd findoc_linux_exporter
sudo FINDOC_BACKEND=<your-site-collector>:4222 ./install.sh
```

Replace `<your-site-collector>` with your site's NATS address, for example
`nats.mumbai.internal`. That is the whole install. The packages ship in `dist/`, so it needs no
internet access once the clone is on the host.

If your estate has a `findoc-collector` DNS record, leave the variable out:

```bash
sudo ./install.sh
```

### Check it worked

The installer ends with a verdict, and it exits non-zero unless the host is actually monitored:

```
==> Result
    version   findoc-agent 0.2.2-1 (CPython 3.12.11, Linux x86_64)
    service   active
    planes    all planes running: heartbeat, metrics, metrics-push
    backend   nats://nats.mumbai.internal:4222

Both planes are running. This host is monitored.
```

At any time afterwards:

```bash
sudo /opt/findoc-exporter/bin/findoc-agent/findoc-monitor status
```

```
findoc-monitor 0.2.2-1
host 3f2c6e0a-...

  service   OK     active (running), pid 309
                   all planes running: heartbeat, metrics, metrics-push
  liveness  OK     connected to nats://nats.mumbai.internal:4222, seq 361204, published 0.4s ago
  metrics   OK     serving on /run/findoc-monitor-metrics.sock, 33/35 contract sources present

OK
```

Run it with `sudo`. The metrics socket is readable only by root and the service account.

## Requirements

| | |
|---|---|
| CPU | x86_64 only. The installer refuses anything else. |
| OS | CentOS/RHEL 7, RHEL/Rocky/Alma 8 and 9, Debian 10 to 12, Ubuntu 18.04 to 24.04 |
| Init | systemd |
| Network | **Outbound** TCP 4222 to the site collector. Nothing inbound. |
| Software | Nothing. The agent carries its own Python and OpenSSL. |

## Options

Pass these to `install.sh` as environment variables, as in the install command above.

| Variable | When to use it |
|---|---|
| `FINDOC_BACKEND=host:4222` | No `findoc-collector` DNS record for this host |
| `FINDOC_SITE=mumbai` | The host belongs to a named site. Must match the site collector's `--site`. |
| `FINDOC_URL=http://packages.internal/findoc` | Install from an internal mirror instead of `dist/` |
| `FINDOC_VERSION=0.2.2-1` | Pin a version |
| `FINDOC_GPG_KEY=/path/key.asc` | Where the public signing key is (default `/etc/findoc-exporter/signing-key.asc`) |

## What gets installed

One systemd service, `findoc-monitor`, running a small supervisor with three child processes:

| Child | What it does |
|---|---|
| `heartbeat` | Holds one outbound NATS connection and sends a 40-byte frame every second. A dead host is detected in under five seconds. |
| `metrics` | `node_exporter` 1.9.1, trimmed to the metrics the platform uses. It serves a UNIX socket that systemd owns, and opens **no TCP port**. |
| `metrics-push` | Reads that socket and publishes the samples to the site collector over the same outbound link. |

Each child is restarted on its own. A metrics fault never stops the heartbeat, so "the exporter
stopped" and "the host is dead" stay different alerts with different urgency.

| Path | What it is |
|---|---|
| `/opt/findoc-exporter/` | Programs and licences |
| `/etc/findoc-monitor/findoc-monitor.conf` | The only file you might edit |
| `/etc/findoc-monitor/host-id` | This host's identity. **Never delete it.** |
| `journalctl -u findoc-monitor` | Logs, all three children in one stream |

## Day to day

```bash
systemctl status findoc-monitor              # state, children, and which plane is down if any
sudo systemctl restart findoc-monitor        # restart everything
sudo systemctl stop findoc-monitor           # stop everything
journalctl -u findoc-monitor -f              # logs
sudo /opt/findoc-exporter/bin/findoc-agent/findoc-monitor status   # the health verdict

# change the backend or site
sudo nano /etc/findoc-monitor/findoc-monitor.conf
sudo systemctl restart findoc-monitor
```

Restart the **service**, never `findoc-monitor.socket` on its own. The service pulls the socket
back with it and is always safe.

## Upgrading

```bash
git pull
sudo ./install.sh
```

Installing the package is the upgrade. The host identity and your configuration are kept.

**Coming from 0.1.x** (the two services `findoc-exporter-heartbeat` and
`findoc-exporter-metrics`, with `:9100` open): the upgrade moves the host onto `findoc-monitor`
and disables the old units. Expect a few seconds with no heartbeat while that happens, so upgrade
a site in batches. If the new service is not healthy within 30 seconds, the upgrade **rolls
itself back** to the old units and says so. The host is never left unmonitored.

To roll back by hand:

```bash
sudo systemctl disable --now findoc-monitor
sudo systemctl enable --now findoc-exporter-metrics findoc-exporter-heartbeat
```

## When it does not work

| The installer or `findoc-monitor status` says | What to do |
|---|---|
| `NOT started: no backend is reachable` | The install worked, but the agent has nowhere to report. Set `FINDOC_BACKEND` in `/etc/findoc-monitor/findoc-monitor.conf`, then `sudo systemctl start findoc-monitor`. `findoc-agent --show-backend` shows what it is looking for. |
| `liveness FAULT ... DISCONNECTED` | The agent runs but cannot reach the collector. This host is **invisible**: if it dies now, nobody is paged. Check the address and the network path to TCP 4222. |
| Journal shows `retrying; repeats are summarised every 60s` | The backend is down or unreachable. Nothing to restart: the agent keeps retrying the address you configured and connects by itself when it answers, then logs `connected after N failed attempt(s)`. |
| `metrics DOWN (no listening socket ...)` | The metrics socket is missing. The heartbeat is unaffected. Run `sudo systemctl restart findoc-monitor`. |
| `metrics FAULT ... families produce NO series` | A collector is being blocked. Report it with the full `status` output. |
| status line says `heartbeat (restarted 47x)` | A child is crash-looping. Run `journalctl -u findoc-monitor \| grep exited`. |
| `checksum mismatch` | **Do not install.** The file was corrupted or substituted. |
| `unsupported architecture` / `unsupported distribution` | This host is not x86_64 Linux in the Debian or Red Hat family. |

## Signatures

Each package in `dist/` has a `.sha256`, which the installer always checks, and a detached
`.asc` GPG signature.

The public key is **deliberately not in this repository**. A key that travels with the package
it verifies proves nothing. Put it on hosts by another route, such as the base image or
configuration management, at `/etc/findoc-exporter/signing-key.asc`. The installer then verifies
every package against it and refuses one that does not match. Without the key it says so and
continues: integrity is checked, origin is not.

> **0.2.2-1 is signed with the same TEST key as 0.1.3-2** (`Findoc Test Signing (THROWAWAY)`,
> key ID `1FE55443`). It is not a production key. Production releases wait on a real release key
> and a signed apt/yum repository.

## Air-gapped hosts

Copy the package, its `.sha256` and `.asc`, and `install.sh` into one directory on the host, then:

```bash
sudo FINDOC_BACKEND=<collector>:4222 sh install.sh
```

Or serve them from any internal web server with a `latest.txt` containing the version:

```
http://packages.internal/findoc/
├── latest.txt                                           0.2.2-1
├── findoc-linux-exporter_0.2.2-1_amd64.deb   (+ .sha256, .asc)
└── findoc-linux-exporter-0.2.2-1.el7.x86_64.rpm   (+ .sha256, .asc)
```

```bash
sudo FINDOC_URL=http://packages.internal/findoc ./install.sh
```

## Rolling out to many hosts

`install.sh` is idempotent and safe to run unattended. It exits `0` only when the host is
genuinely monitored, so a non-zero exit is a real failure:

```bash
ansible all -b -m script -a "install.sh" -e "FINDOC_BACKEND=nats.mumbai.internal:4222"
```

A new host registers as **`collect_only`**: its metrics are stored and visible, but it cannot
page anyone until an operator approves it. Paging is a deliberate act, not a side effect of
installing software.

Cloning VMs? Run `/opt/findoc-exporter/bin/findoc-agent/findoc-agent --prepare-image` before
sealing the template, or every clone reports as the same machine.

## Uninstalling

```bash
sudo apt-get remove findoc-linux-exporter     # Debian / Ubuntu
sudo yum remove findoc-linux-exporter         # RHEL family
```

`/etc/findoc-monitor/host-id` is **kept on purpose**, even on purge. It is this host's name in
the monitoring platform. A reinstalled machine with a new identity would come back as a new,
unapproved host with no history.

## What was verified for 0.2.2-1

Measured against these exact packages, 2026-09-25:

| Check | Result |
|---|---|
| Package contract | 33 passed, 0 failed |
| CentOS 7 (glibc 2.17) | 23 passed, 0 failed |
| systemd contract, booted systemd 255 | 26 passed, 0 failed |
| Kill and restart matrix | 21 passed, 0 failed |
| Upgrade from 0.1.3-2, with rollback | 20 passed, 0 failed |
| Install, upgrade, uninstall, reinstall, purge | 33 passed, 0 failed |
| `install.sh` on Debian 12, Ubuntu 20.04/22.04, AlmaLinux 8/9, CentOS 7 | 24 passed, 0 failed |
| Agent started with its backend DOWN, backend brought up later | 7 passed, 0 failed: no loopback fallback, no crash loop, liveness OK 2 s after the backend returned, no restart |

Measured recovery: a killed heartbeat is back in under 0.9 s, and a killed `node_exporter` in
under 5 s.

Not yet verified, because each needs a real host: CentOS 7 running the unit under its own
systemd 219, endpoint security and SELinux on a trading host, and the performance impact on one.

## Building the packages

The build and its test harnesses live in the Findoc Monitoring platform repository. This
repository is only for installing on a host.

## Licence

Includes `node_exporter` (Apache 2.0), CPython (PSF) and `nats-py` (Apache 2.0), redistributed
with their licences at `/opt/findoc-exporter/licenses/` on an installed host.
