# Project 1 — Build and AWS Deployment Notes

This file tracks the assignment evidence. Local build facts should be measured
from the current checkout; server and AWS results must be filled in only after
those environments have actually been used.

## Part A — Understand the build

### Commands to run and what they show

```bash
pnpm install --frozen-lockfile
pnpm check
pnpm test
pnpm build
find dist -type f -printf '%P %s bytes\n' | sort
du -sb dist
tar czf - dist | wc -c
```

- `pnpm install --frozen-lockfile` installs exactly the dependency versions
  recorded in `pnpm-lock.yaml`; it fails if the package manifests and lockfile
  disagree instead of silently rewriting the lock.
- `pnpm check` type-checks the frontend and API. The root build script runs
  `tsc -b` before Vite.
- `pnpm test` runs the Vitest unit and API tests.
- `pnpm build` runs TypeScript's project build, bundles the frontend with Vite,
  and writes build version information. Vite writes the frontend files to
  `dist/`.
- On this Windows workstation I used `Get-ChildItem -LiteralPath dist -File
  -Recurse` to list files. I made a temporary archive with
  `tar.exe -czf <temporary-file> -C . dist`, measured it with
  `(Get-Item <temporary-file>).Length`, then removed that named temporary
  file. This measures the equivalent of the Linux `tar czf - dist | wc -c`
  command without trying to stream binary tar data through PowerShell.

### Build result measured on this workstation

Environment: Node.js `v24.22.0`, pnpm `10.23.0`, Windows. The assignment calls
for Node.js 22 on the Linux build server; this local output is useful evidence
about the app, but is not the required Node 22 production-build evidence.

Commands actually run for this local validation:

```text
pnpm install --frozen-lockfile
pnpm check
pnpm test
pnpm build
pnpm build:api
```

`pnpm check` passed. `pnpm test` passed 30 tests; 3 database-dependent tests
were skipped. Both builds passed on Node 24.22.0.

```text
africair-mark.svg                         357 bytes
assets/airports-BrwcO3ZA.js           289,186 bytes
assets/index.es-C05bQb9q.js           159,767 bytes
assets/index-CBj_wgb2.css              44,666 bytes
assets/index-D8WT6gtn.js              117,585 bytes
assets/pdf-o1MWN_TF.js                584,775 bytes
assets/react-CpYK3H_K.js              223,309 bytes
index.html                                 805 bytes
manus-routes.json                           61 bytes
version.json                                44 bytes
Total dist/ size:                   1,420,555 bytes
Compressed dist/ tar.gz size:         451,247 bytes
```

The largest chunk is `pdf-o1MWN_TF.js`, at 584,775 bytes before gzip. This
matters on slow connections because larger downloads take longer and also need
more time to parse and execute.

### Concepts

1. Vite puts content hashes in asset names so a changed file gets a new URL.
   Long-lived caches can safely keep the old URL while new HTML points to new
   content. Without hashes, users or CDNs may keep serving stale JS/CSS after a
   deployment.
2. `tsc -b` checks the configured TypeScript project references; the project's
   TypeScript configs use `noEmit`, so TypeScript does not produce the frontend
   files. `vite build` bundles the app and writes `dist/`.
3. `--frozen-lockfile` makes CI installs repeatable and ensures dependency
   changes are deliberate and reviewable. Regenerating a lockfile can select
   different versions within package ranges, changing tests or output with no
   application-code change.
4. `manualChunks` groups modules into separately cacheable JS files.
   `chunkSizeWarningLimit` only controls when Vite warns; it does not shrink a
   bundle. The current configuration groups PDF code, airport data, and React.
   Record the largest actual output chunk and its size after the build.
5. `pnpm dev` is for development, not production: it serves transformed
   development modules rather than the optimized build, has development
   features such as hot reload, and is not a production web server with the
   deployment, caching, TLS, and reliability controls used here.
6. `dist/` is 1,420,555 bytes and its gzip tar archive is 451,247 bytes in the
   Node 24 Windows build measured above. Repeat on the Node 22 Linux build
   server for the assignment's production evidence.

