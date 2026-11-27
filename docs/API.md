# DIET HTTP API

The DIET web interface is a single page (`/www/index.html`) on top of a CGI
script, `/www/cgi-bin/api` (POSIX shell). The same API can be used by scripts
and monitoring tools with an **access token**. This page documents it; the
source of truth is the header of `package/diet/src/www/cgi-bin/api`.

## Two entry points

| URL | Authentication | For |
|---|---|---|
| `https://<nas>/cgi-bin/api?a=<action>&…` | HTTP Basic, user `admin` (password chosen at first setup) | the web interface |
| `https://<nas>/api/v1/<action>?…` | `Authorization: Bearer <token>` | scripts, Prometheus, home automation |

Both run the same script with the same actions and answers. lighttpd checks
the Basic password; it lets `/api/v1/` through without it and rewrites it to
`/cgi-bin/v1?a=<action>&…` (a symbolic link to the API), which checks the
token itself (lighttpd's `mod_auth` has no Bearer scheme). A Bearer token is
refused on `/cgi-bin/api`, and Basic credentials are refused on `/api/v1/`.

Both are served over HTTPS only (port 80 redirects) and only to private
networks (`192.168.0.0/16`, `10.0.0.0/8`, `172.16.0.0/12`, `127.0.0.1`):
the API is not meant to be exposed to the Internet. The certificate is
self-signed (created at first boot): use `curl --cacert` with a copy of it
(`/etc/lighttpd/ssl/server.pem`) or `-k`.

## Access tokens

Created and revoked in **Services → API access tokens** (interface only: a
token can neither list, create nor revoke tokens).

- **Name**: letters, digits, space, `.`, `-`, `_`; 40 characters at most.
  It appears in the DIET log next to the actions done with the token
  (`… (192.168.1.20, token backup script)`).
- **Rights**: `read-only` (GET only: every POST is refused with 403) or
  `full` (everything the interface can do, actions included: reboot,
  users, SSH keys, system update…). Give Prometheus a read-only token.
- **Value**: `<id>.<secret>`, 8 + 32 letters and digits (about 190 bits of
  randomness). It is shown **once**, right after its creation. The NAS keeps
  only `id:name:rights:salt:SHA-256(salt secret):creation date` in
  `/etc/diet-tokens` (mode 600); the value is never written to a file or a
  log. Lost token: revoke it and create another one.
- **Revocation**: immediate (the file is read at each request).
- 20 tokens at most. The file is kept by system updates.

Each request with a token costs one `sha256sum` on the NAS (one process,
a few tens of milliseconds on its 280 MHz CPU); reads of the collector
cache (`status`, `all`, `storage`, …) stay cheap otherwise.

## Requests and answers

- **Action**: path segment of `/api/v1/<action>` (`[a-z_]+`), or `a=<action>`
  on `/cgi-bin/api`. Other parameters in the query string.
- **Language** of messages: `l=en` (default), `l=fr` or `l=de`.
- **Reads** are `GET` (or `HEAD`). Answers: JSON (`application/json`), or
  plain text for logs and reports. `Cache-Control: no-store` everywhere.
- **Actions** are `POST` with a form body
  (`application/x-www-form-urlencoded`, less than 4 KB, except
  `update_upload`) and the header **`X-Diet: 1`**, also with a token. The
  header is a CSRF guard: a form from another site cannot set it. Answer:
  `{"ok":true,"msg":"…"}` (some actions add fields).
- **Errors**: an HTTP status and a short plain-text message (in the chosen
  language), never JSON:

| Status | Meaning |
|---|---|
| 400 | invalid parameter, unknown action |
| 401 | missing, wrong or revoked token (`WWW-Authenticate: Bearer realm="DIET"`), or no Basic password on `/cgi-bin/api` |
| 403 | POST without `X-Diet: 1`; POST with a read-only token; token management through a token; `/metrics` turned off; client outside the private networks |
| 404 | unknown share, user, token, folder… |
| 409 | conflict with the current state (share exists, service stopped, X-RAID only, update in progress…); `reboot`, `poweroff`, `update_switch` while an update, a mirror check or a RAID repair runs (see below) |
| 413 | body too large |
| 500, 502 | the NAS could not apply it (write error, Telegram unreachable…) |

## Reads (GET)

| Action | Answer |
|---|---|
| `status` | host, version, model, IP, uptime, load, board temperature, fan, services, disks (temperature, SMART summary with the self-test state: `selftest` = last status nibble, 0 done or never run, 1 aborted, 2 interrupted, 3–8 failed, 15 running; `left` %, `short_min`/`long_min`; `null` without smart-lite), memory, `/c` usage, raw counters (CPU, network, disk), md arrays, `busy` (operations a restart would cut short) |
| `all` | `{"status":…, "storage":…, "hist":"…"}` (what the page loads first) |
| `storage` | X-RAID / md state from `nas-raid status --json`: mode, reasons, verify and quick check, superblock; Flex-RAID (modes `flexraid-ro`, `flexraid-rw`): `flexraid_mounts`, `flexraid_rw_mounts` and `flexraid.arrays` (levels `raid0`, `raid1`, `raid5`) (docs/XRAID.md §10); plus `layout` (below) |
| `config` | spin-down and fan curve |
| `sys` | name, language, time zone, network, Telegram set, SSH, SMB3 encryption, `metrics` (0 off, 1 token, 2 open) |
| `shares`, `users`, `nfs`, `services` | lists for the Shares page |
| `update` | system update slots and job |
| `hist` | text: monitor history (time, temperature, rpm, PWM), about 12 h |
| `log&f=diet\|messages\|dmesg\|storage\|update` | text: last 300 lines |
| `smart&d=sda` | text: `smartctl` report (or drivetemp and kernel messages) |
| `md&d=md0` | text: `mdadm --detail` |
| `metrics` | Prometheus text format (docs/DIET.md "Prometheus"); through a token only when `/metrics` is on |
| `tokens` | list of tokens (id, name, rights, date); interface only |

`storage.layout` describes the volume the same way whatever the number of
bays, for the page and for scripts; it is computed from the `xraid` object
(xraid-info) and `/proc/mdstat`, the other keys are unchanged:

```json
"layout": {"level": "raid1",
           "members": [{"bay": 1, "dev": "sda", "role": "mirror", "state": "online"},
                       {"bay": 2, "dev": "sdb", "role": "base", "state": "online"}],
           "rebuild": null}
```

- `level`: `raid` + the level of the X-RAID sections (`raid1` on the Duo).
- `members`: one per bay of the volume (bay = X-RAID channel + 1), in bay
  order; `role` is `base`, `mirror` or empty; `state` is `online`, `failed`
  (faulty or unknown), `rebuilding` (spare, ready) or `missing` (a channel of
  the superblock without a disk: `dev` and `role` empty).
- `rebuild`: whole percentage of an md resync/recovery/reshape running in
  `/proc/mdstat`, otherwise `null`.
- `layout` is `null` without an X-RAID superblock and in Flex-RAID mode (its
  arrays are in `storage.flexraid`).

`status`, `all`, `storage`, `services`, `shares`, `nfs`, `sys`, `users` and
`config` come from the collector cache when it is fresh (docs/DIET.md
"Speed"); the first read after an action is computed directly.

## Actions (POST, `X-Diet: 1`)

| Action | Body |
|---|---|
| `spindown`, `ksmbd`, `nfsd`, `ntp`, `notify_test`, `dlna_scan` | none |
| `smart_test` | `d=sda`, `t=short\|long\|abort`: starts (or aborts) a SMART self-test inside the disk; 409 with the disk's reason if refused (test already running, no self-test support) |
| `reboot`, `poweroff` | none; `force=1&confirm=FORCE` to override a 409 (below) |
| `config` | any of `SPINDOWN_MIN FAN_PWM_MIN FAN_PWM_MAX TEMP_LOW TEMP_HIGH DISK_HIGH DISK_CRIT PERIOD` |
| `share_add`, `share_del` | `name` |
| `share_set` | `name`, `ro=0\|1`, `guest=0\|1` |
| `user_set` | `name`, `pw` (creates or changes the password) |
| `user_del` | `name` |
| `nfs_add` | `path=/c/…`, `client=*\|a.b.c.d\|a.b.c.d/nn`, `ro=0\|1` |
| `nfs_del` | `path`, `client` |
| `sys_set` | `host`, `lang`, `tz`, `net=dhcp\|static`, `ip`, `mask`, `gw`, `dns`, `tgtoken`, `tgchat` (all fields: it rewrites the settings) |
| `ssh_set` | `rootpw` and/or `key` (one public key) |
| `smb_enc` | `on=0\|1` |
| `smb_sign` | `v=auto\|mandatory` (`server signing` of ksmbd.conf, ksmbd restarted; `auto`: signed only for clients that require it, `mandatory`: every client signs; read back as `smbsign` in `sys`) |
| `metrics_set` | `on=0\|1`, `open=0\|1` (restarts lighttpd) |
| `svc_set` | `s=smb\|minidlna\|avahi\|rsync\|webdav\|nfs`, `on=0\|1` (`smb`: ksmbd, `SVC_SMB` in diet.conf; `services` answers `smb:{on,run}`, `status` answers `smb_on`) |
| `dlna_set` | `name`, `dirs` (one folder per line) |
| `rsync_pw` | `pw` |
| `rsync_c` | `on=0\|1` |
| `raid_verify`, `raid_quick` | none (start a mirror check) |
| `raid_quick_accept` | `confirm=ACCEPT`, `yes=1` |
| `xraid_rw` | `on=0`, or `on=1&confirm=WRITE&yes=1` |
| `flexraid_rw` | the same for `FLEXRAID_RW` (Flex-RAID RAID 1, RAID 5 and RAID 0 volumes, docs/XRAID.md §10); 409 outside the Flex-RAID modes |
| `update_upload` | the update package as the raw body |
| `update_url` | `url`, `sha` (SHA-256 of the package) |
| `update_switch` | none; `force=1&confirm=FORCE` to override a 409 (below) |
| `update_cancel` | none |
| `token_add`, `token_del` | `name` and `perm=ro\|full` / `id`; interface only |

Text values are URL-encoded (`curl --data-urlencode`).

**Protections.** `reboot`, `poweroff` and `update_switch` are refused with
**409** and a message naming the reason while a system update job runs, a
full or quick mirror check runs, or an md resync/repair is in progress
(docs/DIET.md "Protections"). The same reasons are listed in the `busy` array
of `status` (`update`, `verify`, `quick`, `sync`; empty when nothing runs).
To go ahead anyway, add both `force=1` and `confirm=FORCE` (the word in
capitals, in English); the forced action is logged. Example:
`curl -X POST -H 'X-Diet: 1' -H "Authorization: Bearer $T" -d 'force=1&confirm=FORCE' https://nas/api/v1/reboot`

## Examples

    NAS=https://nas.local
    TOKEN=$(cat ~/.config/diet-token)          # never on the command line of a shared machine
    H="Authorization: Bearer $TOKEN"

    # read: status, as JSON
    curl -sk -H "$H" $NAS/api/v1/status | jq '.uptime, .temp, .c'

    # a log, in French
    curl -sk -H "$H" "$NAS/api/v1/log?f=diet&l=fr"

    # action (full token): spin the disks down
    curl -sk -X POST -H "$H" -H 'X-Diet: 1' $NAS/api/v1/spindown

    # action with parameters: a read-only share
    curl -sk -X POST -H "$H" -H 'X-Diet: 1' -d 'name=media&ro=1&guest=1' $NAS/api/v1/share_set

    # the same through the interface entry point, with the administrator password
    curl -sk -u admin -X POST -H 'X-Diet: 1' "$NAS/cgi-bin/api?a=spindown"

    # what an error looks like
    curl -sk -i -X POST -H "$H" $NAS/api/v1/spindown     # 403: X-Diet missing

Keep tokens out of shell history and process lists where others can read
them (a file, `curl -H @file`, or an environment variable).
