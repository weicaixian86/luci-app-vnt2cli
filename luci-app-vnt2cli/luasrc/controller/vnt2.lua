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
local CONFIG_DIR = "/vnt_config"

function index()
	if not fs.access("/etc/config/vnt2") then
		return
	end

	entry({ "admin", "vpn", "vnt2" }, alias("admin", "vpn", "vnt2", "config"), _("VNT2"), 45).dependent = true
	entry({ "admin", "vpn", "vnt2", "config" }, cbi("vnt2"), _("基本设置"), 10).leaf = true
	entry({ "admin", "vpn", "vnt2", "file" }, template("vnt2/vnt2_config"), _("配置管理"), 20).leaf = true
	entry({ "admin", "vpn", "vnt2", "runtime_log" }, cbi("vnt2_runtime_log"), _("运行日志"), 30).leaf = true

	entry({ "admin", "vpn", "vnt2", "status" }, call("act_status")).leaf = true
	entry({ "admin", "vpn", "vnt2", "ctrl_query" }, call("act_ctrl_query")).leaf = true
	entry({ "admin", "vpn", "vnt2", "get_runtime_log" }, call("get_runtime_log")).leaf = true
	entry({ "admin", "vpn", "vnt2", "clear_runtime_log" }, call("clear_runtime_log")).leaf = true
	entry({ "admin", "vpn", "vnt2", "config_list" }, call("act_config_list")).leaf = true
	entry({ "admin", "vpn", "vnt2", "config_read" }, call("act_config_read")).leaf = true
	entry({ "admin", "vpn", "vnt2", "config_save" }, call("act_config_save")).leaf = true
	entry({ "admin", "vpn", "vnt2", "config_delete" }, call("act_config_delete")).leaf = true
	entry({ "admin", "vpn", "vnt2", "config_use" }, call("act_config_use")).leaf = true
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

local function get_active_conf()
	return uci_first("vnt2_cli", "conf_file", "")
end

local function is_safe_toml_name(name)
	if type(name) ~= "string" or name == "" or #name > 255 then
		return false
	end
	if not name:match("%.toml$") then
		return false
	end
	if name:sub(1, 1) == "." then
		return false
	end
	if name:find("..", 1, true) or name:find("/", 1, true) or name:find("\\", 1, true) then
		return false
	end
	if not name:match("^[%w%._%-]+$") then
		return false
	end
	return true
end

local function list_toml_configs()
	local out = {}

	if not fs.access(CONFIG_DIR) then
		return out
	end

	for name in fs.dir(CONFIG_DIR) do
		local path = CONFIG_DIR .. "/" .. name
		if is_safe_toml_name(name) then
			local stat = fs.stat(path)
			if stat and stat.type == "reg" then
				out[#out + 1] = name
			end
		end
	end
	table.sort(out)
	return out
end

local function atomic_write_toml(path, content)
	local tmp = string.format("%s.%s.tmp", path, tostring(os.time()))
	if not fs.writefile(tmp, content) then
		fs.remove(tmp)
		return false
	end
	if not fs.chmod(tmp, "0600") then
		fs.remove(tmp)
		return false
	end
	if not os.rename(tmp, path) then
		fs.remove(tmp)
		return false
	end
	return true
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

local function set_conf_file(name)
	local section = uci:get_first("vnt2", "vnt2_cli")
	if not section then
		return false
	end
	if name and name ~= "" then
		uci:set("vnt2", section, "conf_file", name)
	else
		uci:delete("vnt2", section, "conf_file")
	end
	uci:commit("vnt2")
	return queue_restart()
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
	e.conf_file = get_active_conf()

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

function act_config_list()
	json_write({
		ok = true,
		active = get_active_conf(),
		configs = list_toml_configs()
	})
end

function act_config_read()
	local name = trim(http.formvalue("name") or "")
	if not is_safe_toml_name(name) then
		json_write({ ok = false, error = "配置文件名不安全" })
		return
	end

	local path = CONFIG_DIR .. "/" .. name
	local stat = fs.stat(path)
	if not stat or stat.type ~= "reg" then
		json_write({ ok = false, error = "配置文件不存在" })
		return
	end

	json_write({
		ok = true,
		name = name,
		active = get_active_conf() == name,
		content = textutil.sanitize_text(fs.readfile(path) or "")
	})
end

function act_config_save()
	local name = trim(http.formvalue("name") or "")
	local content = http.formvalue("content")
	if type(content) == "table" then
		content = table.concat(content, "\n")
	end
	content = tostring(content or ""):gsub("%z", "")

	local hint = ""

	if not is_safe_toml_name(name) then
		json_write({ ok = false, error = "配置文件名不安全：只能包含字母、数字、点、下划线、短横线，且以 .toml 结尾" })
		return
	end
	if trim(content) == "" then
		json_write({ ok = false, error = "配置内容不能为空" })
		return
	end
	if content:match("^%s*ctrl_port%s*=") or content:match("[\r\n]%s*ctrl_port%s*=") then
		hint = "检测到 TOML 中的 ctrl_port 字段：启动时插件会以命令行 --ctrl-port 覆盖该值。"
	end
	hint = hint .. "仅执行基础校验（文件名/非空），TOML 语法错误会在客户端运行日志中体现。"

	if not fs.access(CONFIG_DIR) then
		fs.mkdirr(CONFIG_DIR)
	end
	fs.chmod(CONFIG_DIR, "0700")

	local path = CONFIG_DIR .. "/" .. name
	local existed = fs.access(path) and true or false
	if not atomic_write_toml(path, content) then
		json_write({ ok = false, error = "保存配置失败" })
		return
	end

	json_write({ ok = true, name = name, overwrite = existed, hint = hint })
end

function act_config_delete()
	local name = trim(http.formvalue("name") or "")
	if not is_safe_toml_name(name) then
		json_write({ ok = false, error = "配置文件名不安全" })
		return
	end

	local path = CONFIG_DIR .. "/" .. name
	local stat = fs.stat(path)
	if not stat or stat.type ~= "reg" then
		json_write({ ok = false, error = "配置文件不存在" })
		return
	end

	if not fs.remove(path) then
		json_write({ ok = false, error = "删除配置失败" })
		return
	end

	if get_active_conf() == name then
		set_conf_file("")
	else
		queue_restart()
	end

	json_write({ ok = true, name = name })
end

function act_config_use()
	local name = trim(http.formvalue("name") or "")
	if not is_safe_toml_name(name) then
		json_write({ ok = false, error = "配置文件名不安全" })
		return
	end

	local path = CONFIG_DIR .. "/" .. name
	local stat = fs.stat(path)
	if not stat or stat.type ~= "reg" then
		json_write({ ok = false, error = "配置文件不存在" })
		return
	end

	if not set_conf_file(name) then
		json_write({ ok = false, error = "切换启用配置失败" })
		return
	end

	json_write({ ok = true, name = name })
end
