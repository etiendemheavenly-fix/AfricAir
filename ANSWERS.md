# Part A — Understand the build

## Commands and environment

Environment used: Node.js `v24.22.0`, pnpm `10.23.0`.

- `pnpm build`
- `Get-ChildItem dist -File -Recurse` to list the generated files and their byte sizes.
- `tar.exe -czf <temporary-file>.tar.gz dist`, then `(Get-Item <temporary-file>).Length` to measure the compressed tar archive. The temporary archive was removed after measuring it.
- To compare dependency resolution without risking the repository lockfile, I copied `package.json`, `pnpm-workspace.yaml`, and `server/package.json` to a temporary workspace with no `pnpm-lock.yaml`, then ran `pnpm install` there and compared its generated lockfile with the repository lockfile.

## 1. Files in `dist/` and hashed asset names

The build produced:

```text
dist/africair-mark.svg
dist/index.html
dist/manus-routes.json
dist/version.json
dist/assets/airports-BrwcO3ZA.js
dist/assets/index-CBj_wgb2.css
dist/assets/index-D8WT6gtn.js
dist/assets/index.es-C05bQb9q.js
dist/assets/pdf-o1MWN_TF.js
dist/assets/react-CpYK3H_K.js
```

Vite includes content hashes in the generated asset filenames. When an asset changes, its filename changes too, so browsers and CDNs can cache it for a long time without accidentally reusing an old version after a deployment. Without hashes, users could get stale JavaScript or CSS after an update, or deployments would need more aggressive cache invalidation.

## 2. `tsc -b` and `vite build`

`tsc -b` runs TypeScript's project-build mode over the configured project references, checking the application and Vite configuration. Both referenced TypeScript configurations set `noEmit: true`, so this step does not generate the application files in `dist/`.

`vite build` bundles the app and copies public assets into `dist/`. It is the step that produces the deployable frontend files there.

## 3. `--frozen-lockfile`

`pnpm install --frozen-lockfile` installs the versions already recorded in `pnpm-lock.yaml` and fails rather than silently updating the lockfile if it no longer matches the package manifests. This keeps CI installs repeatable and makes dependency changes reviewable.

For the comparison, I left the real `pnpm-lock.yaml` in place and ran `pnpm install` in a temporary copy of the workspace manifests without a lockfile. The fresh resolution selected newer versions allowed by the manifest ranges. For example, React and React DOM changed from `19.3.0` to `19.3.1`, and `@playwright/test` changed from `1.64.0` to `1.64.1`. The generated lockfile differed by 141 added and 141 removed lines.

Without a frozen lockfile in CI, a later run can install different direct or transitive dependencies than an earlier run, even when the source commit is unchanged. That can change build output or test behavior unexpectedly and makes dependency changes harder to review and reproduce.

## 4. `manualChunks`, `chunkSizeWarningLimit`, and the largest chunk

In `vite.config.ts`, `manualChunks` tells Rollup/Vite to group selected modules into named output chunks: PDF dependencies go into `pdf`, the airport dataset into `airports`, and React dependencies into `react`. This creates separate bundles that can be cached independently.

`chunkSizeWarningLimit: 700` sets the chunk-size threshold, in kB, at which Vite warns about a large generated chunk. It is a warning threshold, not a limit that splits or reduces a bundle.

The largest generated JavaScript chunk was `pdf-o1MWN_TF.js`: **584.78 kB uncompressed** and **175.43 kB gzip**. That transfer and its parsing can add delay for users on a slow or metered connection. The PDF utility is statically imported by the app, so the separate chunk is not currently deferred until a user asks to download a PDF; it can still be fetched as part of loading the app. A dynamic import could defer that cost if needed.

## 5. Why not serve production traffic with `pnpm dev`

