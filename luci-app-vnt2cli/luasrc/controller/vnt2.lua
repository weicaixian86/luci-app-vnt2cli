module("luci.controller.vnt2", package.seeall)

local fs = require "nixio.fs"
local sys = require "luci.sys"
local http = require "luci.http"
local uci = require "luci.model.uci".cursor()
local textutil = require "luci.model.vnt2_text"
local LOG_DISPLAY_LINES = 300
local VERSION_STATE_FILE = "/etc/config/vnt2-cli.version"
local FIXED_VNT2_VERSION = "2.0.10"
local CLIENT_LOG_FILE = "/tmp/logs/vnt2.log"
local CLIENT_LOG_DIR = "/tmp/logs"
local DOWNLOAD_LOG_FILE = "/tmp/vnt2-download.log"
local DOWNLOAD_STATE_FILE = "/tmp/vnt2-download-cli.state"
local RESTART_PENDING_FILE = "/tmp/vnt2-restart.pending"
local RUNTIME_TOML_FILE = "/tmp/vnt2cli.toml"

function index()
	if not fs.access("/etc/config/vnt2") then
		return
	end

	entry({ "admin", "vpn", "vnt2" }, alias("admin", "vpn", "vnt2", "config"), _("VNT2"), 45).dependent = true
	entry({ "admin", "vpn", "vnt2", "config" }, cbi("vnt2"), _("插件设置"), 10).leaf = true
	entry({ "admin", "vpn", "vnt2", "info" }, cbi("vnt2_status"), _("运行信息"), 20).leaf = true
	entry({ "admin", "vpn", "vnt2", "runtime_log" }, cbi("vnt2_runtime_log"), _("运行日志"), 30).leaf = true

	entry({ "admin", "vpn", "vnt2", "status" }, call("act_status")).leaf = true
	entry({ "admin", "vpn", "vnt2", "ctrl_query" }, call("act_ctrl_query")).leaf = true
	entry({ "admin", "vpn", "vnt2", "get_runtime_log" }, call("get_runtime_log")).leaf = true
	entry({ "admin", "vpn", "vnt2", "clear_runtime_log" }, call("clear_runtime_log")).leaf = true
	entry({ "admin", "vpn", "vnt2", "toml_read" }, call("act_toml_read")).leaf = true
	entry({ "admin", "vpn", "vnt2", "toml_save" }, call("act_toml_save")).leaf = true
end

