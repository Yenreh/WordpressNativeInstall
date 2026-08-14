# WordPress Installer

Reproducible provisioning of WordPress sites, in two modes driven by the same
per-site configuration file:

| Mode            | Command                 | What runs where                                                |
|-----------------|-------------------------|----------------------------------------------------------------|
| **Production**  | `bin/install-wordpress` | Everything on the host: PHP-FPM, nginx, TLS. Ubuntu 24.04 LTS. |
| **Development** | `bin/dev`               | WordPress in Docker. No PHP and no nginx on the host.          |

```
production   browser --443--> nginx (host, TLS + static files)
                                 |  unix socket, *.php only
                                 v
                             PHP-FPM  -->  MariaDB (host or remote)

development  browser --8080--> wordpress:php8.3-apache container
                                 |  host.docker.internal
                                 v
                             MariaDB (host or remote)
```

In **both** modes the **database is external**: no database container is ever
started, and the credentials come from the site config.

One repository provisions many sites. Everything a site needs lives in a single
file, `sites/<domain>.env`, which is **gitignored**: no credential ever reaches
the repository.

---

## Repository layout

| Path                      | Purpose                                                           |
|---------------------------|-------------------------------------------------------------------|
| `bin/new-site`            | Creates `sites/<domain>.env` with generated passwords (mode 600). |
| `bin/check-prerequisites` | Verifies and installs the host stack (nginx, PHP, WP-CLI, utils). |
| `bin/install-wordpress`   | Provisions one site end to end from its config file.              |
| `bin/console`             | Day-to-day operations on a host install.                          |
| `bin/dev`                 | Development stack in Docker.                                      |
| `docker/compose.dev.yml`  | Compose file for the dev stack. Driven only by `bin/dev`.         |
| `lib/common.sh`           | Logging, prompts, template rendering, passwords, DB clients.      |
| `lib/config.sh`           | Locates, loads, validates and derives the site configuration.     |
| `nginx/site.conf.tpl`     | nginx site template (`{{TOKEN}}` placeholders).                   |
| `config/site.env.example` | Documented template for a site config. **Only committed copy.**   |
| `sites/`                  | Real site configs — **gitignored, contains credentials**.         |
| `examples/`               | Legacy Docker-based script, kept for reference only.              |

## Prerequisites

**Production** — Ubuntu 24.04 LTS with root, and MariaDB >= 11.4 already
installed, running and reachable as root over the local socket
(`sudo mariadb -e 'SELECT 1;'`). MariaDB is the one component the scripts never
install; `bin/check-prerequisites` prints the exact commands when it is missing
and installs everything else (nginx from nginx.org, PHP-FPM + extensions,
WP-CLI, base utilities).

**Development** — Docker with the Compose **v2** plugin, plus a reachable
MariaDB/MySQL server. Nothing else: no PHP, no nginx, no WP-CLI on the host.

---

## Quick start — production

```sh
# 1. Create the site config (random passwords, mode 600, gitignored).
bash bin/new-site example.com --title "My Site" --email admin@example.com

# 2. Review it — domain, paths, DB name, PHP version, nginx mode, write mode.
$EDITOR sites/example.com.env

# 3. Verify (and install) the host stack.
sudo bash bin/check-prerequisites --config sites/example.com.env

# 4. Provision the site.
sudo bash bin/install-wordpress --config sites/example.com.env

# 5. Check the result.
bash bin/console --config sites/example.com.env status
```

Step 4 creates the database and its dedicated user, downloads WordPress, writes
`wp-config.php`, runs the installer, applies ownership and file modes, generates
a self-signed certificate, renders the nginx site config and reloads nginx and
PHP-FPM.

When `sites/` holds exactly one config, `--config` can be omitted. With several
sites, pass it explicitly or export `WP_SITE_CONFIG`.

## Quick start — development

```sh
bash bin/new-site example.com                  # same config file as production
bash bin/dev --config sites/example.com.env up # start + install on first run
```

`up` starts the container, waits for the core files, checks (and by default
creates) the database, installs WordPress if needed and prints the URL —
`http://localhost:<DEV_HTTP_PORT>`.