1. `pnpm dev` starts Vite's development server, not a production build. It serves transformed development modules and supports development features such as hot module replacement rather than serving the optimized static files from `dist/`.
2. It is intended for local development, not as a production web server with production-grade availability, caching, TLS, and traffic handling. Production should serve the built static files through an appropriate web server or CDN.
3. This project's dev server binds to `0.0.0.0:3000` and proxies `/api` to `localhost:4000`. That local development setup is not a production deployment topology; the frontend assets and optional API should be deployed and operated appropriately for production.

## 6. Build size

The ten files in `dist/` total **1,420,555 bytes** (**1.355 MiB**, about **1.42 MB** decimal).

The gzip-compressed tar archive (`tar czf - dist` equivalent) measured **451,254 bytes** (**440.68 KiB**, about **0.45 MB** decimal). This is an archive measurement, so it includes tar metadata as well as the compressed files.

B7. Log analysis

• Format of the Timestamp: Tracked via $time_local. 

:~$ sudo tail -n 5 /var/log/nginx/africair.access.json
{"time_local":"15/Oct/2026:21:55:11 +0000","remote_addr":"::1","request_method":"HEAD","request_uri":"/","status": "404","body_bytes_sent":"0","request_time":"0.000","http_referrer":"","http_user_agent":"curl/8.5.0"}

• Format of the Timestamp: Tracked via $time_local. It structures timestamps using the standard Common Log Format format: [Day/Month/Year:Hour:Minute:Second ZoneOffset].
• Field for Request Duration: Tracked via $request_time. This variable tracks full processing latency (measured in seconds with millisecond resolution) spent handling the connection inside the server stack.
• Field for User Agent Identification: Tracked via $http_user_agent. This captures the client's software string details (like curl/8.5.0 or Mozilla/5.0...), allowing you to precisely break down user operating profiles.

## Part C — S3 and CloudFront publishing

`pnpm build` writes `dist/version.json` with the package version and current Git commit. The S3 publishing script uploads hashed assets with a one-year immutable cache policy, then uploads `version.json` and `index.html` with `no-cache`. Only after the new HTML is live does it delete stale objects. This order ensures the new HTML never references assets that have not uploaded, and the previous release's assets remain available until the HTML switches. It invalidates only `/index.html` and `/version.json`; hashed asset URLs already change when their content changes. The script disables Git Bash's MSYS path conversion on the CloudFront invalidation call so paths such as `/index.html` reach AWS unchanged.

For this deployment, the version JSON is `{"version":"1.0.0","commit":"a3ca7af8b5d6"}`. The private, versioned, SSE-S3 bucket is `africair-static-204685625557`; all four S3 Block Public Access controls are enabled. CloudFront distribution `E1LCEA19Q51GIK` (`dipwyqeirpige.cloudfront.net`) uses OAC, `PriceClass_200`, the default root object `index.html`, HTTP-to-HTTPS redirection, and the B5 security headers. The bucket policy grants only that distribution read access. A direct anonymous S3 request returned HTTP 403, while CloudFront returned HTTP 200. `version.json` returned `Cache-Control: no-cache`, and a hashed JS asset returned `public,max-age=31536000,immutable`. The root page returned HTTP 200 over HTTPS and HTTP 301 over HTTP.

The deployer policy permits only listing this site bucket, putting/deleting its objects, and creating invalidations for this distribution. A dedicated `africair-s3-deployer` IAM user was tested: listing the site bucket succeeded, while listing a separate temporary bucket returned `AccessDenied`; that empty test bucket was then deleted. The CLI credentials were not included in this repository.

The full desktop and mobile Playwright E2E suite passed against `https://dipwyqeirpige.cloudfront.net` (**26/26**). The live `/#/status` page reports the API as not reachable and the site as running in static mode with built-in defaults. Without a reachable API, server-side booking persistence, PostgreSQL-backed trips, promotion validation, and the admin dashboard are unavailable; browser-only behavior and built-in static content remain. S3 and CloudFront serve public files and cannot keep a secret: every object delivered to a visitor can be downloaded and inspected, so admin tokens and other credentials must never be bundled or uploaded.
