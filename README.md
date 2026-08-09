# WordPress Installer

Reproducible provisioning of WordPress sites, in two modes driven by the same
per-site configuration file:

| Mode            | Command                 | What runs where                                                        |
|-----------------|-------------------------|------------------------------------------------------------------------|
| **Production**  | `bin/install-wordpress` | Everything on the host: PHP-FPM, nginx, TLS. Ubuntu 24.04 LTS.         |
| **Development** | `bin/dev`               | WordPress in Docker. No PHP and no nginx on the host.                  |

In **both** modes the **database is external**: MariaDB/MySQL runs on the host
or on another server and its credentials come from the site config. No database
container is ever started.

One repository can provision many sites. Everything a site needs lives in a
single file, `sites/<domain>.env`, which is **gitignored**: no credential ever
reaches the repository.

---

## Architecture — production (`bin/install-wordpress`)

```
                    +-----------------------------+
   browser  --->    | nginx (host)                |
   https://         |  :443 TLS                   |
   example.com      |  serves static files from   |
                    |  ${WP_PATH}                 |
                    |  forwards *.php over FastCGI|
                    +--------------+--------------+
                                   | unix socket
                                   v
                    +-----------------------------+
                    | PHP-FPM (php8.3-fpm)        |
                    | runs WordPress from         |
                    | ${WP_PATH}                  |
                    +--------------+--------------+
                                   |
                                   v
                    +-----------------------------+
                    | MariaDB (host)              |
                    | one database + one dedicated|
                    | user per site               |
                    +-----------------------------+
```

nginx terminates TLS and serves static assets itself; only `.php` goes to
PHP-FPM through `/run/php/php<version>-fpm.sock`. Each site gets its own
database, its own database user and its own certificate directory.

## Architecture — development (`bin/dev`)

```
                    +-----------------------------+
   browser  --->    | WordPress container         |
   http://          | wordpress:php8.3-apache     |
   localhost:8080   | 127.0.0.1:8080 -> :80       |
                    | docroot in a named volume   |
                    | (or a bind mount)           |
                    +--------------+--------------+
                                   | host.docker.internal
                                   v
                    +-----------------------------+
                    | External MariaDB/MySQL      |
                    | on the host or remote —     |
                    | NOT containerized           |
                    +-----------------------------+
```

A single container serves the site; WP-CLI runs on demand in a second,
short-lived container (`bin/dev wp ...`). The host only needs Docker.

---

## Repository layout

| Path                      | Purpose                                                              |
|---------------------------|----------------------------------------------------------------------|
| `bin/new-site`            | Creates `sites/<domain>.env` with generated passwords (mode 600).    |
| `bin/check-prerequisites` | Verifies and installs the host stack (nginx, PHP, WP-CLI, utils).    |
| `bin/install-wordpress`   | Provisions one site end to end from its config file.                 |
| `bin/console`             | Day-to-day operations on a host install.                             |
| `bin/dev`                 | Development stack in Docker (up, wp, logs, status, down).            |
| `docker/compose.dev.yml`  | Compose file for the development stack. Driven only by `bin/dev`.    |
| `lib/common.sh`           | Logging, prompts, template rendering, password generation.           |
| `lib/config.sh`           | Locates, loads, validates and derives the site configuration.        |
| `nginx/site.conf.tpl`     | nginx site template (`{{TOKEN}}` placeholders).                      |
| `config/site.env.example` | Documented template for a site config. **Only committed copy.**      |
| `sites/`                  | Real site configs — **gitignored, contains credentials**.            |
| `examples/`               | Legacy Docker-based script, kept for reference only.                 |

---

## Prerequisites

**Production mode**

- Ubuntu 24.04 LTS with root access.
- MariaDB >= 11.4 already installed, running, and reachable as root over the
  local socket (`sudo mariadb -e 'SELECT 1;'`). This is the one component the
  scripts never install for you — `bin/check-prerequisites` prints the exact
  commands if it is missing.
- Everything else (nginx from nginx.org, PHP-FPM + WordPress extensions,
  WP-CLI, base utilities) is installed by `bin/check-prerequisites`.

**Development mode**

- Docker with the Compose **v2** plugin (`docker compose`). Nothing else: no
  PHP, no nginx, no WP-CLI on the host.