---

## Command reference

Every script takes `--config sites/<domain>.env` (`-c`) and `--help` (`-h`).
Scripts that prompt also take `--yes` (`-y`) to answer every prompt.

### `bin/new-site <domain>`

Writes `sites/<domain>.env`. Never root.

| Flag              | Effect                                                            |
|-------------------|-------------------------------------------------------------------|
| `--title`         | Site title. Default: the domain.                                  |
| `--email`         | Admin email. Default: `admin@<domain>`.                           |
| `--locale`        | WordPress locale. Default `en_US`.                                |
| `--path`          | Document root. Default `/apps/wordpress/<domain>/html`.           |
| `--nginx-mode`    | `nginxorg` (default) or `ubuntu`.                                 |
| `--php-version`   | Default `8.3`.                                                    |
| `--dev-port`      | Host port for the dev stack. Default: first free from 8080.       |
| `--dev-docroot`   | Dev document root. Default `dev/<domain>/html` inside the repo.   |
| `--random-prefix` | Per-site table prefix (`wp_k3af_`) instead of `wp_`.              |
| `--write-mode`    | `locked` (default) or `dashboard`. See [File ownership](#file-ownership-wp_write_mode). |
| `--force`         | Overwrite an existing config.                                     |

```sh
bash bin/new-site shop.example.com \
  --title "Shop" --locale es_ES --php-version 8.3 \
  --nginx-mode ubuntu --dev-port 8081 --random-prefix
```

### `bin/check-prerequisites`

Two phases: check everything and print a summary, then install what is missing
after confirmation. **Root.**

| Flag              | Effect                                                     |
|-------------------|------------------------------------------------------------|
| `--php-version`   | PHP version to check/install. Default `8.3`.               |
| `--nginx-branch`  | `stable` (default, 1.30.x) or `mainline`.                  |
| `--check-only`    | Report only, install nothing (exits non-zero if anything is missing). |

```sh
sudo bash bin/check-prerequisites --check-only
sudo bash bin/check-prerequisites --php-version 8.4 --nginx-branch mainline --yes
```

### `bin/install-wordpress`

Provisions one site end to end. Idempotent, and asks before every destructive
step. **Root.**

| Flag                | Effect                                                        |
|---------------------|----------------------------------------------------------------|
| `--skip-nginx`      | Leave the nginx configuration untouched.                       |
| `--skip-ssl`        | Leave `SSL_DIR` untouched (existing or external certificate).  |
| `--nginx-only`      | Only re-render and install the nginx site config, then reload. |
| `--write-mode`      | Override `WP_WRITE_MODE` for this run.                         |

```sh
sudo bash bin/install-wordpress --config sites/example.com.env
sudo bash bin/install-wordpress --skip-ssl --yes          # certbot cert already in place
sudo bash bin/install-wordpress --write-mode dashboard    # override the config file
```

### `bin/console <command>`

Day-to-day operations on a host install.

```sh
C="bash bin/console --config sites/example.com.env"

$C info                  # resolved configuration (no secrets)
$C status                # WordPress, services, nginx site, database, certificate
sudo $C permissions      # reapply ownership and file modes
sudo $C nginx            # re-render and install the nginx site config
sudo $C reload           # nginx -t, then reload nginx + PHP-FPM
sudo $C ssl-renew        # regenerate the self-signed certificate
$C db-dump [file]        # dump the database into backups/ (gitignored)
$C wp <args>             # any WP-CLI command against this site
```

```sh
$C wp plugin list
sudo $C wp core update --minor
$C db-dump /var/backups/example-$(date +%F).sql
```

### `bin/dev <command>`

Development stack in Docker. Never run as root; it adds `sudo` to the Docker
calls itself when your user is not in the `docker` group (`--no-sudo` refuses).

```sh
D="bash bin/dev --config sites/example.com.env"

$D up                 # start (and install on first run)
$D up --no-install    # start without touching the database content
$D status             # container, database reachability, WordPress state
$D logs [service]     # follow a container log (default: wordpress)
$D wp <args>          # WP-CLI in a throwaway container
$D shell [service]    # shell in a container (default: wordpress)
$D url                # print the local URL (works without Docker)
$D db-dump [file]     # dump the database into backups/
$D stop | restart     # stop / restart, keep everything
$D down               # remove container + network (volume preserved)
$D down --volumes     # also delete the WordPress files volume
```

`down --volumes` never touches the database: it is external.

---

## Configuration

A site config is a plain shell file sourced by the scripts. Only these values
are authored; everything else is derived.

```sh
SITE_DOMAIN="example.com"        # drives every derived name
SITE_TITLE="My Site"
SITE_LOCALE="en_US"
WP_VERSION="latest"              # or a pinned version, e.g. 6.7.2

WP_PATH="/apps/wordpress/example.com/html"
SSL_DIR="/apps/ssl/example.com"

WP_ADMIN_USER="wp_admin"
WP_ADMIN_EMAIL="admin@example.com"
WP_ADMIN_PASSWORD="..."          # generated by bin/new-site

DB_HOST="127.0.0.1"; DB_PORT="3306"
DB_NAME="wp_example_com"         # letters, digits and underscores only
DB_USER="wp_example_com"
DB_PASSWORD="..."                # generated by bin/new-site

PHP_VERSION="8.3"
NGINX_MODE="nginxorg"            # nginxorg | ubuntu
WP_WRITE_MODE="locked"           # locked | dashboard

DEV_HTTP_PORT="8080"             # dev only; bin/new-site picks a free port
```

Derived automatically: `NGINX_SITE_NAME` (domain with dots turned into dashes),
`PHP_FPM_SOCK`, `SSL_CERT`/`SSL_KEY`, the nginx config path, the log paths,
`SITE_URL`, the file-ownership values and the whole `DEV_*` set. Each can still
be overridden:

| Optional value                     | Default                                        |
|------------------------------------|------------------------------------------------|
| `DB_TABLE_PREFIX`                  | `wp_` (`--random-prefix` writes `wp_xxxx_`)    |
| `WP_WRITABLE_PATHS`                | `wp-content/uploads`, relative to `WP_PATH`    |
| `WP_OWNER_USER` / `WP_OWNER_GROUP` | `root` / `www-data` (locked mode)              |
| `WEB_USER` / `WEB_GROUP`           | `www-data`                                     |
| `NGINX_SITE_NAME`                  | domain, dots to dashes                         |
| `PHP_FPM_SOCK`                     | `/run/php/php<PHP_VERSION>-fpm.sock`           |
| `CLIENT_MAX_BODY_SIZE`             | `64M` (keep in sync with php.ini)              |
| `DEV_BIND_ADDR`                    | `127.0.0.1` (`0.0.0.0` exposes it to the LAN)  |
| `DEV_URL`, `DEV_PROJECT_NAME`      | from the domain and `DEV_HTTP_PORT`            |
| `DEV_WP_IMAGE`, `DEV_CLI_IMAGE`    | `wordpress:php<v>-apache`, `wordpress:cli`     |
| `DEV_DB_HOST`, `DEV_TABLE_PREFIX`  | see below / `DB_TABLE_PREFIX`                  |
| `DEV_DB_AUTOCREATE`                | `true`                                         |
| `DEV_DOCROOT`                      | empty, i.e. a Docker named volume              |
| `DEV_UID` / `DEV_GID`              | the invoking user (`SUDO_UID`/`SUDO_GID`)      |
| `DEV_PLUGIN_DIRS`, `DEV_THEME_DIRS`| empty                                          |

`config/site.env.example` documents every one of them in place.

### `NGINX_MODE`

| Value      | For nginx installed from | Site config path                              |
|------------|--------------------------|-----------------------------------------------|
| `nginxorg` | nginx.org (1.30.x)       | `/etc/nginx/conf.d/<site>.conf`               |
| `ubuntu`   | Ubuntu repos (1.24.x)    | `/etc/nginx/sites-available/<site>` + symlink |

In `nginxorg` mode the installer also switches the nginx worker user from
`nginx` to `www-data`, otherwise the workers cannot reach the PHP-FPM socket.

---

## Development stack

### The database is external

`bin/dev` starts no database container. It reuses `DB_HOST`, `DB_PORT`,
`DB_NAME`, `DB_USER` and `DB_PASSWORD` from the site config.

The two modes use **opposite database models**, on purpose:

| | Production | Development |
|---|---|---|
| Account | one dedicated user per database | one connection account reused by every local site |
| Privileges | `GRANT ALL ON <db>.*` only | needs `CREATE` (scope it to `` `wp\_%`.* ``) |
| Who creates the database | `bin/install-wordpress`, as MariaDB root | `bin/dev up`, with that same account |
| Rationale | blast radius: a compromised site cannot read the others | no user churn when spinning sites up and down |

So in dev you point every site at the same `DB_USER`/`DB_PASSWORD`, give each a
distinct `DB_NAME`, and `bin/dev up` creates the database the first time
(`DEV_DB_AUTOCREATE`, default `true`). Set it to `"false"` to require the
database to exist:

```sql
CREATE DATABASE `wp_example_com` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
GRANT ALL PRIVILEGES ON `wp_example_com`.* TO '<DB_USER>'@'%';
```

The account must reach the server **from the container**, so a grant limited to
`'user'@'localhost'` never works — use `'%'` or the Docker subnet. `DB_HOST` is
likewise interpreted from the container's point of view:

| `DB_HOST` in the config | Used by the container  | Meaning                   |
|-------------------------|------------------------|---------------------------|
| `127.0.0.1`/`localhost` | `host.docker.internal` | Server on the Docker host |
| anything else           | as is                  | Remote server             |

Override with `DEV_DB_HOST` when neither applies. Two things commonly block a
host database: `bind-address = 127.0.0.1` in the MariaDB config (the container
arrives over the Docker bridge, not over loopback), and a grant limited to
`'user'@'localhost'`. `bin/dev up` diagnoses both and stops before installing.

If dev and production share a database server, set `DEV_TABLE_PREFIX` (for
example `wpdev_`) so the two installs do not collide in the same schema.

### Developing plugins and themes

Mount local directories straight into `wp-content` from the site config:

```sh
DEV_PLUGIN_DIRS="/home/user/GIT/my-plugin:/home/user/GIT/other-plugin"
DEV_THEME_DIRS="/home/user/GIT/my-theme"
DEV_DOCROOT="/home/user/dev/example.com/html"   # browse the whole install
```

`bin/dev` renders the mounts into `dev/<domain>/compose.override.yml`
(gitignored) on every run. The containers run as **your** uid/gid, so
everything WordPress writes stays editable from the host and the
`Unable to create directory wp-content/uploads/...` warnings never appear.
Without `DEV_DOCROOT` the document root stays inside a Docker named volume.

---

## Production TLS

The generated certificate is self-signed (365 days). Replace it with Let's
Encrypt once DNS points at the server:

```sh
sudo apt install certbot python3-certbot-nginx
sudo certbot --nginx -d example.com
```

The `:80` server keeps `/.well-known/acme-challenge/` servable instead of
redirecting it, so an HTTP-01 renewal works without relying on the redirect.

certbot rewrites the `ssl_certificate*` lines in the site config. After that,
re-running `sudo bin/console nginx` would overwrite them with the self-signed
paths — set `SSL_DIR` to the certbot directory in the site config first, or skip
that command.

---

## Security model

- **No credential is ever committed.** `sites/*` is gitignored; the only
  committed template, `config/site.env.example`, carries `CHANGEME` placeholders
  that the loader rejects at runtime. `backups/` is gitignored as well.
- `bin/new-site` generates 24-character random passwords and writes the file
  with mode 600. The loader warns if a config is more permissive than that.
- Passwords are never printed: the installer summary points at the config file.
  They never reach a command line either — `-p<password>` is visible in `ps` to
  every local user, so clients read a temporary 0600 defaults file (`db_as_user`)
  and `CREATE USER` is fed through stdin.
- Applied to every site: `wp-config.php` mode 640, `DISALLOW_FILE_EDIT`,
  `WP_DEBUG` off, PHP execution denied under `wp-content/uploads`, `xmlrpc.php`
  and dotfiles denied, `wp-login.php` rate limited (30 r/m per IP, burst 5),
  `server_tokens off`, HTTP redirected to HTTPS, TLS 1.2/1.3 only.
- The **order** of the nginx `location` blocks is part of that: nginx stops at
  the first matching regex, so every `deny` on a `.php` path sits above the
  generic `location ~ \.php$`. Moving them below silently disables them.
- `DB_NAME` and `DB_USER` are validated as plain identifiers before being
  interpolated into statements that run as MariaDB root.
- The table prefix is `wp_` by default; `--random-prefix` writes a per-site one.
  Be clear-eyed about it: it only deflects canned payloads that hardcode `wp_`
  and stops nothing targeted, which is why it is opt-in. It must be chosen
  before installing — changing it later means renaming every table and fixing
  the `*_user_roles` and `*_capabilities` keys.

### File ownership: `WP_WRITE_MODE`

A production install is exposed to the internet, so by default the PHP worker
cannot modify a single line of the code it executes. The dev stack is
unaffected: it runs in Docker, on loopback, as your own user.

| | `locked` (default) | `dashboard` |
|---|---|---|
| Document root owner | `root:www-data`, dirs 755 / files 644 | `www-data:www-data`, `wp-content` group-writable |
| Writable by PHP | only `WP_WRITABLE_PATHS` | everything |
| wp-config constants | `DISALLOW_FILE_MODS`, `DISALLOW_FILE_EDIT` | `FS_METHOD=direct`, `DISALLOW_FILE_EDIT` |
| Updates | from the host, `bin/console wp` as root | from wp-admin |
| A file-write bug in a plugin | drops a file in uploads, where nginx refuses to execute PHP | rewrites the running code |

```sh
bash bin/new-site example.com --write-mode dashboard      # writes WP_WRITE_MODE
sudo bash bin/install-wordpress --write-mode locked ...   # override for one run
```

The cost of `locked` is real: `DISALLOW_FILE_MODS` also disables WordPress
automatic background security updates. Patch from the host instead, ideally from
cron:

```sh
C="bash bin/console --config sites/example.com.env"
sudo $C wp core update --minor
sudo $C wp plugin update --all
sudo $C permissions          # normalize what the update just wrote
```

To switch an installed site: edit `WP_WRITE_MODE`, re-run
`sudo bin/console permissions`, and set the constants accordingly
(`console wp config set DISALLOW_FILE_MODS true --raw`, or delete it and set
`FS_METHOD direct`). If a plugin genuinely needs to write outside uploads, add
its directory to `WP_WRITABLE_PATHS` rather than widening the whole tree.

---

## Verifying changes to the scripts

There is no build or test suite. After editing:

```sh
bash -n bin/* lib/*.sh                       # syntax check
shellcheck bin/* lib/*.sh                    # if available
bash bin/new-site test.local --path /tmp/wp  # throwaway config
bash bin/console --config sites/test.local.env info
bash bin/dev --config sites/test.local.env url        # needs no Docker
rm -rf sites/test.local.env dev/test.local
```

Rendering the nginx template without touching the system:

```sh
source lib/common.sh
render_template nginx/site.conf.tpl \
  'LISTEN_443=listen 443 ssl;' DOMAIN=example.com SITE_KEY=example-com \
  DOCROOT=/tmp/wp PHP_FPM_SOCK=/run/php/php8.3-fpm.sock \
  SSL_CERT=/tmp/c SSL_KEY=/tmp/k ACCESS_LOG=/tmp/a.log ERROR_LOG=/tmp/e.log \
  CLIENT_MAX_BODY_SIZE=64M
```

`$host`, `$uri` and friends in the output are nginx variables, not unresolved
placeholders. Anything beyond this needs a real host: an Ubuntu machine with
MariaDB for the installer, Docker plus a reachable database for `bin/dev`.
