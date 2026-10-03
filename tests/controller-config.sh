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
assert_contains "$CTRL" 'template("vnt2/vnt2_status"), _("运行信息")' "runtime info page registered with status template"
assert_contains "$CTRL" 'cbi("vnt2_runtime_log")' "runtime log page registered"
assert_not_contains "$CTRL" "act_config_" "config management endpoints removed"
assert_not_contains "$CTRL" "vnt2_config" "config management page references removed"
if [ ! -f "${PKG_DIR}/luasrc/view/vnt2/vnt2_config.htm" ]; then
	checks=$((checks + 1))
else
	echo "FAIL: vnt2_config.htm must be removed"
	failures=$((failures + 1))
fi
assert_not_contains "$MODEL" "vnt2/vnt2_status" "status card moved off the basic settings page"

# --- status endpoint ---
assert_contains "$CTRL" 'e.cli_target_tag = FIXED_VNT2_VERSION' "status shows fixed target version"
assert_contains "$CTRL" 'act_status()' "status endpoint exists"
assert_contains "$CTRL" 'get_active_conf()' "status reports the active config file"
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
assert_contains "$MODEL" '/vnt_config' "model guides users to create TOML via SSH"
assert_not_contains "$MODEL" 'web_token' "no web token field"
assert_not_contains "$MODEL" 'web_port' "no web port field"
assert_not_contains "$MODEL" 'generate_web_token' "no web token generator"
assert_not_contains "$MODEL" '配置管理' "no stale config page references in model"

# --- status view ---
assert_contains "$STATUS" 'vnt2_cli 客户端状态' "status card title"
assert_contains "$STATUS" '未选择配置文件' "status shows missing config hint"
assert_contains "$STATUS" '运行信息' "runtime info card"
assert_contains "$STATUS" '节点列表' "clients list card"
assert_contains "$STATUS" '路由列表' "routes list card"
assert_contains "$STATUS" 'escapeHtml' "dynamic text escaped in JS"
assert_not_contains "$STATUS" 'token' "no token in status view"
assert_not_contains "$STATUS" 'preview' "no preview in status view"

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
