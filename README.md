# Tailscale for WD My Cloud OS5

An unofficial **Tailscale** app for **WD My Cloud OS5**, installed from the dashboard with **Apps → Install an app manually**. It puts the NAS on your tailnet:
- It survives firmware-style app upgrades and reboots.
- It keeps the node's identity.
- If a new binary won't start, it falls back to the last one that worked.

The app has an On/Off switch, a **Configure** page and an Uninstall button in the dashboard. It doesn't edit other apps or system files.

Its companion, [Transmission 4 for WD My Cloud OS5](../../../wd-mycloud-os5-transmission), is built the same way.

> **Unofficial.** Not made, endorsed or supported by Western Digital or Tailscale Inc. "Tailscale" is a trademark of Tailscale Inc. The app is provided as is (see [LICENSE](LICENSE)). Tailscale may be your only way in to the NAS: read the notes below before installing.

## Supported devices

| Device | Status |
|---|---|
| My Cloud EX2 Ultra, OS 5.33.102 | Tested, in daily use |
| Other OS5 models | Untested |

Other ARM models need their own build (the model name is part of the package). The x86 models (PR2100, PR4100, DL2100, DL4100) need x86 binaries, which this repo doesn't build.

## Installing

1. **Download** the `.bin` from the [releases](../../releases) and compare its SHA256 with the one published next to it.
2. **Install:** in the dashboard, **Apps → Install an app manually**, then choose the file. The app installs switched OFF.
3. **Switch it on:** read the first-start notes below, then switch **Run App** ON.
4. **Configure:** with the app ON, its **Configure** button opens its settings page inside the dashboard.

The usual setup needs no SSH. For the rest (logs, the `tailscale` command), turn SSH on under **Settings → Network → Network Services → SSH**; the user name is `sshd`.

## First start

- **A NAS without Tailscale:** the app starts a new node. Log it in to your tailnet once on the **Configure** page, in either of two ways:
  - **Get a login link**, open it, and log in with your Tailscale account.
  - Or paste an **auth key** from the admin console (Settings → Keys). It's used once and not kept on the NAS.

  Over SSH, `/mnt/HD/HD_a2/Nas_Prog/tailscale/bin/tailscale up` does the same. Consider disabling key expiry for the NAS in Tailscale's admin console. An expired key on a remote NAS means a lockout.
