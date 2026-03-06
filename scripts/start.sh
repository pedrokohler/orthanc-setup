#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORTHANC_DIR="${ROOT_DIR}/orthanc"
PROXY_SCRIPT="${ROOT_DIR}/cors-reverse-proxy.js"

PROXY_PORT="${PROXY_PORT:-8050}"
ORTHANC_HTTP_PORT="${ORTHANC_HTTP_PORT:-8042}"
ORTHANC_DICOM_PORT="${ORTHANC_DICOM_PORT:-4242}"
ALLOWED_ORIGIN="${ALLOWED_ORIGIN:-http://localhost:3000}"
ORTHANC_INDEX_URL="${ORTHANC_INDEX_URL:-https://orthanc.uclouvain.be/downloads/macos/packages/universal/index.html}"

PACKAGE_MARKER_FILE="${ORTHANC_DIR}/.orthanc-package"

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required"
  exit 1
fi

if ! command -v unzip >/dev/null 2>&1; then
  echo "unzip is required"
  exit 1
fi

if ! command -v xattr >/dev/null 2>&1; then
  echo "xattr is required (macOS)"
  exit 1
fi

if ! command -v node >/dev/null 2>&1; then
  echo "node is required"
  exit 1
fi

collect_port_listeners() {
  local port="$1"
  lsof -nP -iTCP:"${port}" -sTCP:LISTEN -Fpc 2>/dev/null || true
}

ensure_port_is_free_or_confirm_kill() {
  local port="$1"
  local label="$2"
  local listeners

  listeners="$(collect_port_listeners "${port}")"
  if [[ -z "${listeners}" ]]; then
    return 0
  fi

  local pids=()
  local commands=()
  while IFS= read -r line; do
    case "${line}" in
      p*) pids+=("${line#p}") ;;
      c*) commands+=("${line#c}") ;;
    esac
  done <<< "${listeners}"

  if [[ "${#pids[@]}" -eq 0 ]]; then
    return 0
  fi

  echo
  echo "Port ${port} (${label}) is already in use by:"
  for i in "${!pids[@]}"; do
    local cmd="${commands[$i]:-unknown}"
    echo "  - PID ${pids[$i]} (${cmd})"
  done

  local answer
  read -r -p "Do you want to kill these process(es) and continue? [y/N] " answer || {
    echo "No input received. Aborting."
    exit 1
  }

  case "${answer}" in
    y|Y|yes|YES|Yes)
      ;;
    *)
      echo "Aborting. Free port ${port} and run again."
      exit 1
      ;;
  esac

  local seen=" "
  for pid in "${pids[@]}"; do
    if [[ "${seen}" == *" ${pid} "* ]]; then
      continue
    fi
    seen="${seen}${pid} "
    if kill -0 "${pid}" >/dev/null 2>&1; then
      kill "${pid}" >/dev/null 2>&1 || true
    fi
  done

  sleep 1
  listeners="$(collect_port_listeners "${port}")"
  if [[ -n "${listeners}" ]]; then
    echo "Port ${port} is still in use after SIGTERM."
    echo "${listeners}" | awk '
      BEGIN { pid=""; cmd="" }
      /^p/ { pid=substr($0,2) }
      /^c/ { cmd=substr($0,2); if (pid != "") { printf("  - PID %s (%s)\n", pid, cmd) } }
    '
    read -r -p "Force kill with SIGKILL? [y/N] " answer || {
      echo "No input received. Aborting."
      exit 1
    }
    case "${answer}" in
      y|Y|yes|YES|Yes)
        echo "${listeners}" | awk '/^p/ { print substr($0,2) }' | while IFS= read -r pid; do
          [[ -n "${pid}" ]] && kill -9 "${pid}" >/dev/null 2>&1 || true
        done
        sleep 1
        ;;
      *)
        echo "Aborting. Port ${port} still occupied."
        exit 1
        ;;
    esac
  fi

  listeners="$(collect_port_listeners "${port}")"
  if [[ -n "${listeners}" ]]; then
    echo "Could not free port ${port}. Aborting."
    exit 1
  fi
}