## Part B — Linux/EC2 deployment

### Design choices

- `bootstrap.sh` prepares a fresh Ubuntu host, installs Node.js 22 and the
  required packages (including PostgreSQL), creates a non-login `africair`
  system user, configures UFW, and installs the web, health-check, and API
  service files. It checks package/config state before changing it so repeat
  runs are safe.
- `build.sh <git-ref>` fetches an exact Git ref into a temporary checkout,
  installs the frozen dependencies, runs checks and tests, builds both
  frontend and API, and creates checksummed artifacts. It uses `jq` to add
  commit, ref, build time, build user, and Node version to `version.json`.
- I tested the API's `pnpm deploy --prod --legacy` packaging into a temporary
  directory. The compiled API entry, `pg`, and migrations were present, and
  the development-only `tsx` package was absent. pnpm printed Windows-specific
  executable-link warnings, so this does not replace a clean Linux packaging
  run.
- `deploy.sh` verifies checksums before extracting. It creates a new release
  directory and switches the `current` symlink using a temporary link and
  `mv -T`. A direct `ln -sfn` can unlink and recreate the name in separate
  filesystem operations, leaving a brief gap; renaming a prepared symlink in
  the same directory is an atomic name replacement on Linux.
- Deployment runs `nginx -t` before `systemctl reload nginx`, then checks
  `/healthz` and that `/version.json` reports the intended commit. Failed
  checks restore the previous release. The script retains recent releases.
  A `flock` lock prevents simultaneous deploy and rollback commands from
  racing over release links.
- The health systemd timer runs the health check once per minute. The script
  stores consecutive failures under `/var/lib/africair/`; after the third
  failure it logs a warning and reloads nginx after validating the config.
- Nginx writes JSON access logs, excludes `/healthz`, proxies `/api/` to the
  local API, and does not proxy the API metrics port.
- The Nginx security-header include is added again in locations that define
  their own cache headers. Nginx does not inherit server-level `add_header`
  directives into a child location when that child defines its own
  `add_header`; repeating the include keeps security headers on cached assets
  and on `index.html` and `version.json`.
- The API service reads non-secret settings from `/etc/africair/api.env`.
  `LoadCredential=` copies secret files into a service-private credential
  directory at service start; the process is not granted direct access to
  `/etc/africair/secrets`. Changing the source secret therefore requires a
  service restart to update the credential snapshot.
- The API's default shutdown delay is 5 seconds and can be configured up to
  60 seconds. `TimeoutStopSec=75s` gives it time for that delay plus its
  graceful connection drain before systemd forcibly stops it.
- `report.sh` summarizes the Nginx JSON log with `jq`, `sort`, `uniq`, and
  `awk`. Its per-minute report uses Nginx's numeric epoch timestamp field,
  avoiding date parsing differences across jq versions.
- Bash parsed every `scripts/ops/*.sh` file successfully with `bash -n`.
  ShellCheck and the Linux service/runtime acceptance checks have not yet run.

### API host preparation — commands to use after approval

These commands configure the server and database; they have **not** been run
from this workstation. First launch the EC2 instance with the required tags,
attach `AmazonSSMManagedInstanceCore`, and allow SSH only from your IP (or use
Session Manager), plus public HTTP/HTTPS. Then bootstrap the new Ubuntu host:

```bash
sudo ./scripts/ops/bootstrap.sh
sudo install -o root -g africair -m 0640 deploy/api.env.example /etc/africair/api.env
sudo install -d -o root -g root -m 0700 /etc/africair/secrets
sudo -u postgres createuser --pwprompt africair_app
sudo -u postgres createdb --owner=africair_app africair
```

`createuser --pwprompt` asks for the database-role password interactively,
instead of putting it in shell history. Store the resulting connection URL in
`/etc/africair/secrets/database_url`; create `promo_codes` there, and generate
the admin token without printing it:

