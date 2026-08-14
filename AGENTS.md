# AGENTS.md

WordPress provisioning driven by one config file per site, in two modes:
production on the host (Ubuntu 24.04, `bin/install-wordpress`) and development
in Docker (`bin/dev`). No application code, build system or tests — bash
scripts, an nginx template, a compose file and a config template. `README.md`
has the full picture; this file records only what is easy to get wrong.

**The database is external in both modes.** Nothing here ever starts a database
container, and `bin/dev` deliberately has no `db` service. If a change would
introduce one, that is a design change, not a fix.

The two modes use opposite database models on purpose. Production: one dedicated
user per database, created by `bin/install-wordpress` as MariaDB root, granted
only on its own schema. Development: a single connection account reused across
sites, expected to hold `CREATE`, so `bin/dev up` creates a missing database
itself (`DEV_DB_AUTOCREATE`, default `true`) and no user is ever created or
dropped. Do not "unify" them.

## Hard rule: credentials never enter the repository

- Real site configs live in `sites/<domain>.env` (gitignored, mode 600) and hold
  `WP_ADMIN_PASSWORD` and `DB_PASSWORD`.
- `config/site.env.example` is the only committed config and must keep
  `CHANGEME` placeholders; `validate_site_config` in `lib/config.sh` rejects any
  value starting with `CHANGEME`.
- Never print passwords in script output (the installer summary deliberately
  points at the config file instead), never write a site config anywhere outside
  `sites/`, and never `git add -f` anything under `sites/` or `backups/`.

## Entry points

All executables live in `bin/` and take `--config sites/<domain>.env`. When
`sites/` contains exactly one config the flag can be omitted (`resolve_site_config`).

- `bin/new-site <domain>` — generates a site config with random passwords. Not root.
- `bin/check-prerequisites` — verifies/installs nginx, PHP, WP-CLI, base utils.
  **Root.** Two phases: check everything, then install after confirmation.
  MariaDB is only verified, never installed.
- `bin/install-wordpress` — provisions one site end to end. **Root.**
  `--nginx-only` re-renders just the nginx site config (used by `console nginx`).
- `bin/console <command>` — operations on a host install. Some subcommands
  need root (`permissions`, `nginx`, `reload`, `ssl-renew`).
- `bin/dev <command>` — Docker development stack. Never root; it adds `sudo` to
  the Docker calls itself when the user is not in the `docker` group.

## Development stack

- Requires **Compose v2** (`docker compose`). v1 is not supported: the compose
  file uses `profiles` and the Compose Spec, and carries no `version:` key.
- `docker/compose.dev.yml` is only ever invoked through `bin/dev`, which exports
  the `DB_*`/`DEV_*` variables it interpolates. Running `docker compose` against
  it by hand yields empty substitutions.
- Services: `wordpress` (apache image, the only one `up` starts) and `cli`
  (`wordpress:cli`, in the `cli` profile, started per invocation by
  `docker compose --profile cli run --rm -T cli`).
- The container reaches the external database through `DEV_DB_HOST`, derived in
  `derive_dev_config`: a loopback `DB_HOST` becomes `host.docker.internal`
  (mapped via `extra_hosts: host-gateway`), anything else is passed through.
- Extra plugin/theme bind mounts cannot be expressed in a static compose file,
  so `write_override` in `bin/dev` generates `dev/<domain>/compose.override.yml`
  from `DEV_PLUGIN_DIRS`/`DEV_THEME_DIRS` on every run. `dev/` is gitignored;
  never hand-edit the generated file.
- The document root defaults to a **named volume** (`DEV_WP_SOURCE=wp_data`);
  `DEV_DOCROOT=/abs/path` switches the same compose entry to a bind mount.
- Containers run as the invoking human (`DEV_UID`/`DEV_GID`, taken from
  `SUDO_UID`/`SUDO_GID` when present). apache picks it up via
  `APACHE_RUN_USER`/`APACHE_RUN_GROUP` — the `#` prefix means "numeric id" and
  the php-apache image rewrites `envvars` so those variables are honoured — and
  the cli service through `user:`. Removing this reintroduces uid-33 files in a
  bind-mounted docroot and `Unable to create directory` warnings on install.
- `wp_cli` passes `wp` explicitly to `docker compose run`: the image entrypoint
  only prepends it when `wp help <arg>` succeeds, which fails for some
  subcommands (`db check` died as `exec: db: not found`).

## Conventions that matter

- `lib/common.sh` and `lib/config.sh` are **sourced, not executed**, and both
  guard against double sourcing. `lib/config.sh` requires `REPO_ROOT` to be set
  before it is sourced.
- Every script sets `REPO_ROOT` from `BASH_SOURCE`, so they work from any cwd.
- `bin/check-prerequisites` intentionally runs with `set -uo pipefail` **without**
  `-e` during the check phase (probing a missing package returns non-zero);
  `set -e` is enabled inside `do_install`. The other scripts use `set -euo pipefail`.
- Use the shared helpers instead of raw `echo`: `banner`, `section`, `step`,
  `ok`, `info`, `warn`, `err`, `die`, `confirm`, `require_root`, `require_cmd`.
- `confirm` honours `ASSUME_YES` (`--yes`), so every prompt is skippable for
  unattended runs. Any new prompt must go through it.
