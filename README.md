# Orthanc + DICOMweb Local Launcher

This project provides a local startup wrapper around Orthanc for macOS with a CORS-aware reverse proxy for browser-based DICOMweb clients (for example OHIF running on `http://localhost:3000`).

It is designed so you can run one command:

```bash
yarn start
```

and get:

1. Orthanc package download/update (only when needed)
2. macOS quarantine cleanup for the downloaded Orthanc files
3. interactive port conflict handling
4. config consistency check against tracked config
5. CORS reverse proxy startup
6. Orthanc startup

## What this project includes

- `scripts/start.sh`: main launcher
- `cors-reverse-proxy.js`: local proxy for DICOMweb/CORS handling
- `config*.json`: tracked Orthanc config files
- `package.json`: `yarn start` entrypoint

## Requirements

- macOS
- `node`
- `yarn` (classic v1 is fine)
- `curl`
- `unzip`
- `xattr`
- `lsof`

## Quick start

```bash
cd /Users/kohler/projects/Orthanc-MacOS-26.1.0-stable
yarn start
```

## Runtime behavior

### 1) Orthanc download (conditional)

The launcher checks the latest macOS Orthanc package from:

- `https://orthanc.uclouvain.be/downloads/macos/packages/universal/index.html`

It downloads/extracts into `./orthanc` only if:

- `./orthanc` is missing, or
- the local package marker does not match the latest discovered zip.

The temporary `.zip` is removed after extraction.

### 2) Quarantine removal

The launcher runs:

```bash
xattr -dr com.apple.quarantine ./orthanc
```

### 3) Used config consistency check (with prompt)

Before starting Orthanc, the launcher determines which config is used by parsing:

- `./orthanc/startOrthanc.command`

Then it compares that runtime config file in `./orthanc` against the tracked repo file with the same name.

If they differ (or runtime is missing), it prompts:

- `Do you want to update runtime config from tracked file now? [y/N]`

### 4) Port conflict prompts

The launcher checks and prompts for:

- proxy port (`8050` by default)
- Orthanc HTTP port (`8042` by default)
- Orthanc DICOM port (`4242` by default)

For each busy port it shows PID + process name and asks confirmation before killing.
If SIGTERM is not enough, it asks again before SIGKILL.

### 5) Proxy startup

Starts `cors-reverse-proxy.js` with CORS headers and forwarding to Orthanc.

Default mapping:

- proxy: `127.0.0.1:8050`
- Orthanc target: `127.0.0.1:8042`

### 6) Orthanc startup

Starts Orthanc via:

- `./orthanc/startOrthanc.command`

## Environment variables

You can override defaults when running:

```bash
PROXY_PORT=8050 \
ORTHANC_HTTP_PORT=8042 \
ORTHANC_DICOM_PORT=4242 \
ALLOWED_ORIGIN=http://localhost:3000 \
yarn start
```

Supported variables:

- `PROXY_PORT` (default `8050`)
- `ORTHANC_HTTP_PORT` (default `8042`)
- `ORTHANC_DICOM_PORT` (default `4242`)
- `ALLOWED_ORIGIN` (default `http://localhost:3000`)
- `ORTHANC_INDEX_URL` (defaults to Orthanc official macOS index URL)

## Typical usage with OHIF

Point OHIF DICOMweb base URL to:

- `http://localhost:8050/dicom-web`

## Notes

- This repo intentionally ignores downloaded Orthanc binaries and storage/cache folders.
- Tracked config files live in repo root as `config*.json`.

