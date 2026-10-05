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
STATUSMODEL="${PKG_DIR}/luasrc/model/cbi/vnt2_status.lua"
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
assert_contains "$CTRL" 'cbi("vnt2"), _("插件设置")' "plugin settings page registered"
assert_contains "$CTRL" 'cbi("vnt2_status"), _("运行信息")' "runtime info page registered as cbi form"
assert_contains "$CTRL" 'cbi("vnt2_runtime_log")' "runtime log page registered"
assert_not_contains "$MODEL" 'vnt2_cli 客户端设置' "no section title on the settings form"
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
assert_not_contains "$CTRL" 'conf_file' "no config-file selection in status"
assert_not_contains "$CTRL" 'get_active_conf' "no active config helper"
assert_not_contains "$CTRL" 'web_url' "no web access address in status"
assert_not_contains "$CTRL" 'check_preview' "no preview version query"
assert_not_contains "$CTRL" 'PREVIEW_STATE_FILE' "no preview state file"

# --- vnt2_ctrl queries ---
assert_contains "$CTRL" 'query_ctrl' "control query helper exists"
assert_contains "$CTRL" "timeout 5 %s -p %d %s" "ctrl queries wrapped in 5s timeout with explicit port"
assert_contains "$CTRL" 'parse_ctrl_info' "control info parsed into fields"
assert_contains "$CTRL" 'textutil.sanitize_text(out)' "ctrl output ANSI-stripped"
assert_contains "$CTRL" 'act_ctrl_query()' "clients/route endpoint exists"

# --- toml editor round-trip ---
assert_contains "$CTRL" 'function act_toml_read()' "toml read endpoint implemented"
assert_contains "$CTRL" 'function act_toml_save()' "toml save endpoint implemented"
assert_contains "$CTRL" 'toml_serialize_uci' "editor reads serialize UCI to TOML"
assert_contains "$CTRL" 'toml_parse_config' "editor save parses TOML text"
assert_contains "$CTRL" 'toml_apply_to_uci' "editor save writes back to UCI"
assert_contains "$CTRL" 'queue_restart' "editor save queues a client restart"
assert_contains "$CTRL" '已被清除' "editor warns when omitted keys are cleared"
assert_contains "$CTRL" '已废弃键 no_tun' "editor rejects deprecated no_tun key"
assert_contains "$CTRL" 'tunnel_addr 与 tunnel_port 互斥' "editor enforces tunnel mutual exclusion"
assert_contains "$MODEL" 'w:tab("edit", translate("编辑配置"))' "edit config tab registered"
assert_contains "$MODEL" 'vnt2/vnt2_toml_edit' "edit tab renders the editor template"
assert_contains "$MODEL" 'vnt2/vnt2_form_css' "form css compaction template attached"
assert_contains "$MODEL" 'w:tab("upload", translate("上传程序"))' "upload tab still registered"
if [ -f "${PKG_DIR}/luasrc/view/vnt2/vnt2_toml_edit.htm" ]; then
	checks=$((checks + 1))
else
	echo "FAIL: vnt2_toml_edit.htm template missing"
	failures=$((failures + 1))
fi
edit_line=$(grep -n 'w:tab("edit"' "$MODEL" | head -n1 | cut -d: -f1)
upload_line=$(grep -n 'w:tab("upload"' "$MODEL" | head -n1 | cut -d: -f1)
if [ -n "$edit_line" ] && [ -n "$upload_line" ] && [ "$edit_line" -lt "$upload_line" ]; then
	checks=$((checks + 1))
else
	echo "FAIL: edit tab must come before the upload tab"
	failures=$((failures + 1))
fi
assert_contains "${PKG_DIR}/luasrc/view/vnt2/vnt2_toml_edit.htm" 'toml_save' "editor template posts to save endpoint"
assert_contains "${PKG_DIR}/luasrc/view/vnt2/vnt2_toml_edit.htm" 'vnt2TomlReload' "editor template offers reload"

# --- logs ---
assert_contains "$CTRL" '/tmp/logs/vnt2.log' "client log path"
assert_contains "$CTRL" '/tmp/vnt2-download.log' "download log path"
assert_contains "$CTRL" 'vnt2%.%d+%.log' "clear removes rotated client logs"
assert_contains "$LOGVIEW" '/tmp/logs/vnt2.log' "log view reads client log"

