#!/bin/sh
# Pre-build source validation gate for luci-app-vnt2cli.
# Usage: tests/validate-source.sh [package-source-directory]
# The directory argument defaults to the directory containing PKG_NAME:=luci-app-vnt2cli.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PKG_DIR="${1:-}"

failures=0
checks=0

fail() {
	echo "FAIL: $*"
	failures=$((failures + 1))
}

ok() {
	checks=$((checks + 1))
}

note() {
	echo "SKIP: $*"
}

# ---------- locate package directory ----------
if [ -z "${PKG_DIR}" ]; then
	for candidate in $(find "${REPO_ROOT}" -name Makefile -type f); do
		if tr -d '\r' <"$candidate" | grep -q '^PKG_NAME:=luci-app-vnt2cli[[:space:]]*$'; then
			PKG_DIR="$(dirname "$candidate")"
			break
		fi
	done
fi

if [ -z "${PKG_DIR}" ] || [ ! -f "${PKG_DIR}/Makefile" ]; then
	echo "FAIL: package source directory with PKG_NAME:=luci-app-vnt2cli not found"
	exit 1
fi
echo "package source directory: ${PKG_DIR}"

INIT="${PKG_DIR}/root/etc/init.d/vnt2"

# ---------- shell syntax ----------
for f in \
	"${PKG_DIR}/Makefile" \
	"${PKG_DIR}"/root/etc/init.d/* \
	"${PKG_DIR}"/root/usr/libexec/vnt2/* \
	"${REPO_ROOT}"/tests/*.sh; do
	[ -f "$f" ] || continue
	if sh -n "$f" 2>/tmp/vnt2cli-shn.err; then
		ok
	else
		fail "shell syntax: $f: $(cat /tmp/vnt2cli-shn.err)"
	fi
done
rm -f /tmp/vnt2cli-shn.err

# ---------- Lua 5.1 syntax ----------
if command -v luac5.1 >/dev/null 2>&1; then
	LUAC="luac5.1"
elif command -v luac >/dev/null 2>&1; then
	LUAC="luac"
else
	LUAC=""
	note "luac not available; Lua syntax check skipped (CI installs lua5.1)"
fi
if [ -n "$LUAC" ]; then
	for f in $(find "${PKG_DIR}/luasrc" -name '*.lua' -type f); do
		if "$LUAC" -p "$f" 2>/tmp/vnt2cli-lua.err; then
			ok
		else
			fail "lua syntax: $f: $(cat /tmp/vnt2cli-lua.err)"
		fi
	done
	rm -f /tmp/vnt2cli-lua.err
fi

# ---------- YAML syntax ----------
if command -v python3 >/dev/null 2>&1; then
	for f in $(find "${REPO_ROOT}/.github" -name '*.yml' -o -name '*.yaml' 2>/dev/null); do
		if python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1], encoding='utf-8'))" "$f" 2>/tmp/vnt2cli-yaml.err; then
			ok
		else
			fail "yaml syntax: $f: $(cat /tmp/vnt2cli-yaml.err)"
		fi
	done
	rm -f /tmp/vnt2cli-yaml.err
else
	note "python3 not available; YAML syntax check skipped (CI installs it)"
fi

# ---------- UTF-8, BOM and CRLF ----------
for f in $(find "${PKG_DIR}" "${REPO_ROOT}/.github" "${REPO_ROOT}/tests" -type f \( -name '*.lua' -o -name '*.htm' -o -name '*.sh' -o -name '*.yml' -o -name '*.md' -o -name 'vnt2' -o -name 'vnt2cli' \) 2>/dev/null) \
	"${PKG_DIR}/root/etc/config/vnt2" \
	"${PKG_DIR}/root/lib/upgrade/keep.d/vnt2cli" \
	"${PKG_DIR}/Makefile"; do
	[ -f "$f" ] || continue
	if head -c 3 "$f" | od -An -tx1 | grep -q 'ef bb bf'; then
		fail "BOM found: $f"
	else
		ok
	fi
	if grep -q "$(printf '\r')" "$f" 2>/dev/null; then
		fail "CRLF line ending found: $f"
	else
		ok
	fi
done

# ---------- git hygiene ----------
if command -v git >/dev/null 2>&1 && git -C "${REPO_ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
	if git -C "${REPO_ROOT}" diff --check >/tmp/vnt2cli-gitdiff.err 2>&1; then
		ok
	else
		fail "git diff --check reported whitespace errors: $(cat /tmp/vnt2cli-gitdiff.err | head -n3)"
	fi
	rm -f /tmp/vnt2cli-gitdiff.err
else
	note "not a git work tree; git diff --check skipped"
fi

# ---------- package identity ----------
if tr -d '\r' <"${PKG_DIR}/Makefile" | grep -q '^PKG_NAME:=luci-app-vnt2cli[[:space:]]*$'; then
	ok
else
	fail "Makefile must define PKG_NAME:=luci-app-vnt2cli"
fi

if grep -q '^PKGARCH:=all\|^LUCI_PKGARCH:=all' "${PKG_DIR}/Makefile"; then
	ok
else
	fail "Makefile must keep the package architecture independent (LUCI_PKGARCH:=all)"
fi

# ---------- forbidden references ----------
# Scanned everywhere: these belong to the removed web client and must not exist
# in any source file, including the packaging Makefile.
for pattern in \
	'vnt2_web' \
	'vnt2web' \
	'vnt2-web' \
	'web_token' \
	'web_host' \
	'web_port' \
	'web_wan'; do
	hits=$(grep -rn -- "$pattern" "${PKG_DIR}" 2>/dev/null | grep -v 'Binary file' || true)
	if [ -n "$hits" ]; then
		fail "forbidden reference '${pattern}' found:"
		echo "$hits" | head -n5
	else
		ok
	fi
done

# Scanned in runtime sources only: the Makefile postinst must keep deleting
# these legacy artifacts during upgrades. The single-config model additionally
# forbids any config-file selection or /vnt_config usage in runtime sources.
for pattern in \
	'version-worker' \
	'preview-worker' \
	'vnt_current_config' \
	'releases/latest' \
	'act_config_' \
	'vnt2_config' \
	'conf_file' \
	'vnt_config' \
	'toml_get_'; do
	hits=$(grep -rn -- "$pattern" "${PKG_DIR}/root" "${PKG_DIR}/luasrc" 2>/dev/null | grep -v 'Binary file' || true)
	if [ -n "$hits" ]; then
		fail "forbidden reference '${pattern}' found:"
		echo "$hits" | head -n5
	else
		ok
	fi
done

# GNU od options must never be used for ELF detection (BusyBox od lacks them).
# Both is_elf_binary implementations must read the magic with dd.
for f in "${INIT}" "${PKG_DIR}/root/usr/libexec/vnt2/upload-worker"; do
	if ! grep -q 'is_elf_binary()' "$f"; then
		fail "is_elf_binary() missing in $f"
		continue
	fi
	block=$(sed -n '/^is_elf_binary()/,/^}/p' "$f")
	if printf '%s\n' "$block" | grep -q 'dd if="$bin" bs=1 count=4'; then
		ok
	else
		fail "ELF detection must read the magic with dd in $f"
	fi
	if printf '%s\n' "$block" | grep -v '^\s*#' | grep -q 'od '; then
		fail "ELF detection must not use od in $f"
	else
		ok
	fi
done

# ---------- LuCI template syntax ----------
# The Lua template engine only understands <% %>, <%= %>, <%: %> and <%+ %>.
# Anything else between the brackets is handed to Lua verbatim, so an
# HTML-looking <%-- comment --%> is a syntax error that takes down the whole
# settings page. Comments must be plain HTML.
for f in $(find "${PKG_DIR}/luasrc" -type f -name '*.htm' 2>/dev/null); do
	if grep -q '<%--\|--%>' "$f"; then
		fail "invalid template comment in $f: use <!-- --> instead of <%-- --%>"
	else
		ok
	fi
done

# ---------- required files ----------
for f in \
	"${PKG_DIR}/root/etc/init.d/vnt2" \
	"${PKG_DIR}/root/etc/init.d/vnt2-worker" \
	"${PKG_DIR}/root/etc/init.d/vnt2-upload-worker" \
	"${PKG_DIR}/root/usr/libexec/vnt2/restart-worker" \
	"${PKG_DIR}/root/usr/libexec/vnt2/upload-worker" \
	"${PKG_DIR}/root/etc/config/vnt2" \
	"${PKG_DIR}/root/lib/upgrade/keep.d/vnt2cli" \
	"${PKG_DIR}/luasrc/controller/vnt2.lua" \
	"${PKG_DIR}/luasrc/model/cbi/vnt2.lua" \
	"${PKG_DIR}/luasrc/model/cbi/vnt2_status.lua" \
	"${PKG_DIR}/luasrc/view/vnt2/vnt2_status.htm" \
	"${PKG_DIR}/luasrc/view/vnt2/vnt2_toml_edit.htm" \
	"${PKG_DIR}/luasrc/view/vnt2/vnt2_form_css.htm" \
	"${PKG_DIR}/luasrc/view/vnt2/dynlist.htm" \
	"${PKG_DIR}/luasrc/view/vnt2/multilist.htm" \
	"${PKG_DIR}/luasrc/view/vnt2/other_dvalue.htm" \
	"${PKG_DIR}/luasrc/view/vnt2/other_upload.htm"; do
	if [ -f "$f" ]; then
		ok
	else
		fail "required file missing: $f"
	fi
done

# ---------- fixed download policy ----------
if grep -q 'VNT2_FIXED_REPO="vnt-dev/vnt"' "$INIT" && grep -q 'VNT2_FIXED_VERSION="2.0.10"' "$INIT"; then
	ok
else
	fail "init script must pin the fixed repo vnt-dev/vnt and version 2.0.10"
fi

if grep -q 'releases/tags/' "$INIT" && ! grep -q 'releases?per_page\|releases/latest' "$INIT"; then
	ok
else
	fail "release query must resolve the fixed tag only"
fi

# ---------- request isolation ----------
check_marker_only_block() {
	# The block must only write a marker: schedule_restart is the allowed
	# helper call; any other restart/sleep/background execution is forbidden.
	local name="$1"
	local block
	block=$(sed -n "/^${name}()/,/^}/p" "${INIT}")
	if [ -z "$block" ]; then
		fail "${name}() missing"
		return
	fi
	block=$(printf '%s\n' "$block" | sed 's/schedule_restart//g')
	if printf '%s\n' "$block" | grep -q 'sleep\|&$\|restart\|/etc/init.d\|ubus'; then
		fail "${name} must only write a pending marker"
	else
		ok
	fi
}

check_marker_only_block reload_service
check_marker_only_block schedule_restart

# ---------- vnt2_cli start model ----------
if grep -q 'cd /tmp && exec' "$INIT"; then
	ok
else
	fail "init must start vnt2_cli from /tmp working directory"
fi

if grep -q -- '--conf ' "$INIT" && grep -q -- '--ctrl-port ' "$INIT"; then
	ok
else
	fail "init must pass --conf and --ctrl-port explicitly"
fi

if grep -qF 'TOML_EXPORT_FILE="/tmp/vnt2cli.toml"' "$INIT" && grep -qF -- '--conf \"${TOML_EXPORT_FILE}\"' "$INIT"; then
	ok
else
	fail "init must export and start from the single runtime toml /tmp/vnt2cli.toml"
fi

if grep -q 'export_client_config "$cfg"' "$INIT"; then
	ok
else
	fail "init must export the runtime toml before starting the client"
fi

if grep -Eq 'toml_put_[a-z]+ "\$tmp" "ctrl_port"' "$INIT"; then
	fail "runtime toml must not contain a ctrl_port key (control port goes via --ctrl-port)"
else
	ok
fi

if grep -q -- '--token\|--addr ' "$INIT"; then
	fail "init must not pass web client arguments (--token/--addr)"
else
	ok
fi

if grep -q 'procd_set_param respawn 3600 5 5' "$INIT"; then
	ok
else
	fail "client respawn must be bounded (procd_set_param respawn 3600 5 5)"
fi

# ---------- control port loopback ----------
if grep -q '127.0.0.1' "${PKG_DIR}/root/usr/libexec/vnt2"/* 2>/dev/null || true; then
	: # workers never bind ports
fi
if grep -rn 'ensure_firewall_rule\|dest_port' "${PKG_DIR}/root/etc/init.d/vnt2" >/dev/null 2>&1; then
	fail "init must not create port-forward firewall rules (control port stays loopback only)"
else
	ok
fi

# ---------- upload staging ----------
UP="${PKG_DIR}/root/usr/libexec/vnt2/upload-worker"
if grep -q 'UPLOAD_DIR}/incoming' "$UP" && grep -q 'umask 077' "$UP"; then
	ok
else
	fail "upload worker must only process staged incoming.* files with private umask"
fi

if grep -q 'TARGET_CTRL_BIN' "$UP"; then
	ok
else
	fail "upload worker must install vnt2_ctrl when present in the archive"
fi

# ---------- keep.d ----------
if [ "$(cat "${PKG_DIR}/root/lib/upgrade/keep.d/vnt2cli")" = "/etc/machine-id" ]; then
	ok
else
	fail "keep.d/vnt2cli must preserve /etc/machine-id"
fi

echo "----------------------------------------"
echo "checks passed: ${checks}, failures: ${failures}"
if [ "$failures" -gt 0 ]; then
	exit 1
fi
echo "validate-source: OK"