- `db_root` picks `mariadb` or `mysql`; scripts already run as root, so no
  `sudo` inside them. Anything that connects **as the site user** goes through
  `db_as_user <client>` (`db_client` / `db_dump_client` name the binary): it
  writes the credentials to a temporary 0600 defaults file, because `-p<pass>`
  on the command line is readable through `ps` by any local user. Never
  reintroduce `-p"$DB_PASSWORD"`, and never put a password in a `-e` statement.
- English only, no emojis, in code, comments, docs and commit messages.

## Configuration is derived, not repeated

`derive_site_config` (`lib/config.sh`) computes `NGINX_SITE_NAME`, `PHP_FPM_SOCK`,
`PHP_FPM_SERVICE`, `SSL_CERT`/`SSL_KEY`, `NGINX_CONF_FILE`, `NGINX_ENABLED_LINK`,
`ACCESS_LOG`, `ERROR_LOG`, `SITE_URL`, `WEB_USER`/`WEB_GROUP`, then calls
`derive_dev_config` for the `DEV_*` set. Add derived values there — do not add
fields to the config template that can be computed.

`_REQUIRED_VARS` covers production fields only. Every `DEV_*` value is optional
by design: a config written before the dev stack existed still works.

## WP_WRITE_MODE (production file ownership)

`derive_write_mode` in `lib/config.sh` turns one switch into ownership, modes and
wp-config constants. **Do not split it into independent knobs**: `FS_METHOD=direct`
over files PHP cannot write is a broken state that ends in wp-admin asking for
FTP credentials.

- `locked` (default): owner `WP_OWNER_USER` (root) group `WEB_GROUP`, only
  `WP_WRITABLE_PATHS` (default `wp-content/uploads`) belongs to `WEB_USER`,
  wp-config gets `DISALLOW_FILE_MODS`. Updates run through `bin/console wp` as
  root — which also means WordPress background security updates are off, so the
  installer prints the commands to schedule.
- `dashboard`: `WEB_USER` owns everything, `FS_METHOD=direct`, `wp-content`
  group-writable. Prior behaviour of this repo, now opt-in.

`bin/console permissions` is the single implementation; `bin/install-wordpress`
shells out to it. `bin/new-site --write-mode` writes the value into the config;
`bin/install-wordpress --write-mode` overrides it for one run by exporting
`WP_WRITE_MODE_OVERRIDE`, which `load_site_config` applies **after** sourcing the
config (a plain variable would be overwritten by `source`) and which the spawned
`console` process inherits. `bin/dev` ignores all of this: dev containers run as
the invoking user.

## nginx template

`nginx/site.conf.tpl` uses `{{TOKEN}}` placeholders rendered by `render_template`
(pure bash string replacement, so passwords and slashes are safe). Tokens:
`{{DOMAIN}} {{SITE_KEY}} {{DOCROOT}} {{PHP_FPM_SOCK}} {{SSL_CERT}} {{SSL_KEY}}
{{ACCESS_LOG}} {{ERROR_LOG}} {{CLIENT_MAX_BODY_SIZE}}`. `$host`, `$uri`,
`$document_root` etc. are **nginx variables** — leave them alone.

`{{SITE_KEY}}` is `NGINX_SITE_NAME` and exists to name the per-site
`limit_req_zone` for `wp-login.php`. The zone is declared at http level (the
rendered file is included there in both modes); two sites sharing a zone name
would break `nginx -t`.

**Location order is security-relevant.** nginx stops at the first matching regex
location, so the `deny` blocks for `wp-content/uploads/*.php`, the metadata
files and dotfiles must stay ABOVE `location ~ \.php$` — below it they are dead
config while looking perfectly fine. `location = /wp-login.php` duplicates the
fastcgi block on purpose (an exact match beats every regex, and that is how the
rate limit is applied to it alone); keep the two copies in sync. Any location
that defines its own `add_header` loses the server-level security headers and
must repeat them.

`NGINX_MODE` decides the layout: `nginxorg` -> `/etc/nginx/conf.d/<site>.conf`,
`ubuntu` -> `sites-available` + symlink. The installer removes the file the other
mode would have created, and in `nginxorg` mode rewrites the `user nginx;`
directive in `/etc/nginx/nginx.conf` to `www-data` so the workers can reach the
PHP-FPM socket.

## Verifying changes

```sh
bash -n bin/* lib/*.sh
shellcheck bin/* lib/*.sh          # if installed
bash bin/new-site test.local --path /tmp/wp
bash bin/console --config sites/test.local.env info
bash bin/dev --config sites/test.local.env url        # needs no Docker
```

The compose file can be validated without a running daemon by exporting the
same variables `bin/dev` exports and running `docker compose ... config`.
Clean up with `rm -rf sites/test.local.env dev/test.local`.

Anything beyond that needs a real host: an Ubuntu machine with MariaDB for the
installer, Docker plus a reachable database for `bin/dev`. Do not run the
installer just to "check" it.

## Out of scope

`examples/wordpress-docker-fpm.sh` is a legacy reference only — it does not read
`sites/*.env` and is not maintained. A separate Docker deployment for
production lives in the `General-Wordpress-Site` repository; `bin/dev` here is
for local development, not for serving a site.