# --- basic settings model: full FileConfig field set ---
assert_contains "$MODEL" 'TypedSection, "vnt2_cli"' "settings bound to vnt2_cli section"
assert_contains "$MODEL" '"network_code"' "network_code field present"
assert_contains "$MODEL" '"subscription"' "subscription field present"
assert_contains "$MODEL" '"server"' "server list field present"
assert_contains "$MODEL" '"peer_address"' "peer_address list field present"
assert_contains "$MODEL" '"device_mode"' "device_mode field present"
assert_contains "$MODEL" '"tun_name"' "tun_name field present"
assert_contains "$MODEL" '"ip", translate("固定虚拟 IP")' "virtual ip field present"
assert_contains "$MODEL" '"device_name"' "device_name field present"
assert_contains "$MODEL" '"device_id"' "device_id field present"
assert_contains "$MODEL" '"outbound_interface"' "outbound_interface field present"
assert_contains "$MODEL" '"mtu"' "mtu field present"
assert_contains "$MODEL" '"rtx"' "rtx flag present"
assert_contains "$MODEL" '"compress"' "compress flag present"
assert_contains "$MODEL" '"fec"' "fec flag present"
assert_contains "$MODEL" '"no_punch"' "no_punch flag present"
assert_contains "$MODEL" '"no_broadcast"' "no_broadcast flag present"
assert_contains "$MODEL" '"auto_sync_subnet"' "auto_sync_subnet flag present"
assert_contains "$MODEL" '"allow_ikev2"' "allow_ikev2 flag present"
assert_contains "$MODEL" '"allow_wireguard"' "allow_wireguard flag present"
assert_contains "$MODEL" '"allow_mapping"' "allow_mapping flag present"
assert_contains "$MODEL" '"input"' "input list field present"
assert_contains "$MODEL" '"output"' "output list field present"
assert_contains "$MODEL" '"subnet_mapping"' "subnet_mapping list field present"
assert_contains "$MODEL" '"port_mapping"' "port_mapping list field present"
assert_contains "$MODEL" '"password"' "password field present"
assert_contains "$MODEL" '"cert_mode"' "cert_mode field present"
assert_contains "$MODEL" '"udp_stun"' "udp_stun list field present"
assert_contains "$MODEL" '"tcp_stun"' "tcp_stun list field present"
assert_contains "$MODEL" '"tunnel_addr"' "tunnel_addr list field present"
assert_contains "$MODEL" '"tunnel_port"' "tunnel_port field present"
assert_contains "$MODEL" '"event_script"' "event_script field present"
assert_contains "$MODEL" '"vnt2_forward"' "firewall forwarding directions present"
assert_contains "$MODEL" '"ctrl_port", translate("控制端口")' "control port input present"
assert_contains "$MODEL" '"vnt2_cli_bin", translate("vnt2_cli 程序路径")' "cli binary path input present"
assert_contains "$MODEL" '127.0.0.1' "control port description documents loopback-only binding"
assert_contains "$MODEL" "网络编号与订阅链接至少填写其一" "identity cross-validation present"
assert_not_contains "$MODEL" 'conf_file' "no config-file selector in model"
assert_not_contains "$MODEL" 'web_token' "no web token field"
assert_not_contains "$MODEL" 'web_port' "no web port field"
assert_not_contains "$MODEL" 'generate_web_token' "no web token generator"
assert_not_contains "$MODEL" '配置管理' "no stale config page references in model"

# --- status view ---
assert_contains "$STATUSMODEL" 'SimpleForm("vnt2", translate("运行信息"))' "runtime info page uses the standard form chrome"
assert_contains "$STATUSMODEL" 'Template("vnt2/vnt2_status")' "runtime info page embeds the status template"
assert_contains "$STATUS" '运行状态' "status card title"
assert_contains "$STATUS" '虚拟网络' "virtual network card"
assert_contains "$STATUS" 'fieldset class="cbi-section' "cards use theme section styling"
assert_contains "$STATUS" '客户端未运行' "lists hidden with a hint when client stopped"
assert_contains "$STATUS" 'vnt2_clients_card' "list cards have toggle ids"
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