```bash
sudo sh -c 'umask 077; openssl rand -hex 24 > /etc/africair/secrets/admin_token'
sudo chmod 0600 /etc/africair/secrets/admin_token /etc/africair/secrets/promo_codes /etc/africair/secrets/database_url
sudo chown root:root /etc/africair/secrets/admin_token /etc/africair/secrets/promo_codes /etc/africair/secrets/database_url
```

The three secret files must exist before systemd starts the API, because
`LoadCredential=` reads them at service startup. Deploy the matching API
artifact, apply the schema without displaying the database URL, and start the
service:

```bash
sudo ./scripts/ops/deploy.sh artifacts/africair-<sha>.tar.gz artifacts/africair-api-<sha>.tar.gz
sudo bash -c 'DATABASE_URL="$(< /etc/africair/secrets/database_url)" node /opt/africair/api/current/server/dist/migrate.js'
sudo systemctl enable --now africair-api.service
```

The `africair` service account receives credential copies from systemd and
should not be able to read the root-only source directory. Verify that with
`sudo -u africair cat /etc/africair/secrets/admin_token`; it must return
`Permission denied`. Repeat the check after real provisioning, not on this
Windows workstation.

### Knowledge check

1. `nginx -s reload` asks the existing Nginx master to validate/reload worker
   configuration. Old workers can finish existing requests while new workers
   accept traffic. `systemctl restart nginx` stops and starts the service,
   which can interrupt in-flight requests.
2. With `set -u`, expanding an unset `$RELEASE_DIR` causes Bash to stop rather
   than expand it to an empty string. This is not the only safeguard: use
   quoted variables, validate the path is under the expected releases
   directory, reject empty/root paths, and avoid recursive deletion unless
   the target has been checked.
3. A static single-page app has no application server to report that its files
   are present and being served. A server-side health endpoint lets monitoring
   and deployment scripts check the actual web server path and detect failed
   releases.
4. EC2 has a continuously running server cost, requires OS patching and
   capacity planning, and has a larger host-level failure/blast radius. S3 and
   CloudFront scale static traffic and provide managed HTTPS, but may incur
   storage, request, transfer, and invalidation charges; current costs depend
   on region and traffic and should be estimated with AWS pricing tools.
   Release directories make EC2 rollback local; S3 versioning and retained
   hashed assets help recover static objects, while publishing the prior build
   is another rollback route.
5. Possible stale-content causes: (a) old `index.html` at the origin—check
   S3 object version and cache headers; (b) CloudFront still serving a cached
   root or index—check response `Age`/`X-Cache` and invalidation status; (c) a
   browser or service worker cache—test a private window and inspect browser
   cache/service-worker behavior. Hashed asset caching is expected; new HTML
   must reference the new asset hashes.

### Deployment evidence — fill after provisioning

- EC2 instance, region and tags: **pending**
- Bootstrap idempotency (two consecutive runs): **pending**
- Build artifact names, checksums and commit: **pending**
- Nginx health/version/cache/security-header checks: **pending**
- Wrong-checksum deployment leaves active release unchanged: **pending**
- Automatic rollback and one-command rollback: **pending**
- Health timer and journald entries: **pending**
- API PostgreSQL, credential isolation, maintenance mode and admin checks:
  **pending**
- ShellCheck and log report output: **pending**

## Part C — S3 and CloudFront

`publish-s3.sh` uploads hashed assets first, then the small root files and
`index.html`, and removes stale objects only after the new HTML is live. That
order prevents new HTML from referencing assets that have not arrived yet.
Only `/index.html` and `/version.json` are invalidated because those stable
URLs can be cached; content-hashed assets use new URLs when their contents
change, so invalidating every asset is unnecessary.

An S3 bucket is only static object storage. Anything placed in browser-delivered
files can be downloaded by visitors, so S3 cannot keep API secrets private.
The static site can still search and save bookings locally, but API-backed
bookings, database persistence, admin functions, and server-validated promo
codes require a reachable server-side API.

AWS resource and acceptance evidence: **pending confirmation and execution in
the target AWS account**. Do not record a resource as created until it has
been checked in that account.