local function trim(s)
	return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function shell_quote(s)
	s = tostring(s or "")
	return "'" .. s:gsub("'", [['"'"']]) .. "'"
end

local function json_write(data)
	http.prepare_content("application/json")
	http.write_json(data)
end

local function plain_write(data)
	http.prepare_content("text/plain; charset=utf-8")
	http.write(data or "")
end

local function uci_first(stype, opt, default)
	local v = uci:get_first("vnt2", stype, opt)
	if v == nil or v == "" then
		return default
	end
	return v
end

local function file_exists(path)
	return path and path ~= "" and fs.access(path)
end

local function get_cli_bin()
	return uci_first("vnt2_cli", "vnt2_cli_bin", "/usr/bin/vnt2_cli")
end

local function get_ctrl_bin()
	return uci_first("vnt2_cli", "vnt2_ctrl_bin", "/usr/bin/vnt2_ctrl")
end

local function get_ctrl_port()
	local port = tonumber(uci_first("vnt2_cli", "ctrl_port", "11233"))
	if not port or port < 1 or port > 65535 then
		return 11233
	end
	return port
end

local function get_pid_by_name(name)
	local pid = trim(sys.exec("pidof " .. shell_quote(name) .. " 2>/dev/null | awk '{print $1}'"))
	if pid ~= "" then
		return pid
	end
	return nil
end

local function get_pid_by_path(path)
	local base = tostring(path or ""):match("([^/]+)$")
	if base and base ~= "" then
		local pid = get_pid_by_name(base)
		if pid then
			return pid
		end
	end

	local pid = trim(sys.exec("ps -w 2>/dev/null | grep " .. shell_quote(path or "") .. " | grep -v grep | awk 'NR==1{print $1}'"))
	if pid ~= "" then
		return pid
	end

	return nil
end

local function get_cli_pid()
	return get_pid_by_path(get_cli_bin())
end

local function format_runtime(tag_file)
	local t = fs.readfile(tag_file)
	if not t then
		return ""
	end

	local start_ts = tonumber(trim(t))
	if not start_ts then
		return ""
	end

	local now_ts = os.time()
	if not now_ts or now_ts < start_ts then
		return ""
	end

	local delta = now_ts - start_ts
	local day = math.floor(delta / 86400)
	local hour = math.floor((delta % 86400) / 3600)
	local min = math.floor((delta % 3600) / 60)
	local sec = delta % 60

	if day > 0 then
		return string.format("%dd %02dh %02dm %02ds", day, hour, min, sec)
	end

	return string.format("%02dh %02dm %02ds", hour, min, sec)
end

local function get_clk_tck()
	local value = tonumber(trim(sys.exec("getconf CLK_TCK 2>/dev/null"))) or 100
	if value < 1 then
		value = 100
	end
	return value
end

local function get_page_size()
	local value = tonumber(trim(sys.exec("getconf PAGESIZE 2>/dev/null"))) or 4096
	if value < 1 then
		value = 4096
	end
	return value
end

local function get_cpu_count()
	local count = tonumber(trim(sys.exec([[awk '/^cpu[0-9]+ /{n++} END{print n?n:1}' /proc/stat 2>/dev/null]]))) or 1
	if count < 1 then
		count = 1
	end
	return count
end

local CLK_TCK = get_clk_tck()
local PAGE_SIZE = get_page_size()
local CPU_COUNT = get_cpu_count()

local function get_cpu_usage(pid)
	pid = trim(pid)
	if pid == "" or not pid:match("^%d+$") then
		return ""
	end

	local stat = fs.readfile("/proc/" .. pid .. "/stat")
	if not stat or stat == "" then
		return ""
	end

	local right = stat:find("%)")
	if not right then
		return ""
	end

	local fields = {}
	for token in stat:sub(right + 2):gmatch("%S+") do
		fields[#fields + 1] = token
	end

	local utime = tonumber(fields[12] or "")
	local stime = tonumber(fields[13] or "")
	local starttime = tonumber(fields[20] or "")
	if not utime or not stime or not starttime then
		return ""
	end

	local uptime_line = trim(fs.readfile("/proc/uptime") or "")
	local uptime = tonumber((uptime_line:match("^([%d%.]+)") or ""))
	if not uptime or uptime <= 0 then
		return ""
	end

	local elapsed = uptime - (starttime / CLK_TCK)
	if elapsed <= 0 then
		return "0.00%"
	end

	local total = (utime + stime) / CLK_TCK
	local cpu = (total / elapsed) * 100
	if CPU_COUNT > 1 then
		cpu = cpu / CPU_COUNT
	end
	if cpu < 0 then
		cpu = 0
	end

	return string.format("%.2f%%", cpu)
end

local function get_mem_usage(pid)
	pid = trim(pid)
	if pid == "" or not pid:match("^%d+$") then
		return ""
	end

	local status = fs.readfile("/proc/" .. pid .. "/status") or ""
	local rss_kb = tonumber(status:match("VmRSS:%s*(%d+)"))
	if not rss_kb then
		local statm = fs.readfile("/proc/" .. pid .. "/statm") or ""
		local rss_pages = tonumber(statm:match("^%S+%s+(%d+)"))
		if rss_pages then
			rss_kb = (rss_pages * PAGE_SIZE) / 1024
		end
	end

	if not rss_kb then
		return ""
	end

	return string.format("%.2f MB", rss_kb / 1024)
end

local function parse_version_state(path)
	local out = {
		tag = "",
		source = "",
		arch = "",
		asset = "",
		cli_path = "",
		cli_mtime = "",
		cli_size = "",
		ctrl_path = "",
		ctrl_mtime = "",
		ctrl_size = "",
		time = ""
	}

	local content = fs.readfile(path)
	if not content or content == "" then
		return out
	end

	for line in content:gmatch("[^\r\n]+") do
		local k, v = line:match("^([%w_]+)=(.*)$")
		if k and out[k] ~= nil then
			out[k] = trim(v)
		end
	end

	return out
end

local function stat_value_matches(actual, expected)
	expected = trim(expected)
	if expected == "" then
		return true
	end

	local value = tonumber(actual)
	return value ~= nil and string.format("%.0f", value) == expected
end

local function get_local_tag(bin_path)
	if not file_exists(bin_path) then
		return ""
	end

	local state = parse_version_state(VERSION_STATE_FILE)
	if state.tag == "" or state.cli_path == "" or state.cli_path ~= bin_path then
		return ""
	end

	local stat = fs.stat(bin_path)
	if not stat or stat.type ~= "reg" then
		return ""
	end
	if not stat_value_matches(stat.size, state.cli_size)
		or not stat_value_matches(stat.mtime, state.cli_mtime) then
		return ""
	end

	return state.tag:gsub("^[vV]", "")
end

local function get_log_content(path, max_lines)
	return textutil.read_log_file(path, max_lines)
end

local function parse_state_file(path)
	local out = {
		state = "",
		message = "",
		asset = "",
		tag = "",
		arch = "",
		path = "",
		time = ""
	}

	local content = fs.readfile(path)
	if not content or content == "" then
		return out
	end

	for line in content:gmatch("[^\r\n]+") do
		local k, v = line:match("^([%w_]+)=(.*)$")
		if k and out[k] ~= nil then
			out[k] = trim(v)
		end
	end

	out.state = textutil.sanitize_text(out.state)
	out.message = textutil.normalize_log_text(out.message)
	out.asset = textutil.sanitize_text(out.asset)
	out.tag = textutil.sanitize_text(out.tag)
	out.arch = textutil.sanitize_text(out.arch)
	out.path = textutil.sanitize_text(out.path)
	out.time = textutil.sanitize_text(out.time)

	return out
end

-- vnt2_ctrl only listens on 127.0.0.1 and every call is wrapped in an outer
-- timeout so a stalled control port cannot hold the LuCI polling request.
local function query_ctrl(subcommand)
	local bin = get_ctrl_bin()
	if not file_exists(bin) then
		return nil, "vnt2_ctrl 不可用"
	end

	local port = get_ctrl_port()
	local cmd
	if sys.call("command -v timeout >/dev/null 2>&1") == 0 then
		cmd = string.format("timeout 5 %s -p %d %s 2>/dev/null", shell_quote(bin), port, subcommand)
	else
		cmd = string.format("%s -p %d %s 2>/dev/null", shell_quote(bin), port, subcommand)
	end

	local out = sys.exec(cmd)
	if out == nil or out == "" then
		return nil, "查询失败或超时，客户端可能尚未就绪"
	end

	return textutil.sanitize_text(out)
end

local function parse_ctrl_info(text)
	local out = {
		server = "",
		server_status = "",
		last_connected = "",
		name = "",
		device_id = "",
		version = "",
		ip = "",
		total_clients = "",
		online_clients = "",
		p2p_clients = "",
		nat_type = "",
		public_ipv4 = "",
		public_ipv6 = ""
	}

	if not text or text == "" then
		return out
	end

	for line in text:gmatch("[^\r\n]+") do
		local key, value = line:match("^%s*([^:]+):%s*(.*)$")
		if key then
			key = trim(key)
			value = trim(value)
			if key == "Server" then
				local addr, status = value:match("^(.-)%s*%((.*)%)$")
				out.server = trim(addr or value)
				out.server_status = trim(status or "")
			elseif key == "Last Connected Time" then
				out.last_connected = value
			elseif key == "Name" then
				out.name = value
			elseif key == "Id" then
				out.device_id = value
			elseif key == "Version" then
				out.version = value
			elseif key == "IP" then
				out.ip = value
			elseif key == "Total Clients" then
				out.total_clients = value
			elseif key == "Online Clients" then
				out.online_clients = value
			elseif key == "P2P Clients" then
				out.p2p_clients = value
			elseif key == "Nat Type" then
				out.nat_type = value
			elseif key == "Public Ipv4" then
				out.public_ipv4 = value
			elseif key == "Ipv6" then
				out.public_ipv6 = value
			end
		end
	end

	return out
end

function act_status()
	local e = {}
	local enabled = uci_first("vnt2_cli", "enabled", "0") == "1"

	local pid = get_cli_pid()
	local dl = parse_state_file(DOWNLOAD_STATE_FILE)

	-- This endpoint is polled every five seconds. Keep it local-only so an
	-- unavailable process cannot hold the LuCI request open during apply.
	e.cli_running = enabled and pid ~= nil
	e.cli_pid = e.cli_running and pid or ""
	e.cli_runtime = format_runtime("/tmp/vnt2_cli_time")
	e.cli_cpu = get_cpu_usage(pid)
	e.cli_ram = get_mem_usage(pid)

	-- Never execute managed binaries from this polling endpoint. A broken or
	-- blocked binary must not delay LuCI while an apply-triggered restart runs.
	e.cli_tag = get_local_tag(get_cli_bin())
	e.cli_target_tag = FIXED_VNT2_VERSION
	e.log_level = uci_first("vnt2_cli", "log_level", "info")

	e.download_log_size = #(get_log_content(DOWNLOAD_LOG_FILE, LOG_DISPLAY_LINES) or "")
	e.cli_download = dl

	e.ctrl_available = file_exists(get_ctrl_bin())
	e.ctrl_info = nil
	e.ctrl_error = ""
	if not e.ctrl_available then
		e.ctrl_error = "vnt2_ctrl 不可用"
	elseif not e.cli_running then
		e.ctrl_error = "客户端未运行"
	else
		local info, err = query_ctrl("info")
		if info then
			e.ctrl_info = parse_ctrl_info(info)
		else
			e.ctrl_error = err or "查询失败"
		end
	end

	json_write(e)
end

function act_ctrl_query()
	local what = trim(http.formvalue("what") or "")
	local e = { ok = false, text = "", error = "" }

	if what ~= "ips" and what ~= "clients" and what ~= "route" then
		e.error = "无效的查询类型"
		json_write(e)
		return
	end

	if not file_exists(get_ctrl_bin()) then
		e.error = "vnt2_ctrl 不可用"
		json_write(e)
		return
	end

	local text, err = query_ctrl(what)
	if not text then
		e.error = err or "查询失败"
	else
		e.ok = true
		e.text = text
	end
	json_write(e)
end

local function clear_log_file(path)
	if not path or path == "" then
		return
	end
	fs.writefile(path, "")
end

local function write_runtime_log()
	plain_write(textutil.merge_log_files({
		CLIENT_LOG_FILE,
		DOWNLOAD_LOG_FILE
	}, LOG_DISPLAY_LINES))
end

function get_runtime_log()
	write_runtime_log()
end

function clear_runtime_log()
	clear_log_file(CLIENT_LOG_FILE)
	clear_log_file(DOWNLOAD_LOG_FILE)
	-- Also drop rotated client log files (log4rs fixed window: vnt2.N.log).
	if fs.access(CLIENT_LOG_DIR) then
		for name in fs.dir(CLIENT_LOG_DIR) do
			if name == "vnt2.log" or name:match("^vnt2%.%d+%.log$") then
				fs.remove(CLIENT_LOG_DIR .. "/" .. name)
			end
		end
	end
	fs.remove(DOWNLOAD_STATE_FILE)
	json_write({ ok = true })
end


-- ---------- 编辑配置：UCI <-> TOML 文本往返 ----------
-- The editor never touches /tmp/vnt2cli.toml itself (that file is re-exported
-- from UCI on every start). Reload reads the runtime TOML as the complete
-- picture; saving is a partial merge: only keys present in the text are
-- written back to UCI, every other key keeps its current value.

local TOML_EDIT_STR_KEYS = {
	subscription = true,
	network_code = true,
	ip = true,
	device_mode = true,
	tun_name = true,
	device_id = true,
	device_name = true,
	outbound_interface = true,
	password = true,
	cert_mode = true,
	event_script = true
}

local TOML_EDIT_LIST_KEYS = {
	server = true,
	peer_address = true,
	turn = true,
	punch_model = true,
	input = true,
	subnet_mapping = true,
	output = true,
	port_mapping = true,
	udp_stun = true,
	tcp_stun = true,
	tunnel_addr = true
}

local TOML_EDIT_BOOL_KEYS = {
	no_punch = true,
	no_broadcast = true,
	allow_ikev2 = true,
	allow_wireguard = true,
	rtx = true,
	compress = true,
	fec = true,
	auto_sync_subnet = true,
	no_nat = true,
	allow_mapping = true
}

local TOML_EDIT_NUM_KEYS = {
	mtu = true,
	tunnel_port = true
}

local TOML_EDIT_KEY_ORDER = {
	"subscription", "server", "peer_address", "turn", "punch_model",
	"network_code", "ip", "no_punch", "no_broadcast", "allow_ikev2",
	"allow_wireguard", "rtx", "compress", "fec", "input",
	"subnet_mapping", "output", "auto_sync_subnet", "no_nat", "device_mode",
	"mtu", "port_mapping", "allow_mapping", "device_id", "device_name",
	"tun_name", "outbound_interface", "password", "cert_mode", "udp_stun",
	"tcp_stun", "tunnel_addr", "tunnel_port", "event_script"
}

local function toml_quote(value)
	local s = tostring(value or "")
	s = s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("[%z\r\n]", " ")
	return '"' .. s .. '"'
end

local function toml_serialize_uci()
	local section = uci:get_first("vnt2", "vnt2_cli")
	if not section then
		return "# 未找到 vnt2_cli 配置节，请重新安装本插件\n"
	end

	local out = {}
	out[#out + 1] = "# VNT 客户端配置（与设置表单同源；保存后写回插件配置并排队重启生效）"

	for _, key in ipairs(TOML_EDIT_KEY_ORDER) do
		local value = uci:get("vnt2", section, key)
		if value ~= nil and value ~= "" then
			if TOML_EDIT_BOOL_KEYS[key] then
				out[#out + 1] = key .. " = " .. (value == "1" and "true" or "false")
			elseif TOML_EDIT_LIST_KEYS[key] then
				local items = {}
				if type(value) == "table" then
					for _, item in ipairs(value) do
						item = trim(item)
						if item ~= "" then
							items[#items + 1] = toml_quote(item)
						end
					end
				elseif trim(tostring(value)) ~= "" then
					items[#items + 1] = toml_quote(trim(tostring(value)))
				end
				if #items > 0 then
					out[#out + 1] = key .. " = [" .. table.concat(items, ", ") .. "]"
				end
			elseif TOML_EDIT_NUM_KEYS[key] then
				local n = tonumber(trim(tostring(value)))
				if n then
					out[#out + 1] = key .. " = " .. tostring(math.floor(n))
				end
			else
				out[#out + 1] = key .. " = " .. toml_quote(trim(tostring(value)))
			end
		end
	end

	return table.concat(out, "\n") .. "\n"
end

local function toml_strip_comment(line)
	local out = {}
	local in_str = false
	local esc = false
	for i = 1, #line do
		local c = line:sub(i, i)
		if in_str then
			out[#out + 1] = c
			if esc then
				esc = false
			elseif c == "\\" then
				esc = true
			elseif c == '"' then
				in_str = false
			end
		else
			if c == "#" then
				break
			end
			out[#out + 1] = c
			if c == '"' then
				in_str = true
			end
		end
	end
	return table.concat(out)
end

local function toml_unquote(s)
	s = s:gsub("\\\\", "\001")
	s = s:gsub('\\"', '"')
	s = s:gsub("\001", "\\")
	return s
end

local function toml_parse_array(inner)
	local items = {}
	local pos = 1

	while pos <= #inner do
		local c = inner:sub(pos, pos)
		if c == " " or c == "\t" or c == "," then
			pos = pos + 1
		elseif c == '"' then
			pos = pos + 1
			local item = {}
			local esc = false
			local closed = false
			while pos <= #inner do
				local ch = inner:sub(pos, pos)
				if esc then
					item[#item + 1] = ch
					esc = false
					pos = pos + 1
				elseif ch == "\\" then
					item[#item + 1] = ch
					esc = true
					pos = pos + 1
				elseif ch == '"' then
					closed = true
					pos = pos + 1
					break
				else
					item[#item + 1] = ch
					pos = pos + 1
				end
			end
			if not closed then
				return nil
			end
			items[#items + 1] = toml_unquote(table.concat(item))
		else
			return nil
		end
	end

	return items
end

local function toml_parse_config(text)
	local values = {}
	local unknown = {}
	local lineno = 0

	for line in tostring(text or ""):gmatch("[^\r\n]+") do
		lineno = lineno + 1
		local content = trim(toml_strip_comment(line))
		if content ~= "" then
			local key, val = content:match("^([A-Za-z_][A-Za-z0-9_]*)%s*=%s*(.-)$")
			val = val and trim(val) or ""
			if not key or val == "" then
				return nil, "第 " .. lineno .. " 行不是有效的 TOML 键值"
			end
			if key == "no_tun" then
				return nil, "已废弃键 no_tun：请改用 device_mode"
			end
			if not (TOML_EDIT_STR_KEYS[key] or TOML_EDIT_LIST_KEYS[key]
				or TOML_EDIT_BOOL_KEYS[key] or TOML_EDIT_NUM_KEYS[key]) then
				unknown[#unknown + 1] = key .. " (第 " .. lineno .. " 行)"
			elseif val:sub(1, 1) == "[" then
				if val:sub(-1) ~= "]" then
					return nil, "第 " .. lineno .. " 行数组未闭合"
				end
				local items = toml_parse_array(val:sub(2, -2))
				if not items then
					return nil, "第 " .. lineno .. " 行数组格式无效"
				end
				values[key] = items
			elseif val == "true" or val == "false" then
				if not TOML_EDIT_BOOL_KEYS[key] then
					return nil, "第 " .. lineno .. " 行的键不接受布尔值"
				end
				values[key] = (val == "true")
			elseif val:sub(1, 1) == '"' then
				if #val < 2 or val:sub(-1) ~= '"' then
					return nil, "第 " .. lineno .. " 行字符串未闭合"
				end
				if not TOML_EDIT_STR_KEYS[key] then
					return nil, "第 " .. lineno .. " 行的键不接受字符串值"
				end
				values[key] = toml_unquote(val:sub(2, -2))
			elseif val:match("^%d+$") then
				if not (TOML_EDIT_NUM_KEYS[key] or TOML_EDIT_STR_KEYS[key] or TOML_EDIT_LIST_KEYS[key]) then
					return nil, "第 " .. lineno .. " 行的键不接受数值"
				end
				values[key] = val
			else
				return nil, "第 " .. lineno .. " 行的值类型无效"
			end
		end
	end

	return values, nil, unknown
end

local function toml_apply_to_uci(values)
	local section = uci:get_first("vnt2", "vnt2_cli")
	if not section then
		return nil, "未找到 vnt2_cli 配置节"
	end

	if values.device_mode and values.device_mode ~= "no"
		and values.device_mode ~= "tun" and values.device_mode ~= "tap" then
		return nil, "device_mode 仅支持 no、tun、tap"
	end
	if values.cert_mode and values.cert_mode ~= ""
		and values.cert_mode ~= "skip" and values.cert_mode ~= "standard"
		and not values.cert_mode:match("^finger:[0-9a-fA-F]+$") then
		return nil, "cert_mode 仅支持 skip、standard 或 finger:指纹"
	end
	if values.mtu then
		local n = tonumber(values.mtu)
		if not n or math.floor(n) ~= n or n < 1 or n > 65535 then
			return nil, "mtu 必须为 1~65535 的整数"
		end
	end
	if values.tunnel_port then
		local n = tonumber(values.tunnel_port)
		if not n or n < 0 or n > 65535 then
			return nil, "tunnel_port 必须为 0~65535 的整数"
		end
	end
	if values.tunnel_addr and #values.tunnel_addr > 0 and values.tunnel_port then
		return nil, "tunnel_addr 与 tunnel_port 互斥，不能同时填写"
	end

	-- Partial merge: only keys present in the text are written; keys absent
	-- from the text keep their current UCI values.
	local applied = 0
	for _, key in ipairs(TOML_EDIT_KEY_ORDER) do
		local value = values[key]
		if value ~= nil then
			applied = applied + 1
			if TOML_EDIT_BOOL_KEYS[key] then
				uci:set("vnt2", section, key, value == true and "1" or "0")
			elseif TOML_EDIT_NUM_KEYS[key] then
				uci:set("vnt2", section, key, tostring(value))
			elseif TOML_EDIT_LIST_KEYS[key] then
				local items = {}
				if type(value) == "table" then
					for _, item in ipairs(value) do
						item = trim(tostring(item))
						if item ~= "" then
							items[#items + 1] = item
						end
					end
				else
					local item = trim(tostring(value))
					if item ~= "" then
						items[#items + 1] = item
					end
				end
				uci:delete("vnt2", section, key)
				if #items > 0 then
					uci:set_list("vnt2", section, key, items)
				end
			else
				local s = trim(tostring(value))
				if s == "" then
					uci:delete("vnt2", section, key)
				else
					uci:set("vnt2", section, key, s)
				end
			end
		end
	end

	uci:commit("vnt2")
	return true, applied
end

local function queue_restart()
	local stat = fs.readfile("/proc/self/stat") or ""
	local pid = stat:match("^(%d+)") or tostring(os.time())
	local temp = string.format("%s.%s", RESTART_PENDING_FILE, pid)
	local ok = fs.writefile(temp, tostring(os.time()) .. "\n")
	if ok then
		ok = os.rename(temp, RESTART_PENDING_FILE) and true or false
	end
	if not ok then
		fs.remove(temp)
	end
	return ok
end

local function config_audit(message)
	local f = io.open("/tmp/vnt2-download.log", "a")
	if f then
		f:write(os.date("%Y-%m-%d %H:%M:%S") .. " config : " .. message .. "\n")
		f:close()
	end
end

function act_toml_read()
	-- Reload prefers the runtime TOML: the complete config the client
	-- actually loaded. Fall back to a UCI serialization when the file has
	-- not been generated yet (client never started).
	local content = nil
	local source = "uci"
	if fs.access(RUNTIME_TOML_FILE) then
		local stat = fs.stat(RUNTIME_TOML_FILE)
		if stat and stat.type == "reg" and (tonumber(stat.size) or 0) > 0 then
			content = textutil.sanitize_text(fs.readfile(RUNTIME_TOML_FILE) or "")
			source = "file"
		end
	end
	if content == nil or content == "" then
		content = textutil.sanitize_text(toml_serialize_uci())
	end

	json_write({ ok = true, content = content, source = source })
end

function act_toml_save()
	local content = http.formvalue("content")
	if type(content) == "table" then
		content = table.concat(content, "\n")
	end
	content = tostring(content or ""):gsub("%z", "")

	if trim(content) == "" then
		json_write({ ok = false, error = "配置内容不能为空" })
		return
	end

	local values, err, unknown = toml_parse_config(content)
	if not values then
		json_write({ ok = false, error = err })
		return
	end

	local ok, applied_or_err = toml_apply_to_uci(values)
	if not ok then
		json_write({ ok = false, error = applied_or_err })
		return
	end

	config_audit("编辑配置保存：部分合并 " .. tostring(applied_or_err) .. " 个键（其余保持不变）")

	local restart_queued = queue_restart()
	local hint = "已保存：部分合并 " .. tostring(applied_or_err) .. " 个键，其余键保持不变。"
	if restart_queued then
		hint = hint .. "后台将重启客户端使配置生效。"
	else
		hint = hint .. "排队重启失败，请手动重启客户端。"
	end
	if #unknown > 0 then
		hint = hint .. "已忽略未知字段：" .. table.concat(unknown, "、") .. "。"
	end

	json_write({ ok = true, hint = hint })
end