- A reachable MariaDB/MySQL server with the database and user already created
  (see [Development stack](#development-stack-bindev)).

---

## Quick start — production

```sh
# 1. Create the site config (generates strong random passwords, mode 600).
bash bin/new-site example.com --title "My Site" --email admin@example.com

# 2. Review it — domain, paths, DB name, PHP version, nginx mode.
$EDITOR sites/example.com.env

# 3. Verify (and install) the host stack.
sudo bash bin/check-prerequisites --config sites/example.com.env

# 4. Provision the site.
sudo bash bin/install-wordpress --config sites/example.com.env

# 5. Check the result.
bash bin/console --config sites/example.com.env status
```

Step 4 creates the database and its dedicated user, downloads WordPress, writes
`wp-config.php`, runs the installer, fixes permissions, generates a self-signed
certificate, renders the nginx site config and reloads nginx and PHP-FPM.

When `sites/` holds exactly one config, `--config` can be omitted. With several
sites, pass it explicitly or export `WP_SITE_CONFIG`.

---

## Development stack (`bin/dev`)

Runs the site locally in Docker. Useful when the machine has no PHP and you do
not want to install one.

```sh
bash bin/new-site example.com          # same config file as production
bash bin/dev --config sites/example.com.env up
```

`up` starts the container, waits for the WordPress core files, checks the
database connection and runs the installer if the site is not installed yet.
The URL is printed at the end (`http://localhost:<DEV_HTTP_PORT>`).

```sh
D="bash bin/dev --config sites/example.com.env"

$D up                 # start (and install on first run)
$D up --no-install    # start without touching the database content
$D status             # containers, database reachability, WordPress state
$D logs               # follow the WordPress container log
$D wp plugin list     # WP-CLI inside a throwaway container
$D shell              # shell in the WordPress container
$D db-dump            # dump the database into backups/
$D stop               # stop, keep everything
$D down               # remove container + network (volume preserved)
$D down --volumes     # also delete the WordPress files volume
```

`down --volumes` never touches the database: it is external.

### The database is external

`bin/dev` starts no database container. It reuses `DB_HOST`, `DB_PORT`,
`DB_NAME`, `DB_USER` and `DB_PASSWORD` from the site config, so **the database
and its user must exist beforehand**:

```sql
CREATE DATABASE `wp_example_com` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER 'wp_example_com'@'%' IDENTIFIED BY '<DB_PASSWORD from the site config>';
GRANT ALL PRIVILEGES ON `wp_example_com`.* TO 'wp_example_com'@'%';
```

`DB_HOST` is interpreted from the container's point of view:

| `DB_HOST` in the config | Used by the container    | Meaning                          |
|-------------------------|--------------------------|----------------------------------|
| `127.0.0.1`/`localhost` | `host.docker.internal`   | Server on the Docker host        |
| anything else           | as is                    | Remote server                    |

Override with `DEV_DB_HOST` when neither applies. Two things commonly block a
host database: `bind-address = 127.0.0.1` in the MariaDB config (the container
arrives over the Docker bridge, not over loopback), and a grant limited to
`'user'@'localhost'`. `bin/dev up` diagnoses both and stops before installing.

If dev and production share the same database server, set `DEV_TABLE_PREFIX`
(for example `wpdev_`) so the two installs do not collide in the same schema.

### Developing plugins and themes

Mount local directories straight into `wp-content` from the site config:

```sh
DEV_PLUGIN_DIRS="/home/user/GIT/my-plugin:/home/user/GIT/other-plugin"
DEV_THEME_DIRS="/home/user/GIT/my-theme"
```

`bin/dev` renders these into `dev/<domain>/compose.override.yml` (gitignored) on
every run.

To browse and edit the whole installation from the host, bind-mount the
document root:

```sh
DEV_DOCROOT="/home/user/dev/example.com"
```

The containers run as **your** uid/gid (derived from `SUDO_UID`/`SUDO_GID` when
invoked through sudo, overridable with `DEV_UID`/`DEV_GID`): apache gets them
through `APACHE_RUN_USER`/`APACHE_RUN_GROUP`, and the WordPress entrypoint
chowns the document root to match. Everything WordPress writes — uploads,
plugins installed from the dashboard, core updates — ends up owned by you, and
`Unable to create directory wp-content/uploads/...` warnings disappear.

Without `DEV_DOCROOT` the document root stays inside a Docker named volume,
which is fine when you only reach the site through the browser and `bin/dev wp`.

If your user is not in the `docker` group, `bin/dev` detects it and re-runs the
Docker calls through `sudo` (pass `--no-sudo` to refuse).

---

## Configuration

A site config is a plain shell file sourced by the scripts. Only these values
are authored; everything else is derived (see `derive_site_config` in
`lib/config.sh`).

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
DB_NAME="wp_example_com"
DB_USER="wp_example_com"
DB_PASSWORD="..."                # generated by bin/new-site

PHP_VERSION="8.3"
NGINX_MODE="nginxorg"            # nginxorg | ubuntu

DEV_HTTP_PORT="8080"             # dev only; bin/new-site picks a free port
```

Derived automatically: `NGINX_SITE_NAME` (domain with dots turned into dashes),
`PHP_FPM_SOCK`, `SSL_CERT` / `SSL_KEY`, the nginx config path, the log paths,
`SITE_URL`, and the whole `DEV_*` set (`DEV_URL`, `DEV_PROJECT_NAME`,
`DEV_WP_IMAGE`, `DEV_DB_HOST`, ...). Any of them can still be overridden in the
config file; see `config/site.env.example` for the full list.

### `NGINX_MODE`

| Value      | For nginx installed from | Site config path                                     |
|------------|--------------------------|------------------------------------------------------|
| `nginxorg` | nginx.org (1.30.x)       | `/etc/nginx/conf.d/<site>.conf`                      |
| `ubuntu`   | Ubuntu repos (1.24.x)    | `/etc/nginx/sites-available/<site>` + symlink        |

In `nginxorg` mode the installer also switches the nginx worker user from
`nginx` to `www-data`, otherwise the workers cannot reach the PHP-FPM socket.

---

## Daily operations

```sh
C="bash bin/console --config sites/example.com.env"

$C info                 # resolved configuration (no secrets)
$C status               # WordPress, services, nginx site, database, certificate
sudo $C permissions     # reapply ownership and file modes
sudo $C nginx           # re-render and install the nginx site config
sudo $C reload          # nginx -t, then reload nginx + PHP-FPM
sudo $C ssl-renew       # regenerate the self-signed certificate
$C db-dump              # dump the database into backups/ (gitignored)
$C wp plugin list       # any WP-CLI command against this site
```

### Production TLS

The generated certificate is self-signed (365 days). Replace it with Let's
Encrypt once DNS points at the server:

```sh
sudo apt install certbot python3-certbot-nginx
sudo certbot --nginx -d example.com
```

certbot rewrites the `ssl_certificate*` lines in the site config. After that,
re-running `sudo bin/console nginx` would overwrite them with the self-signed
paths — set `SSL_DIR` to the certbot directory in the site config first, or skip
that command.

---

## Security model

- **No credential is ever committed.** `sites/*` is gitignored; the only
  committed template, `config/site.env.example`, carries `CHANGEME` placeholders
  that the loader rejects at runtime.
- `bin/new-site` generates 24-character random passwords and writes the file
  with mode 600. The loader warns if a config is more permissive than that.
- Passwords are never printed in the installer summary; it points at the config
  file instead.
- Applied to every site: `wp-config.php` mode 640, `DISALLOW_FILE_EDIT`,
  `WP_DEBUG` off, PHP execution denied under `wp-content/uploads`, `xmlrpc.php`
  and dotfiles denied, HTTP redirected to HTTPS.
- `backups/` (database dumps) is gitignored as well.

---

## Verifying changes to the scripts

There is no build or test suite. After editing:

```sh
bash -n bin/* lib/*.sh                      # syntax check
shellcheck bin/* lib/*.sh                   # if available
bash bin/new-site test.local --path /tmp/wp # generate a throwaway config
bash bin/console --config sites/test.local.env info
```

Rendering the nginx template without touching the system:

```sh
source lib/common.sh
render_template nginx/site.conf.tpl DOMAIN=example.com DOCROOT=/tmp/wp \
  PHP_FPM_SOCK=/run/php/php8.3-fpm.sock SSL_CERT=/tmp/c SSL_KEY=/tmp/k \
  ACCESS_LOG=/tmp/a.log ERROR_LOG=/tmp/e.log CLIENT_MAX_BODY_SIZE=64M
```

`$host`, `$uri` and friends in the output are nginx variables, not unresolved
placeholders.
