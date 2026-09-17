# findoc_linux_exporter — install

Installs the Findoc Monitoring agent on a Linux host. One command, both monitoring services,
no configuration file to edit.

```bash
git clone https://github.com/ankittshrmaa/findoc_linux_exporter.git
cd findoc_linux_exporter
sudo ./install.sh
```

That is the whole thing, and it needs **no network at all** — not even to reach this repo a
second time. The packages are committed under `dist/`, so the clone you just did is the delivery
mechanism. There is no server to stand up, no mirror to configure, and nothing to publish before
a host can be onboarded.

Everything below is detail for when discovery is not set up, or when something goes wrong.

---

## What gets installed

Two services, which run **independently on purpose**:

| Service | Port | What it does |
|---|---|---|
| `findoc-exporter-heartbeat` | — | Sends a ~40 byte "alive" frame every second. This is what detects a dead host in under five seconds. |
| `findoc-exporter-metrics` | `9100` | `node_exporter`, trimmed to the metrics the platform actually uses. Scraped over the LAN by the site collector. |

They have no dependency on each other. "The exporter stopped answering" and "the host is dead"
are different facts: the first is a low-severity ticket, the second wakes somebody up. Stopping
one does not touch the other.

| Path | What it is |
|---|---|
| `/opt/findoc-exporter/` | Programs and licences |
| `/etc/findoc-exporter/exporter.env` | The only file you might edit |
| `/etc/findoc-monitor/host-id` | This host's identity. **Never delete it** — see below |
| `/var/log/journal` (`journalctl`) | Logs |

## Requirements

- **Linux, x86_64.** The installer refuses anything else rather than installing a package that
  cannot run.
- **systemd.** Present on every supported distribution.
- **Outbound TCP to port 4222** on the site's collector. That is the only network access the
  agent needs.
- Nothing else. No Python, no runtime, no dependencies — the agent carries its own.

### Supported distributions

Every one of these was tested by running the agent on it:

| | |
|---|---|
| **Red Hat family** | CentOS 7, RHEL 7 · RHEL/CentOS/Rocky/AlmaLinux 8 · RHEL/CentOS Stream/Rocky/AlmaLinux 9 |
| **Debian family** | Debian 10, 11, 12 · Ubuntu 18.04, 20.04, 22.04, 24.04 |

Older than that will refuse to start with a clear `GLIBC` error rather than misbehave.

## Installing

### The normal case

```bash
sudo ./install.sh
```

The agent finds the collector by DNS, so there is nothing to configure. It looks for a host
named `findoc-collector`, then `findoc-monitor`, resolved through this machine's own DNS search
suffix — one DNS record covers the whole estate.

### If DNS discovery is not set up

Tell it where to report, once. The value is written into `exporter.env` and remembered:

```bash
sudo FINDOC_BACKEND=nats.your-site.internal:4222 ./install.sh
```

### Other options

