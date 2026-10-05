#!/bin/sh
# Behaviour assertions for the init service script and workers.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PKG_DIR="${1:-}"
if [ -z "$PKG_DIR" ]; then
	for candidate in $(find "${REPO_ROOT}" -name Makefile -type f); do
		if tr -d '\r' <"$candidate" | grep -q '^PKG_NAME:=luci-app-vnt2cli[[:space:]]*$'; then
			PKG_DIR="$(dirname "$candidate")"
			break
		fi
	done
fi
INIT="${PKG_DIR}/root/etc/init.d/vnt2"

failures=0
checks=0

assert_contains() {
	# assert_contains <file> <fixed-string> <description>
	if grep -qF -- "$2" "$1"; then
		checks=$((checks + 1))
	else
		echo "FAIL: $3"
		failures=$((failures + 1))
	fi
}

assert_not_contains() {
	if grep -qF -- "$2" "$1"; then
		echo "FAIL: $3"
		failures=$((failures + 1))
	else
		checks=$((checks + 1))
	fi
}

# --- start instance model ---
assert_contains "$INIT" 'procd_set_param env RUST_LOG="$log_level"' "start injects RUST_LOG"
assert_contains "$INIT" '--ctrl-port \"${ctrl_port}\"' "start passes explicit --ctrl-port"
assert_contains "$INIT" 'valid_port "$ctrl_port" || ctrl_port="11233"' "invalid ctrl_port falls back to 11233"
assert_contains "$INIT" 'client config missing network_code and subscription' "start rejects configs without identity"

# --- single-config export model ---
assert_contains "$INIT" 'TOML_EXPORT_FILE="/tmp/vnt2cli.toml"' "runtime toml path fixed"
assert_contains "$INIT" 'export_client_config "$cfg"' "service flow exports the runtime toml"
assert_contains "$INIT" 'client disabled; runtime toml export skipped' "stopped client still refreshes the export"
assert_contains "$INIT" 'start failed: runtime toml export failed' "export failure blocks client start"
assert_contains "$INIT" '--conf \"${TOML_EXPORT_FILE}\"' "start passes the exported toml via --conf"
assert_contains "$INIT" 'client config missing network_code and subscription' "export rejects configs without identity"
assert_contains "$INIT" 'tunnel_addr and tunnel_port are mutually exclusive' "export enforces tunnel_addr/tunnel_port mutual exclusion"
assert_contains "$INIT" 'mv -f "$tmp" "$TOML_EXPORT_FILE"' "export publishes atomically"
assert_contains "$INIT" 'toml_put_list "$tmp" "server" "$cfg" "server"' "server list exported"
assert_contains "$INIT" 'toml_put_string "$tmp" "password"' "password exported with escaping"
assert_contains "$INIT" 'toml_escape' "toml values escaped"

# --- network sync reads UCI directly ---
assert_contains "$INIT" 'config_get "$cfg" "device_mode"' "network sync reads device_mode from UCI"
assert_contains "$INIT" 'config_get "$cfg" "ip"' "network sync reads virtual ip from UCI"
assert_contains "$INIT" 'config_get "$cfg" "no_nat"' "network sync reads no_nat from UCI"
assert_not_contains "$INIT" 'toml_get_' "no legacy toml parsers in init"
assert_not_contains "$INIT" 'conf_file' "no config-file selection in init"
assert_not_contains "$INIT" 'vnt_config' "no /vnt_config usage in init"
assert_contains "$INIT" 'NETWORK_SYNC_RESULT="no-device-mode"' "device_mode no cleans managed network objects"

# --- firewall: no web port rules, four forwarding directions kept ---
assert_contains "$INIT" 'firewall.vnt2fwlan' "forwarding rule vnt2fwlan managed"
assert_contains "$INIT" 'firewall.vnt2fwwan' "forwarding rule vnt2fwwan managed"
assert_contains "$INIT" 'firewall.lanfwvnt2' "forwarding rule lanfwvnt2 managed"
assert_contains "$INIT" 'firewall.wanfwvnt2' "forwarding rule wanfwvnt2 managed"

# --- machine-id persistence ---
assert_contains "$INIT" 'ensure_persistent_machine_id' "machine-id prepared before start"
assert_contains "$INIT" 'mktemp "${MACHINE_ID_FILE}.XXXXXX"' "machine-id written via private temp file"

# --- version sidecar ---
assert_contains "$INIT" 'VERSION_STATE_FILE="/etc/config/vnt2-cli.version"' "sidecar path fixed"
assert_contains "$INIT" 'cli_mtime=' "sidecar records cli binary mtime"
assert_contains "$INIT" 'ctrl_size=' "sidecar records ctrl binary size"
assert_contains "$INIT" 'version_state_matches_binary "$path" "cli"' "sidecar validated per binary"

# --- restart worker ---
RW="${PKG_DIR}/root/usr/libexec/vnt2/restart-worker"
assert_not_contains "$RW" 'NETWORK_RECORD_FILE' "restart worker has no record file"
assert_contains "$RW" 'uci -q show vnt2' "restart worker watches UCI changes"
assert_contains "$RW" 'RESTART_DELAY="${VNT2_RESTART_DELAY:-15}"' "restart worker default 15s debounce"
assert_contains "$RW" 'claim_restart_request' "restart worker claims markers atomically"

# --- upload worker ---
UW="${PKG_DIR}/root/usr/libexec/vnt2/upload-worker"
assert_contains "$UW" 'TARGET_BIN="${INSTALL_BIN_DIR}/vnt2_cli"' "upload installs vnt2_cli"
assert_contains "$UW" 'zip_archive_is_safe' "upload validates zip archives"
assert_contains "$UW" 'tar_archive_is_safe' "upload validates tar.gz archives"
assert_contains "$UW" 'clear_version_state' "upload clears version sidecar"
assert_contains "$UW" 'queue_restart' "upload queues a service restart"
assert_contains "$UW" 'vnt2_cli_bin' "upload syncs vnt2_cli_bin UCI option"
assert_not_contains "$UW" 'vnt2_web' "upload worker has no vnt2_web references"

echo "----------------------------------------"
echo "checks passed: ${checks}, failures: ${failures}"
if [ "$failures" -gt 0 ]; then
	exit 1
fi
echo "init-service: OK"
