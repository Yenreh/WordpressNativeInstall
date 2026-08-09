# AGENTS.md

Host-based (non-Docker) WordPress provisioning for Ubuntu 24.04. No application
code, build system or tests — bash scripts, an nginx template and a config
template. `README.md` has the full picture; this file records only what is easy
to get wrong.

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
- `bin/console <command>` — operations on an installed site. Some subcommands
  need root (`permissions`, `nginx`, `reload`, `ssl-renew`).

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
  `sudo` inside them.
- English only, no emojis, in code, comments, docs and commit messages.

## Configuration is derived, not repeated

`derive_site_config` (`lib/config.sh`) computes `NGINX_SITE_NAME`, `PHP_FPM_SOCK`,
`PHP_FPM_SERVICE`, `SSL_CERT`/`SSL_KEY`, `NGINX_CONF_FILE`, `NGINX_ENABLED_LINK`,
`ACCESS_LOG`, `ERROR_LOG`, `SITE_URL`, `WEB_USER`/`WEB_GROUP`. Add derived values
there — do not add fields to the config template that can be computed.

## nginx template

`nginx/site.conf.tpl` uses `{{TOKEN}}` placeholders rendered by `render_template`
(pure bash string replacement, so passwords and slashes are safe). Tokens:
`{{DOMAIN}} {{DOCROOT}} {{PHP_FPM_SOCK}} {{SSL_CERT}} {{SSL_KEY}} {{ACCESS_LOG}}
{{ERROR_LOG}} {{CLIENT_MAX_BODY_SIZE}}`. `$host`, `$uri`, `$document_root` etc.
are **nginx variables** — leave them alone.

`NGINX_MODE` decides the layout: `nginxorg` -> `/etc/nginx/conf.d/<site>.conf`,
`ubuntu` -> `sites-available` + symlink. The installer removes the file the other
mode would have created, and in `nginxorg` mode rewrites the `user nginx;`
directive in `/etc/nginx/nginx.conf` to `www-data` so the workers can reach the
PHP-FPM socket.

## Verifying changes

```sh
bash -n bin/* lib/*.sh
shellcheck bin/* lib/*.sh          # if installed
bash bin/new-site test.local --path /tmp/wp && bash bin/console --config sites/test.local.env info
rm -f sites/test.local.env
```

Anything beyond that needs a real Ubuntu host with MariaDB; do not try to run
the installer to "check" it.

## Out of scope

Docker deployments. `examples/wordpress-docker-fpm.sh` is a legacy reference
only — it does not read `sites/*.env` and is not maintained. The maintained
Docker stack lives in the separate `General-Wordpress-Site` repository.