- **A NAS that runs Tailscale started by hand from `/mnt/HD/HD_a2/tailscale`** (for example from twonky's `start.sh`): the app takes it over.
  - It stops the old daemon, copies its identity, and starts its own. The NAS keeps the same tailnet address.
  - It then waits up to 10 minutes for proof that the NAS is still reachable: received traffic (keep the dashboard open), or a file created over SSH, `touch /mnt/HD/HD_a2/.systemfile/tailscale/confirm`.
  - Without proof it switches back to the old daemon.
  - Afterwards, remove the old start lines by hand.
- **A Tailscale started any other way** (Entware, Docker, another folder): stop it first. The app won't run a second daemon next to it.

**Switching the app OFF or uninstalling it disconnects the NAS from your tailnet.** Keep another way in (your LAN, or a VPN to it) while you change anything here.

## The Configure page

You can change:
- the NAS's name on the tailnet;
- subnet routes to offer, such as your home network;
- whether the NAS offers itself as an exit node (IPv4);
- whether Tailscale updates itself.

These apply at once. Routes and the exit node turn on IP forwarding on the NAS, and still need approval in the admin console.
- **Exit node and routes on the EX2 Ultra:** its kernel has no iptables NAT, so tailscaled can't NAT forwarded traffic. Both most likely work only if your router has a route back to 100.64.0.0/10 through the NAS; this is untested.

The page can also take the NAS off its tailnet:
- **Disconnect:** offline, still logged in; **Connect** brings it back.
- **Log out:** leave the tailnet. Logging in again makes the NAS a new device.
- **Connect to another tailnet:** log in to a different account or tailnet, even while connected. The current tailnet's login stays on the NAS. A refused key puts it straight back, and **Go back** returns to it from an unfinished login.

If the NAS is far away, Tailscale may be your only way in, so each of these asks twice: a checkbox ("I can reach this NAS without Tailscale"), then a confirmation. When the page notices it was opened through Tailscale, it says that it will stop answering; switching from there then only takes an auth key, which can't leave the NAS stranded between tailnets.

Tailscale SSH and using other devices' routes or exit nodes aren't on the page; use the `tailscale` command over SSH for those.

## Updating

Install the newer `.bin` over the installed app, whether it's ON or OFF. Tailscale keeps running while its folder is replaced, then moves to the new binary, a few seconds off the tailnet. If the new binary doesn't come up, it goes back to the previous one.

WD's dashboard calls this a re-install, and installs the new package switched OFF. The app remembers whether it was ON. Once WD's installer has finished, it puts Run App back the way it was, so the page you get after "App installed" shows it ON. If the dashboard's own list still disagrees a few seconds later, the app asks WD with the same request the dashboard's switch sends. If the dashboard still shows OFF after a refresh, switch it ON yourself: that's harmless, and makes the dashboard match.

WD's "Updating" dialog sometimes never hears that the installer has finished, and waits for good. If WD recorded the install as done and the app was ON, the app hands the dialog that result. If the dialog still hangs, refresh the page.

Tailscale's own auto-update, if you turned it on, replaces the binaries inside the app folder. The next package upgrade installs the package's version again.

## Uninstalling

The node identity and the logs are kept in `/mnt/HD/HD_a2/.systemfile/tailscale/`, and a later install picks them up again. Delete that folder over SSH to remove everything.

## Where things are

| | |
|---|---|
| App (replaced on every upgrade) | `/mnt/HD/HD_a2/Nas_Prog/tailscale/` |
| Node identity | `/mnt/HD/HD_a2/.systemfile/tailscale/state/` |
| Logs (1 MB, one rotation) | `/mnt/HD/HD_a2/.systemfile/tailscale/log/` |
| What the app did, in order | `log/app.log` |

## How it works

- **WD's app lifecycle** was measured on the NAS, not guessed: which script runs when, with which arguments, on install, upgrade, boot and shutdown. The results are in [docs/os5-app-lifecycle.md](docs/os5-app-lifecycle.md).
  - WD switches every app OFF on upgrade and deletes its folder.
  - So the app keeps its state and its own "should run" flag on the data volume, and restores itself.
- **The EX2 Ultra's kernel uses 32 KB memory pages.** A binary or library whose ELF segments are aligned to only 4 KB segfaults before it starts.
  - That's true of most distribution packages and many Docker images. qemu on a PC can't show it.
  - WD's own binaries and Go programs such as Tailscale are 64 KB-aligned and run fine.
  - [tools/check-elf-alignment.sh](tools/check-elf-alignment.sh) checks any binary, and every package build runs it.
- **Security:**
  - Tailscale runs as root, because it needs the TUN device.
  - Upstream files are pinned by checksum, so the build refuses anything else.
  - No secrets are ever in a package. Keys stay on the data volume.
- **The Configure page.** WD's web server runs PHP as root, so the page's small `api.php` is written as a security boundary ([common/web/app-api.php](common/web/app-api.php)):
  - The page lives only under `/apps/tailscale/`, the one place where the dashboard login is required (`CenterType: 1`). `api.php` refuses to work from anywhere else.
  - Requests from other websites are refused: each one needs a custom header and a matching `Origin`.
  - Every value is checked in PHP, and again by the app's `ctl.sh`, which does the actual work. Values reach it on stdin, never on a command line.
  - The page shows no secrets. An auth key goes to `tailscale` on its standard input, and is never written to a file or a log.
  - "Log in" on the page is for a node that has never logged in. For a node whose login expired, a page login would make it a new device with a new address, so the page sends you to `tailscale up` over SSH instead, which keeps it. Making it a new device on purpose is what "Connect to another tailnet" is for.
  - Keys travel like the dashboard's own login does: encrypted when you open the dashboard over Tailscale or its HTTPS port, readable on the network over plain HTTP.

## Building from source

You need Linux or WSL2 with Docker. Run everything from the repository root.

```sh
tailscale/build.sh       # dist/MyCloudEX2Ultra_tailscale_<version>.bin
tests/run-all.sh         # stub package, simulations, syntax checks, ShellCheck
tests/web-preview.sh     # the Configure page on http://localhost:8080, with a stub daemon
```

- **`dist/`** gets the `.bin` with its `.sha256` and a list of its contents.
- **Pinning:** the build refuses upstream files whose checksums differ from the pinned ones, in `tailscale/upstream.env`.
- **New Tailscale release:** `tailscale/bump.sh` shows it and its checksum.
- **Versions** are `<upstream>-<revision>`; bump the revision in `apkg.rc` for any change to the package.
- **Icon:** edit `tailscale/icon.svg`, then run `tools/render-icons.sh`.

`tests/run-all.sh` drives the app through WD's measured script sequences in a BusyBox container, with a stub daemon:
- install, upgrades while ON, reboots, takeovers, refusals, uninstall
- a NAS with and without earlier installs

It also serves the Configure page with PHP 7.4, as on the NAS, and calls its `api.php` as the page does. That covers the request guards, bad values, and each change end to end. Finally it checks the PHP and JavaScript syntax and runs ShellCheck.

## License

The scripts in this repository are under the MIT License ([LICENSE](LICENSE)).

The package also contains Tailscale's binaries, unmodified, under BSD-3-Clause. Its `licenses/` folder has a `README.txt` that lists every component and its license.
