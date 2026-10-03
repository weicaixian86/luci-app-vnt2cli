#!/bin/sh
# Assertions for the LuCI controller, models and views.
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
CTRL="${PKG_DIR}/luasrc/controller/vnt2.lua"
MODEL="${PKG_DIR}/luasrc/model/cbi/vnt2.lua"
TEXT="${PKG_DIR}/luasrc/model/vnt2_text.lua"
STATUS="${PKG_DIR}/luasrc/view/vnt2/vnt2_status.htm"
CFGVIEW="${PKG_DIR}/luasrc/view/vnt2/vnt2_config.htm"
LOGVIEW="${PKG_DIR}/luasrc/view/vnt2/vnt2_runtime_log.htm"

failures=0
checks=0

assert_contains() {
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

# --- menu and pages ---
assert_contains "$CTRL" '"admin", "vpn", "vnt2"' "menu entry under VPN"
assert_contains "$CTRL" 'cbi("vnt2")' "basic settings page registered"
assert_contains "$CTRL" 'template("vnt2/vnt2_config")' "config management page registered"
assert_not_contains "$CTRL" "act_config_page" "config page uses the template target directly"
assert_contains "$CTRL" 'cbi("vnt2_runtime_log")' "runtime log page registered"

# --- config management endpoints ---
for ep in act_config_list act_config_read act_config_save act_config_delete act_config_use; do
	assert_contains "$CTRL" "function ${ep}()" "config endpoint ${ep} implemented"
done
assert_contains "$CTRL" 'is_safe_toml_name(name)' "config endpoints validate file names"
if sed -n '/^function act_config_save()/,/^}/p' "$CTRL" | grep -qF 'fs.writefile(path'; then
	echo "FAIL: config save must not write content directly to the target path"
	failures=$((failures + 1))
else
	checks=$((checks + 1))
fi
assert_contains "$CTRL" 'atomic_write_toml' "config writes are atomic"
assert_contains "$CTRL" 'fs.chmod(tmp, "0600")' "config temp files get 0600"
assert_contains "$CTRL" 'fs.chmod(CONFIG_DIR, "0700")' "config directory stays 0700"
assert_contains "$CTRL" 'set_conf_file("")' "deleting the active config clears conf_file"
assert_contains "$CTRL" 'queue_restart' "config changes queue a worker restart"
assert_contains "$CTRL" 'ctrl_port' "save warns about TOML ctrl_port override"

# --- status endpoint ---
assert_contains "$CTRL" 'e.cli_target_tag = FIXED_VNT2_VERSION' "status shows fixed target version"
assert_contains "$CTRL" 'act_status()' "status endpoint exists"
assert_not_contains "$CTRL" 'web_url' "no web access address in status"
assert_not_contains "$CTRL" 'check_preview' "no preview version query"
assert_not_contains "$CTRL" 'PREVIEW_STATE_FILE' "no preview state file"

# --- vnt2_ctrl queries ---
assert_contains "$CTRL" 'query_ctrl' "control query helper exists"
assert_contains "$CTRL" "timeout 5 %s -p %d %s" "ctrl queries wrapped in 5s timeout with explicit port"
assert_contains "$CTRL" 'parse_ctrl_info' "control info parsed into fields"
assert_contains "$CTRL" 'textutil.sanitize_text(out)' "ctrl output ANSI-stripped"
assert_contains "$CTRL" 'act_ctrl_query()' "clients/route endpoint exists"

# --- logs ---
assert_contains "$CTRL" '/tmp/logs/vnt2.log' "client log path"
assert_contains "$CTRL" '/tmp/vnt2-download.log' "download log path"
assert_contains "$CTRL" 'vnt2%.%d+%.log' "clear removes rotated client logs"
assert_contains "$LOGVIEW" '/tmp/logs/vnt2.log' "log view reads client log"

# --- basic settings model ---
assert_contains "$MODEL" 'TypedSection, "vnt2_cli"' "settings bound to vnt2_cli section"
assert_contains "$MODEL" '"conf_file", translate("启用配置文件")' "config file selector present"
assert_contains "$MODEL" '"ctrl_port", translate("控制端口")' "control port input present"
assert_contains "$MODEL" '"vnt2_cli_bin", translate("vnt2_cli 程序路径")' "cli binary path input present"
assert_contains "$MODEL" '127.0.0.1' "control port description documents loopback-only binding"
assert_contains "$MODEL" 'is_safe_toml_name' "model filters TOML options safely"
assert_not_contains "$MODEL" 'web_token' "no web token field"
assert_not_contains "$MODEL" 'web_port' "no web port field"
assert_not_contains "$MODEL" 'generate_web_token' "no web token generator"

# --- status view ---
assert_contains "$STATUS" 'vnt2_cli 客户端状态' "status card title"
assert_contains "$STATUS" '未选择配置文件' "status shows missing config hint"
assert_contains "$STATUS" '节点列表' "clients list card"
assert_contains "$STATUS" '路由列表' "routes list card"
assert_contains "$STATUS" 'escapeHtml' "dynamic text escaped in JS"
assert_not_contains "$STATUS" 'token' "no token in status view"
assert_not_contains "$STATUS" 'preview' "no preview in status view"

# --- config view ---
assert_contains "$CFGVIEW" 'config_save' "config view posts saves"
assert_contains "$CFGVIEW" "window.confirm" "delete requires confirmation"
assert_contains "$CFGVIEW" 'validName' "config view validates file names client-side"

# --- log text module ---
assert_contains "$TEXT" 'sanitize_text' "ANSI stripping helper exists"
assert_contains "$TEXT" 'vnt2_cli config section not found' "log translations updated"
assert_not_contains "$TEXT" 'vnt2_web' "log translations have no vnt2_web strings"

echo "----------------------------------------"
echo "checks passed: ${checks}, failures: ${failures}"
if [ "$failures" -gt 0 ]; then
	exit 1
fi
echo "controller-config: OK"
