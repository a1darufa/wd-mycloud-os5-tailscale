# OS5 app lifecycle — what the app manager actually runs

Measured on the target NAS (My Cloud EX2 Ultra, firmware 5.33.102) on
2026-10-27 with the `apkgprobe` test app (`apkgprobe/`), which logs every
script call to `/mnt/HD/HD_a2/.systemfile/apkgprobe*/probe.log` on the NAS.

## Who runs what

- **Upload step:** `upload_apkg` (started by the web CGI `apkg_mgr.cgi`, cwd
  `/var/www/cgi-bin`, CGI environment) runs the **new** package's
  `before_apkg.sh` from `Nas_Prog/_install/<pkg>/`, with no arguments.
- **Everything else:** the `apkg` daemon (UDP 127.0.0.1:30958, stdout to
  `/dev/console`). Scripts get the app folder `Nas_Prog/<pkg>` as `$1`, except
  `install.sh`, which gets `Nas_Prog/_install/<pkg>` and `Nas_Prog`.
- The daemon creates an empty `Nas_Prog/<pkg>` before `install.sh` runs;
  `cp -rf "$1" "$2"` merges into it correctly.
- `start.sh` is launched in the background (its parent is `init`), so it does
  not block the web request. `stop.sh` runs synchronously under the daemon.

## Sequences

| Action | Scripts, in order |
|---|---|
| Fresh manual install | `before_apkg` (new) → `install` (new) → `init` (new). App is **OFF**; no `start`. |
| Run App ON | `start` |
| Run App OFF | `stop` |
| Upgrade, app OFF | `before_apkg` (new) → `clean` (old) → `preinst` (old) → `remove` (old) → `install` (new) → `init` (new) |
| Upgrade, app ON | `before_apkg` (new) → **`stop` (old)** → `clean` (old) → `preinst` (old) → `remove` (old) → `install` (new) → `init` (new). App ends **OFF**; no `start`. |
| Shutdown / reboot | enabled apps: `stop` → `clean`; disabled apps: `clean`. The whole round ran **twice**, 18 s apart. |
| Boot | `init` for **every** installed app, enabled or not (~111.8 s after boot), then for each enabled app `stop` → `start` (~112 s). |
| Uninstall, app OFF | `clean` → `remove` |
| Uninstall, app ON | `stop` → `clean` → `remove` |

`preinst.sh` runs **only on upgrade**, never on uninstall, and the new
package's `before_apkg.sh` runs only on install/upgrade. So the scripts can
tell the cases apart:

| Case | Sign |
|---|---|
| Upgrade | new `before_apkg.sh` ran first; old `preinst.sh` runs before old `remove.sh` |
| Uninstall | `remove.sh` without a preceding `preinst.sh` / `before_apkg.sh` |
| Run App OFF | `stop.sh` alone |
| Shutdown | `stop.sh` → `clean.sh`, twice |

On an upgrade of a running app, the old `stop.sh` runs *before* the old
`preinst.sh`, so only the flag from the new `before_apkg.sh` reaches it.

### Boot timeline (reboot on 2026-10-27, seconds since boot)