| Variable | Use it when |
|---|---|
| `FINDOC_BACKEND=host:4222` | DNS discovery is not available |
| `FINDOC_SITE=mumbai` | This host belongs to a named site (must match the collector's) |
| `FINDOC_URL=http://packages.internal/findoc` | Hosts cannot reach GitHub — see [air-gapped](#air-gapped-and-restricted-networks) |
| `FINDOC_VERSION=0.2.0` | Pin a specific version instead of the latest |

### Where the package comes from

`install.sh` looks in this order, and stops at the first that works:

1. **A package in `dist/`, or next to the script.** This is the normal path now: the packages
   ship in this repository, so a `git clone` already has them. No network, no mirror, no
   release to download.
2. **`FINDOC_URL`** — an internal HTTP server. For an estate that mirrors packages itself, or
   that wants a version this clone does not carry.
3. **GitHub Releases** — the fallback, and last on purpose. A trading host reaching the public
   internet is the exception rather than the rule.

### What ships in `dist/`

| File | Size | What it is |
|---|---|---|
| `findoc-linux-exporter_0.1.3-1_amd64.deb` | 25 MB | Debian, Ubuntu, and anything `ID_LIKE=debian` |
| `findoc-linux-exporter-0.1.3-1.el7.x86_64.rpm` | 33 MB | RHEL 7+, Rocky, Alma, Oracle Linux |
| `*.sha256` | — | Verified before install, always. A mismatch aborts. |
| `*.asc` | — | Detached GPG signature. See below. |

Each package carries its own `node_exporter`, its own CPython and its own OpenSSL, which is why
one artifact covers CentOS 7 through Ubuntu 24.04 and why they are this size.

**The signing key is deliberately NOT in this repository.** A key that travels with the package
it verifies proves nothing — anyone who can replace one can replace the other. Put the public key
on the host by a different route (base image, configuration management, or once by hand) at
`/etc/findoc-exporter/signing-key.asc`, and `install.sh` will verify against it. Without it the
installer says so plainly and continues: integrity is checked, origin is not.

**A note for whoever maintains this.** Committing 58 MB of packages per release is a deliberate
trade: it makes onboarding work on an air-gapped host with nothing but `git`, and it grows this
repository by that much on every version bump, permanently. Keep `dist/` to the current release
only — replacing rather than accumulating — and if the history ever becomes a problem, the answer
is Git LFS or going back to Releases, not deleting files from `dist/` and hoping.

## What success looks like

```
==> Findoc Monitoring exporter installer
    OS       = Linux
    Distro   = Debian GNU/Linux 12 (bookworm)  (family: debian)
    Arch     = x86_64 -> amd64
==> Using the package already on this host
    sha256 verified
==> Installing
==> Starting both planes

==> Result
    version   findoc-agent 0.1.0 (CPython 3.12.11, Linux x86_64)
    heartbeat active
    metrics   active
    backend   nats://nats.your-site.internal:4222

Both planes are running. This host is monitored.
```

**"Monitored" means both services are running *and* the agent has somewhere to report to.** The
installer will not say it otherwise, and exits non-zero if it cannot.

## When it does not work

### "no backend is reachable"

```
Installed and enabled for boot, but NOT started: no backend is reachable.
```

The install worked. The agent has nowhere to report, so it was deliberately not started — an
agent retrying an address that will never answer looks alive while monitoring nothing.

Fix it with any one of:

```bash
# tell it directly, then start
sudo sh -c 'echo "FINDOC_BACKEND=nats.your-site.internal:4222" >> /etc/findoc-exporter/exporter.env'
sudo systemctl start findoc-exporter.target

# or a one-line file, if DNS cannot be changed
echo "nats.your-site.internal:4222" | sudo tee /etc/findoc-monitor/backend

# or ask the agent what it is looking for
sudo /opt/findoc-exporter/bin/findoc-agent/findoc-agent --show-backend
```

### "unsupported architecture"

The package is x86_64 only. The installer refuses rather than installing it, because
`node_exporter` would run and the agent would not — leaving a host that reports metrics and
whose death nobody notices.

### "unsupported distribution"

The host is not in the Debian or Red Hat family. Installing the wrong package format would leave
a machine that looks installed and monitors nothing.

### "checksum mismatch"

The download did not match its published hash. **Do not install it.** Either the transfer was
corrupted or the file was substituted.

### "neither curl nor wget is installed"

Minimal image. Either install one, or copy the package next to `install.sh` — a local package
needs no network.

## Managing it afterwards

```bash
# start or stop both at once
sudo systemctl enable --now findoc-exporter.target
sudo systemctl stop findoc-exporter-heartbeat findoc-exporter-metrics

# check one plane — NOT the target; see the note below
systemctl is-active findoc-exporter-heartbeat
systemctl is-active findoc-exporter-metrics

# logs
journalctl -u findoc-exporter-heartbeat -f
journalctl -u findoc-exporter-metrics -f

# what is it reporting to?
sudo /opt/findoc-exporter/bin/findoc-agent/findoc-agent --show-backend

# which version?
/opt/findoc-exporter/bin/findoc-agent/findoc-agent --version

# is the metrics endpoint answering?
curl -s localhost:9100/metrics | head
```

> **`findoc-exporter.target` starts things; it does not tell you whether they are healthy.** A
> systemd target reports `active` once it has been *reached*, even if every service under it has
> since stopped. To judge a host, name the plane:
> `systemctl is-active findoc-exporter-heartbeat`.
>
> Note also that `systemctl enable --now findoc-exporter` does **not** work — systemd expands a
> bare name to `.service`, and there is deliberately no such unit. The `.target` suffix is
> required.

## Upgrading

Re-run the installer. It replaces the package in place, keeps `exporter.env` and the host
identity, and restarts both services onto the new binaries.

```bash
git pull
sudo ./install.sh
```

## Uninstalling

```bash
sudo apt-get remove findoc-linux-exporter     # Debian / Ubuntu
sudo yum remove findoc-linux-exporter         # RHEL / CentOS
```

Both remove the services, the programs and the configuration.

**`/etc/findoc-monitor/host-id` is kept on purpose.** It is this host's name in the monitoring
platform, not package configuration. A machine that came back with a new identity would be a
*new* host: no history, no alert state, no operator approval. Deleting it orphans everything
this machine has ever reported.

Cloning a VM? Run `findoc-agent --prepare-image` before sealing the template, or every clone
reports as the same machine.

## Air-gapped and restricted networks

Hosts that cannot reach GitHub have two options.

**Copy the package alongside the installer:**

```bash
scp findoc-linux-exporter_0.1.0_amd64.deb* host:/tmp/findoc/
ssh host 'cd /tmp/findoc && sudo sh install.sh'
```

**Or host the packages internally.** Put the `.deb`, the `.rpm`, their `.sha256` files and a
`latest.txt` containing the version number on any web server:

```
http://packages.internal/findoc/
├── latest.txt                                     "0.1.0"
├── findoc-linux-exporter_0.1.0_amd64.deb
├── findoc-linux-exporter_0.1.0_amd64.deb.sha256
├── findoc-linux-exporter-0.1.0-1.el7.x86_64.rpm
└── findoc-linux-exporter-0.1.0-1.el7.x86_64.rpm.sha256
```

```bash
sudo FINDOC_URL=http://packages.internal/findoc ./install.sh
```

Checksums are verified either way.

## Rolling it out

`install.sh` is safe to run unattended and is idempotent, so any configuration management tool
can call it directly:

```bash
ansible all -b -m script -a "install.sh" -e "FINDOC_BACKEND=nats.your-site.internal:4222"
```

It exits `0` only when the host is genuinely monitored, so a non-zero exit is a real failure
worth surfacing rather than noise.

A new host is registered as **`collect_only`**: scraped, stored and visible on dashboards, but
unable to page anyone until an operator approves it. That is deliberate — paging is an opt-in
act, not a side effect of installing software.

## Building the packages

The build lives in the Findoc Monitoring platform repository, not here. This repository is for
installing on a host.

## Licence

Includes `node_exporter` (Apache 2.0), CPython (PSF) and `nats-py` (Apache 2.0), redistributed
with their licences at `/opt/findoc-exporter/licenses/` on an installed host.