get_used_config_filename() {
  local launcher_path="${ORTHANC_DIR}/startOrthanc.command"
  local used_config=""

  if [[ -f "${launcher_path}" ]]; then
    used_config="$(awk '
      /^[[:space:]]*\.\/*Orthanc([[:space:]]|$)/ {
        for (i = 2; i <= NF; i++) {
          token = $i
          gsub(/["'\'']/, "", token)
          if (token ~ /\.json$/) {
            print token
            exit
          }
        }
      }
    ' "${launcher_path}")"
  fi

  if [[ -z "${used_config}" ]]; then
    used_config="configMacOS.json"
  fi

  basename "${used_config}"
}

prompt_sync_used_config_if_mismatch() {
  local used_config
  local tracked_path
  local runtime_path
  local answer

  used_config="$(get_used_config_filename)"
  tracked_path="${ROOT_DIR}/${used_config}"
  runtime_path="${ORTHANC_DIR}/${used_config}"

  if [[ ! -f "${tracked_path}" ]]; then
    echo "Tracked config ${tracked_path} not found. Skipping config consistency check."
    return 0
  fi

  if [[ -f "${runtime_path}" ]] && cmp -s "${tracked_path}" "${runtime_path}"; then
    echo "Used config ${used_config} already matches tracked file."
    return 0
  fi

  echo
  echo "Used Orthanc config differs from tracked version:"
  echo "  - tracked: ${tracked_path}"
  if [[ -f "${runtime_path}" ]]; then
    echo "  - runtime: ${runtime_path} (different content)"
  else
    echo "  - runtime: ${runtime_path} (missing)"
  fi

  read -r -p "Do you want to update runtime config from tracked file now? [y/N] " answer || {
    echo "No input received. Aborting."
    exit 1
  }

  case "${answer}" in
    y|Y|yes|YES|Yes)
      cp "${tracked_path}" "${runtime_path}"
      echo "Updated ${runtime_path} from tracked config."
      ;;
    *)
      echo "Keeping runtime config unchanged."
      ;;
  esac
}

latest_zip_filename="$(curl -fsSL "${ORTHANC_INDEX_URL}" | node -e '
let html = "";
process.stdin.on("data", (chunk) => (html += chunk));
process.stdin.on("end", () => {
  const matches = [];
  const regex = /Orthanc-macOS-([0-9]+(?:\.[0-9]+)*)\.zip/g;
  let m;
  while ((m = regex.exec(html)) !== null) {
    matches.push({
      filename: m[0],
      version: m[1].split(".").map((v) => parseInt(v, 10)),
    });
  }
  if (matches.length === 0) {
    console.error("Could not discover any Orthanc macOS zip in index.");
    process.exit(1);
  }
  matches.sort((a, b) => {
    const max = Math.max(a.version.length, b.version.length);
    for (let i = 0; i < max; i += 1) {
      const av = a.version[i] || 0;
      const bv = b.version[i] || 0;
      if (av !== bv) {
        return av - bv;
      }
    }
    return 0;
  });
  process.stdout.write(matches[matches.length - 1].filename);
});
')"

index_base_url="${ORTHANC_INDEX_URL%/*}"
latest_zip_url="${index_base_url}/${latest_zip_filename}"

download_needed="true"
if [[ -x "${ORTHANC_DIR}/Orthanc" && -f "${ORTHANC_DIR}/startOrthanc.command" && -f "${PACKAGE_MARKER_FILE}" ]]; then
  current_package="$(cat "${PACKAGE_MARKER_FILE}")"
  if [[ "${current_package}" == "${latest_zip_filename}" ]]; then
    download_needed="false"
  fi
fi

if [[ "${download_needed}" == "true" ]]; then
  echo "Downloading latest Orthanc package: ${latest_zip_filename}"

  tmp_zip="$(mktemp "${TMPDIR:-/tmp}/orthanc-macos.XXXXXX")"
  tmp_extract_dir="$(mktemp -d "${TMPDIR:-/tmp}/orthanc-extract.XXXXXX")"

  cleanup_tmp() {
    rm -f "${tmp_zip}" 2>/dev/null || true
    rm -rf "${tmp_extract_dir}" 2>/dev/null || true
  }

  trap cleanup_tmp EXIT

  curl -fL "${latest_zip_url}" -o "${tmp_zip}"
  unzip -q "${tmp_zip}" -d "${tmp_extract_dir}"

  extracted_start_file="$(find "${tmp_extract_dir}" -type f -name "startOrthanc.command" -print -quit)"
  if [[ -z "${extracted_start_file}" ]]; then
    echo "Could not locate startOrthanc.command in extracted package."
    exit 1
  fi

  extracted_dir="$(cd "$(dirname "${extracted_start_file}")" && pwd)"
  rm -rf "${ORTHANC_DIR}"
  mkdir -p "${ORTHANC_DIR}"
  cp -a "${extracted_dir}/." "${ORTHANC_DIR}/"
  printf "%s" "${latest_zip_filename}" > "${PACKAGE_MARKER_FILE}"

  # Ensure the downloaded archive is removed.
  rm -f "${tmp_zip}"
  trap - EXIT
  cleanup_tmp
else
  echo "Orthanc already up to date (${latest_zip_filename}), skipping download."
fi

echo "Removing macOS quarantine attributes from ${ORTHANC_DIR}"
xattr -dr com.apple.quarantine "${ORTHANC_DIR}" || true

prompt_sync_used_config_if_mismatch

ensure_port_is_free_or_confirm_kill "${PROXY_PORT}" "Proxy"
ensure_port_is_free_or_confirm_kill "${ORTHANC_HTTP_PORT}" "Orthanc HTTP"
ensure_port_is_free_or_confirm_kill "${ORTHANC_DICOM_PORT}" "Orthanc DICOM"

echo "Starting proxy on port ${PROXY_PORT} -> Orthanc ${ORTHANC_HTTP_PORT}"
PROXY_PORT="${PROXY_PORT}" \
TARGET_HOST="127.0.0.1" \
TARGET_PORT="${ORTHANC_HTTP_PORT}" \
ALLOWED_ORIGIN="${ALLOWED_ORIGIN}" \
node "${PROXY_SCRIPT}" &
PROXY_PID=$!

cleanup() {
  if kill -0 "${PROXY_PID}" >/dev/null 2>&1; then
    kill "${PROXY_PID}" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT INT TERM

echo "Starting Orthanc from ${ORTHANC_DIR}/startOrthanc.command"
chmod +x "${ORTHANC_DIR}/startOrthanc.command"
(
  cd "${ORTHANC_DIR}"
  ./startOrthanc.command
)