| t | Event |
|---|---|
| 109.7 | `apkg` daemon starts |
| 111.8 / 111.9 | `init.sh` of apkgprobe (ON) / apkgprobe2 (OFF) |
| 112.0 | GoodSync's `gs-server` starts |
| 112.07 → 112.22 | apkgprobe `stop.sh` → `start.sh`; `tailscaled` and twonky not running yet |
| 112.5 | Transmission's daemon starts |
| 117.7 | `twonkyserver` starts (twonky's `start.sh` sleeps 5 s first) |
| 119.8 | `tailscaled` starts from the twonky hook |

All `start.sh` scripts launch in the background at about the same time, so
an app's daemon is up roughly 5 s before the twonky hook checks
`pidof tailscaled`. That head start comes from twonky's `sleep 5`, not from a
guaranteed order. The NAS was off Tailscale for about 2.5 minutes in total.

Never seen called: `pre_inst.sh`, `reinstall.sh`, `rm_link.sh` (names exist in
the daemon binary).

## Consequences for our apps

- **Nothing inside `Nas_Prog/<pkg>` survives an upgrade**, because the old
  `remove.sh` runs. State and config must live outside the app folder.
- **Upgrading a running app leaves it stopped and switched OFF.** The new
  package's `apkg.xml` (`<enable>0</enable>`) replaces the stored state, and
  the daemon does not run `start.sh`. For the Tailscale app this means a
  web-UI upgrade would cut the only access path unless the app handles it
  itself. The new package's `before_apkg.sh` runs first, so it can mark "upgrade
  in progress" for the old `stop.sh`/`remove.sh` and the new `init.sh`.
- Upgrading a running app also hangs the web UI's "Updating" dialog. The
  dialog polls `cmd=module_show_install_status` every 5 s and only closes when
  `install_status` (in `/var/www/xml/apkg_state.xml`) leaves 100
  (`APKG_INSTALLING`); for the ON-upgrade it stayed at 100 for good. A page
  refresh shows the upgraded app, switched OFF. The OFF-upgrade (0.1.1)
  finished normally, and the two packages differed only in one log line, so
  this is WD's handling of upgrading a running app, not the package.
  It doesn't happen every time: on 2026-10-28 Transmission 4.1.4-5's
  ON-upgrade got status 1 ("installed") a second after `init.sh`. Every hang
  seen so far is WD's status staying at 100 while the dialog keeps polling:
  Apache's `/var/log/apache2/access.log` logs each poll with its answer's
  size, and the size gives the status away. In one hang (2026-10-29 02:44),
  `upload_apkg` had exited within a second of `init.sh` without writing 1.
- `upload_apkg` writes a debug log to `/tmp/upload_apkg_dbg.log` while
  `/tmp/dbg_upload_apkg` (or `/usr/local/config/dbg_upload_apkg`) exists, or
  with `-d`.
- WD can lose the uploaded file's name. It happened twice on 2026-10-29
  and once on 2026-11-08, each time on a first attempt with the 36 MB
  Tailscale package. The status record changed the name to `null`
  between two polls of the "re-install?" step. OK's request then took 10 s
  instead of 1 s and ran `upload_apkg -r null`, which failed with 101
  ("Unable to upload app package"), while the uploaded file stayed intact
  in `/usr/local/apps_upload/`. It happens inside WD's upload step,
  before any app script runs. Uploading again is the way out, and it has
  worked every time. Running OK's own command on the uploaded file over SSH
  should work too, but hasn't been tried: `upload_apkg -r <file name> -f 1
  -g 0`. A good OK runs exactly that, with the bare file name; `upload_apkg`
  looks for it in `/usr/local/apps_upload/` itself.
- The dialog's poll (`apps_get_install_status()` in
  `/var/www/web/function/appsDiag.js`) has no error handler: one failed
  request ends the polling, and the dialog stays on "Updating". The CGI
  answers from `/var/www/xml/apkg_state.xml` and deletes it after a final
  answer; `upload_apkg` also writes `/tmp/apkg_state.xml`, which stays.
- Uploading a package whose app is installed always asks "already installed
  … re-install?" (status 4), and OK sends `cmd=cgi_apps_reinstall`. Apps
  installed by hand have no other path. The dashboard's Update button is only
  for apps from WD's App Store (`/var/www/xml/app_update.xml`).
- `init.sh` runs at boot even for apps switched OFF, so an app can restore
  itself at boot based on its own "should run" flag kept outside the app
  folder, regardless of WD's `<enable>`.
- `stop.sh` runs right before `start.sh` at every boot, and twice during
  shutdown, so it must be harmless when nothing is running.
- A script an app left running keeps running through an upgrade, on the
  earlier version's code: the shell reads it from the deleted `ctl.sh`
  (`/proc/<pid>/fd/10 -> …/ctl.sh (deleted)`). Seen 2026-11-07: both apps'
  log keepers, started 2026-10-30 and 2026-11-05, outlived several upgrades
  and held their locks, so a new version's keeper exited at once. From
  Tailscale 1.104.4-6 a new keeper stops one running a deleted `ctl.sh`.
- `/home/root` is in RAM: SSH keys added there are wiped by every reboot.
- A Run App click right after an install can be dropped while the daemon is
  still busy (seen once, 3 s after install). Wait a few seconds.
- The stored Run App state is `<enable>` in `Nas_Prog/<pkg>/apkg.xml`; the
  dashboard reads `/var/www/xml/apkg_all.xml`.
- The dashboard's Run App switch POSTs `cmd=cgi_apps_set&f_module_name=<pkg>&f_enable=<0|1>`
  to `/cgi-bin/apkg_mgr.cgi`. The same request sent on the NAS itself to
  Apache (`http://127.0.0.1:8000`, local only) works without a login
  (checked 2026-10-28). WD stores the switch, runs `start.sh` or `stop.sh`,
  and answers `<result>1</result>`.
- A re-install, watched second by second on 2026-10-28:
  - Everything runs inside WD's installer process, `upload_apkg -r <file> -f`
    (`/usr/sbin/upload_apkg`).
  - WD writes the installed `apkg.xml` itself, filling in `inst_date` and
    `path`. Run App comes from the new package, which says 0.
  - `upload_apkg` exits about two seconds after `init.sh`.
  - The apps page calls `cgi_apps_load_appinfo` when it loads, which rebuilds
    the app list (`/tmp/apkg_all.xml`) from the `apkg.xml` files. The page
    reads `/xml/apkg_all.xml` (`/var/www/xml/apkg_all.xml`).
  - `apkg.sign` is checked at upload only. WD itself rewrites `<enable>` in
    `apkg.xml` on every Run App click.
- So, once `upload_apkg` has exited, the apps store `<enable>1</enable>` in
  their `apkg.xml` again if they were ON before the upgrade. They use
  `cgi_apps_set` only when the dashboard's list still disagrees.
- The dialog's record, `/var/www/xml/apkg_state.xml` (mode 666), looks like
  this while it's installing:

  ```xml
  <?xml version="1.0" encoding="UTF-8" ?>
  <config>
  <install_type>1</install_type>
  <install_status>100</install_status>
  <install_filename>MyCloudEX2Ultra_tailscale_1.104.4-3.bin</install_filename>
  <name>tailscale</name>
  <dep_apps></dep_apps>
  </config>
  ```

  At the end, `upload_apkg` writes its result (1) to `/tmp/upload_apkg_status`
  and `/tmp/apkg_state.xml`, and then to this record. In the probe's hang,
  `/tmp/upload_apkg_status` said 1, `/tmp/apkg_state.xml` was missing, and
  the record stayed at 100. From 1.104.4-4 and 4.1.4-7, the apps check after
  an upgrade while ON, once `upload_apkg` has exited. If its result is 1 and
  their own record still says 100, they write the 1 there. They never write
  a result WD didn't record, and never touch another app's record.

## Dashboard

- With `CenterType: 0`, the dashboard loads the icon (`/<pkg>/<Icon>`),
  `desc.xml` (`/<pkg>/desc.xml`, used as the description text) and the
  Configure page (`/<pkg>/<AddonIndexPage>`, opened in a new tab) from
  `/var/www/<pkg>/`. `init.sh` must link the web files there.
- With `CenterType: 1` the same files come from `/var/www/apps/<pkg>/` and the
  page opens inside the dashboard: `go_sub_page()` (`/var/www/web/home.php`)
  fetches `/apps/<pkg>/<AddonIndexPage>` and inserts the HTML into its own
  page with jQuery, running its scripts there, then calls `page_load()`. It
  calls `page_unload()` before leaving. A page that doesn't define both gets
  the previous page's. These apps' `index.html` is just an iframe holding
  their own page, plus empty versions of both functions.
- The Configure button is greyed out while the app is OFF.
- `desc.xml` is read by `get_app_desc()` (`/var/www/web/function/app_menu.js`),
  which takes the text of the tag for the dashboard's language and nothing
  else: with no tag for it, the description is empty. Its 18 languages, by
  index: `en-US fr-FR it-IT de-DE es-ES zh-CN zh-TW ko-KR ja-JP ru-RU pt-BR
  cs-CZ nl-NL hu-HU no-NO pl-PL sv-SE tr-TR` (checked 2026-11-07). Both
  apps' `desc.xml` have all 18, and `tests/run-all.sh` checks it.

## Alerts

Checked on 5.33.102 (2026-11-07), read-only:

- `/usr/sbin/fireAlert` raises the alerts the dashboard shows under its bell
  icon and e-mails when alert e-mails are set up:
  `fireAlert -a <code> -p "<param1>,<param2>" -f` raises one, `-g` lists them,
  `-s <seq> -r` removes one, `-a <code> -x` removes all with that code.
  `sendAlert.sh` doesn't exist here.
- The codes and their texts are in `/etc/nas/alert-param.sh` and
  `/etc/nas/strings/<language>/alertmessages.txt`. None takes free text alone.
  The only one for apps is 1501, `appUpdateAvailable`: title "App Update
  Available", text "A new version of the following app(s) has been released.
  Please update the app(s) at your earliest convenience.%1". The Tailscale
  app uses it, with its own text as `%1`.
- `-g` prints each alert as `---->[item N]`, then `alertCode = …`,
  `alertSeqNum = …`, `alertMSG:[…]`, `alertDesc:[…]` (with `%1` filled in),
  `alertTime:[…]` and `counts:[…]`. So an app can find and remove its own
  alerts by their text, leaving other apps' 1501 alerts alone.
- The parameter is split at commas. From another OS5 Tailscale app
  (la32094uf/mycloud-tailscale), not checked here yet: WD drops a text longer
  than about 124 characters or holding `<`, `>` or `&`, and counts a repeat of
  the same code instead of showing its new text.

## Kernel

- No iptables `nat` table (`iptables -t nat -L` exits 3: "Table does not
  exist"), for IPv4 or IPv6 (checked 2026-11-07). tailscaled's default
  netfilter mode then fails to add its NAT chain and says so in a health
  warning. The Tailscale app passes `--netfilter-mode=off
  --snat-subnet-routes=false` instead (checked: `tailscale set`, `up` and
  `login` 1.104.4 all take both).

## Web server

Checked on 5.33.102 (2026-10-28), with requests for files that don't exist:

- `nasAdmin` (WD's own server, `/etc/nasAdmin.toml`) listens on ports 80 and
  8543 and proxies to Apache, which only accepts local connections
  (`Require local`). Apache hands `*.php` anywhere under `/var/www` to
  php-fpm (PHP 7.4), and **php-fpm runs as root**.
- Without a dashboard login, nasAdmin answers 403 for `/apps/…`, `/web/…` and
  `/cgi-bin/…`, but passes `/<pkg>/…` (the `CenterType: 0` folder) straight
  to Apache. Anyone who can reach the NAS can load those files, and a `.php`
  there would run as root with no login. Put any page that changes something
  under `/var/www/apps/<pkg>/` (`CenterType: 1`) only.
- WD's `login_check()` (`/var/www/web/lib/login_checker.php`) always returns
  1: nasAdmin checks the login, not PHP.
- nasAdmin cleans odd paths before its login check: `//./apps/...`,
  `/./apps/...`, `/x/../apps/...` and `//apps/...` get a 301 to the clean
  `/apps/...`, and `/%61pps/...` is decoded and refused like `/apps/...`.
- The dashboard's own AJAX helper (`wd_ajax`) adds no CSRF header, and the
  PHP 7.4 there has `json`, `mbstring` and `proc_open`.
- Apache loads ModSecurity (`security2`, `SecRuleEngine On`) with its audit
  log off (`SecAuditEngine Off`), so request bodies aren't written to disk.
- There's no `/dev/stdin` (use `/proc/self/fd/0`) and no `sha1sum`;
  `/usr/sbin/openssl` exists.

## Packaging facts

- `.bin` = 204-byte header (magic `GrandTeZ`, payload length in the last
  4 bytes, little-endian) + tar.gz of the `<pkg>/` folder. The 200 bytes on the
  wdpksrc wiki is the OS3 figure.
- `mksapkg-OS5 -s -m MyCloudEX2Ultra` output installs fine; `-E` was not needed.
- WD's toggle helper `addons_follow-up.sh` (called by `apkg_mgr.cgi`) does not
  exist on this firmware; the daemon does the work.
