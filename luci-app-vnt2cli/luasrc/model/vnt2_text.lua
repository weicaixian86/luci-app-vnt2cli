local fs = require "nixio.fs"
local sys = require "luci.sys"
local util = require "luci.util"

local M = {}
local tail_available = sys.call("command -v tail >/dev/null 2>&1") == 0

local mojibake_markers = {
	string.char(233, 150, 186, 63),
	string.char(233, 151, 129, 63),
	string.char(230, 191, 160, 63),
	string.char(230, 191, 158, 63),
	string.char(230, 191, 161, 63),
	string.char(233, 151, 130, 63),
	string.char(233, 150, 187, 63),
	string.char(231, 188, 130, 63),
	string.char(233, 150, 184, 63),
	string.char(231, 128, 185, 63),
	string.char(229, 169, 181, 63),
	string.char(233, 144, 160, 63),
	string.char(231, 188, 129, 63)
}

local function iconv_available()
	return sys.call("command -v iconv >/dev/null 2>&1") == 0
end

local function run_iconv_command(cmd)
	if not iconv_available() then
		return nil
	end

	local repaired = sys.exec(cmd)
	if repaired and repaired ~= "" then
		return repaired
	end

	return nil
end

local log_message_exact_map = {
	["start failed: missing executable vnt2_cli"] = "启动失败：缺少可执行文件 vnt2_cli",
	["start failed: runtime toml export failed"] = "启动失败：运行配置导出失败",
	["client disabled; runtime toml export failed"] = "客户端已停用；运行配置导出失败，保留原运行配置文件",
	["export failed: client config missing network_code and subscription"] = "导出失败：客户端配置缺少 network_code 和 subscription",
	["export failed: tunnel_addr and tunnel_port are mutually exclusive"] = "导出失败：tunnel_addr 与 tunnel_port 互斥，不能同时填写",
	["export failed: unable to publish runtime toml"] = "导出失败：无法写入运行配置文件",
	["control tool vnt2_ctrl is missing or invalid; status page will show control info as unavailable"] = "控制工具 vnt2_ctrl 缺失或无效，状态页控制信息将显示为不可用",
	["service start flow begin"] = "服务启动流程开始",
	["vnt2_cli config section not found"] = "未找到 vnt2_cli 配置节",
	["start_service finished"] = "服务启动流程结束",
	["service stop flow begin"] = "服务停止流程开始",
	["service stopped"] = "服务已停止",
	["bundle missing vnt2_cli"] = "压缩包中缺少 vnt2_cli",
	["bundle binaries are not valid ELF files"] = "压缩包中的程序不是有效的 ELF 文件",
	["install bundle to /usr/bin failed"] = "安装程序包到 /usr/bin 失败"
}

local log_message_pattern_rules = {
	{ "^starting (.+) with config (.+)$", "正在启动 %1，配置文件：%2" },
	{ "^runtime toml exported: (.+)$", "运行配置已导出：%1" },
	{ "^using (.+) ctrl=(.+) port=(.+) conf=(.+)$", "使用 %1 控制工具 %2 控制端口 %3 配置文件：%4" },
	{ "^checking (.+) releases list: (.+)$", "正在检查 %1 的 Releases 列表：%2" },
	{ "^checking release endpoint: (.+)$", "正在检查发布接口：%1" },
	{ "^checking releases list: (.+)$", "正在检查 Releases 列表：%1" },
	{ "^failed to create install directory (.+)$", "创建安装目录失败：%1" },
	{ "^failed to copy binary to (.+) from (.+)$", "复制程序失败：目标=%1 来源=%2" },
	{ "^failed to chmod binary (.+)$", "设置程序执行权限失败：%1" },
	{ "^binary not found after install (.+)$", "安装后未找到程序：%1" },
	{ "^mirror (.+) not supported for repo (.+), fallback to (.+)$", "镜像 %1 不支持仓库 %2，已回退到 %3" },
	{ "^mirror strategy (.+) not supported for repo (.+), fallback to github$", "镜像策略 %1 不支持仓库 %2，已回退到 GitHub" },
	{ "^cached bundle found, reuse (.+)$", "发现缓存程序包，复用目录：%1" },
	{ "^query target release repo=(.+) tag=(.+) arch=(.+) scope=(.+)$", "准备查询发行版：repo=%1 tag=%2 arch=%3 scope=%4" },
	{ "^querying (.+) release repo=(.+) tag=(.+) mirror=(.+) strategy=(.+) arch=(.+)$", "正在查询 %1 发行版：repo=%2 tag=%3 mirror=%4 strategy=%5 arch=%6" },
	{ "^release query failed repo=(.+) tag=(.+) mirror=(.+)$", "发行版查询失败：repo=%1 tag=%2 mirror=%3" },
	{ "^release query ok: (.+)$", "发行版查询成功：%1" },
	{ "^no release asset matched arch=(.+) scope=(.+) mirror=(.+)$", "未找到匹配的发行资源：arch=%1 scope=%2 mirror=%3" },
	{ "^selected asset (.+) mirror=(.+)$", "已选择发行资源：%1 mirror=%2" },
	{ "^selected asset (.+)$", "已选择发行资源：%1" },
	{ "^reusing downloaded asset (.+)$", "复用已下载资源：%1" },
	{ "^cached asset invalid, remove and redownload (.+)$", "缓存资源无效，已删除并重新下载：%1" },
	{ "^asset download started tool=(.+) timeout=(.+) mirror=(.+) file=(.+)$", "开始下载资源：工具=%1 超时=%2 mirror=%3 文件=%4" },
	{ "^asset download failed tool=(.+) rc=(.+) received=(.+) mirror=(.+) used_url=(.+)$", "资源下载失败：工具=%1 返回码=%2 已接收=%3 mirror=%4 地址=%5" },
	{ "^asset download ok tool=(.+) used_url=(.+) mirror=(.+) file=(.+)$", "资源下载完成：工具=%1 地址=%2 mirror=%3 文件=%4" },
	{ "^asset download failed tool=(.+) mirror=(.+) url=(.+)$", "资源下载失败：工具=%1 mirror=%2 地址=%3" },
	{ "^asset download failed tool=(.+) url=(.+)$", "资源下载失败：工具=%1 地址=%2" },
	{ "^downloaded release asset invalid or corrupted scope=(.+) file=(.+) size=(.+) mirror=(.+)$", "已下载资源无效或损坏：scope=%1 文件=%2 大小=%3 mirror=%4" },
	{ "^downloaded asset invalid or corrupted (.+)$", "已下载资源无效或已损坏：%1" },
	{ "^extract failed, remove cache and switch mirror (.+)$", "解压失败，已删除缓存并切换镜像：%1" },
	{ "^extract failed, remove cache and retry (.+)$", "解压失败，已删除缓存并重试：%1" },
	{ "^retry asset download failed tool=(.+) mirror=(.+) url=(.+)$", "重试下载资源失败：工具=%1 mirror=%2 地址=%3" },
	{ "^retry asset download failed tool=(.+) url=(.+)$", "重试下载资源失败：工具=%1 地址=%2" },
	{ "^retried asset still invalid (.+)$", "重试后资源仍然无效：%1" },
	{ "^extract asset failed (.+)$", "解压资源失败：%1" },
	{ "^bundle missing vnt2_cli mirror=(.+)$", "压缩包中缺少 vnt2_cli：mirror=%1" },
	{ "^bundle missing vnt2_ctrl mirror=(.+)$", "压缩包中缺少 vnt2_ctrl：mirror=%1" },
	{ "^bundle binaries are not valid ELF files mirror=(.+)$", "压缩包中的程序不是有效的 ELF 文件：mirror=%1" },
	{ "^bundle installed: cli=(.+) ctrl=(.+) mirror=(.+) url=(.+)$", "程序安装完成：cli=%1 ctrl=%2 mirror=%3 地址=%4" },
	{ "^upload rejected: archive does not contain vnt2_cli$", "上传被拒绝：压缩包中不包含 vnt2_cli" },
	{ "^upload failed: extracted vnt2_cli is not a valid ELF binary$", "上传失败：解压出的 vnt2_cli 不是有效的 ELF 程序" },
	{ "^upload note: archive has no vnt2_ctrl; kept existing control tool$", "上传提示：压缩包中没有 vnt2_ctrl，已保留现有控制工具" },
	{ "^upload warning: extracted vnt2_ctrl is not a valid ELF binary; kept existing control tool$", "上传警告：解压出的 vnt2_ctrl 不是有效的 ELF 程序，已保留现有控制工具" },
	{ "^all download mirrors failed repo=(.+) tag=(.+) strategy=(.+) arch=(.+) scope=(.+)$", "所有下载镜像均失败：repo=%1 tag=%2 strategy=%3 arch=%4 scope=%5" },
	{ "^(.+) auto download failed, fallback to uploaded binary (.+)$", "%1 自动下载失败，已回退到已上传程序：%2" }
}

function M.sanitize_text(content)
	content = tostring(content or "")
	content = content:gsub("\27%[[%d;?]*[%a]", "")
	content = content:gsub("\27%][^\7]*\7", "")
	content = content:gsub("%z", "")
	content = content:gsub("\r", "")
	return content
end

function M.translate_log_message(message)
	message = tostring(message or "")
	if message == "" then
		return message
	end

	if log_message_exact_map[message] then
		return log_message_exact_map[message]
	end

	for _, rule in ipairs(log_message_pattern_rules) do
		local translated, count = message:gsub(rule[1], rule[2])
		if count > 0 then
			return translated
		end
	end

	return message
end

function M.translate_log_text(content)
	content = tostring(content or "")
	if content == "" then
		return content
	end

	local has_trailing_newline = content:sub(-1) == "\n"
	local lines = {}

	for line in (content .. "\n"):gmatch("(.-)\n") do
		local prefix, message = line:match("^(.- : )(.*)$")
		if prefix then
			lines[#lines + 1] = prefix .. M.translate_log_message(message)
		else
			lines[#lines + 1] = M.translate_log_message(line)
		end
	end

	local translated = table.concat(lines, "\n")
	if not has_trailing_newline and translated:sub(-1) == "\n" then
		translated = translated:sub(1, -2)
	end
	return translated
end

function M.looks_like_mojibake(content)
	content = tostring(content or "")
	if content == "" then
		return false
	end

	for _, marker in ipairs(mojibake_markers) do
		if content:find(marker, 1, true) then
			return true
		end
	end

	return false
end

function M.repair_mojibake_text(content)
	content = tostring(content or "")
	if content == "" or not M.looks_like_mojibake(content) then
		return content
	end

	local repaired = run_iconv_command(string.format(
		"printf '%%s' %s | iconv -f UTF-8 -t GB18030 2>/dev/null",
		util.shellquote(content)
	))
	return repaired or content
end

function M.read_text_file(path)
	local content = path and path ~= "" and fs.access(path) and (fs.readfile(path) or "") or ""
	if content ~= "" and path and path ~= "" and M.looks_like_mojibake(content) then
		local repaired = run_iconv_command(string.format(
			"iconv -f UTF-8 -t GB18030 %s 2>/dev/null",
			util.shellquote(path)
		))
		if repaired then
			content = repaired
		end
	end

	return M.sanitize_text(content)
end

function M.normalize_text(content)
	return M.sanitize_text(M.repair_mojibake_text(content))
end

function M.normalize_log_text(content)
	return M.translate_log_text(M.normalize_text(content))
end

local function keep_last_lines(content, max_lines)
	content = tostring(content or "")
	max_lines = tonumber(max_lines or 0) or 0
	if max_lines <= 0 or content == "" then
		return content
	end

	local has_trailing_newline = content:sub(-1) == "\n"
	local lines = {}
	for line in (content .. "\n"):gmatch("(.-)\n") do
		lines[#lines + 1] = line
	end

	if has_trailing_newline and lines[#lines] == "" then
		table.remove(lines, #lines)
	end

	if #lines <= max_lines then
		return table.concat(lines, "\n") .. (has_trailing_newline and #lines > 0 and "\n" or "")
	end

	local start_idx = #lines - max_lines + 1
	local out = {}
	for i = start_idx, #lines do
		out[#out + 1] = lines[i]
	end

	return table.concat(out, "\n") .. (has_trailing_newline and #out > 0 and "\n" or "")
end

function M.read_log_file(path, max_lines)
	local limit = tonumber(max_lines or 0) or 0
	if limit <= 0 then
		return M.normalize_log_text(M.read_text_file(path))
	end

	local content = ""
	if path and path ~= "" and fs.access(path) then
		if tail_available then
			content = sys.exec(string.format("tail -n %d %s 2>/dev/null", limit, util.shellquote(path))) or ""
		end
		if content == "" then
			content = keep_last_lines(M.read_text_file(path), limit)
			return M.normalize_log_text(content)
		end
	end

	return M.normalize_log_text(content)
end

local function log_timestamp(line)
	return tostring(line or ""):match("^(%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d)") or ""
end

local function append_log_record(records, record)
	if record and #record.lines > 0 then
		record.order = #records + 1
		record.text = table.concat(record.lines, "\n")
		record.lines = nil
		records[#records + 1] = record
	end
end

local function parse_log_records(content, records)
	local current

	for line in (tostring(content or "") .. "\n"):gmatch("(.-)\n") do
		if line ~= "" then
			local timestamp = log_timestamp(line)
			if timestamp ~= "" then
				append_log_record(records, current)
				current = { timestamp = timestamp, lines = { line } }
			elseif current then
				current.lines[#current.lines + 1] = line
			else
				-- A tail can begin in the middle of a multiline error. Keep that
				-- continuation together instead of sorting each line separately.
				current = { timestamp = "", lines = { line } }
			end
		end
	end

	append_log_record(records, current)
end

function M.merge_log_files(paths, max_lines)
	local records = {}
	for _, path in ipairs(paths or {}) do
		parse_log_records(M.read_log_file(path, max_lines), records)
	end

	table.sort(records, function(a, b)
		if a.timestamp == b.timestamp then
			return a.order < b.order
		end
		if a.timestamp == "" then
			return true
		end
		if b.timestamp == "" then
			return false
		end
		return a.timestamp < b.timestamp
	end)

	local output = {}
	for _, record in ipairs(records) do
		output[#output + 1] = record.text
	end
	return table.concat(output, "\n")
end


-- ---------- 编辑配置：UCI <-> TOML 文本往返 ----------
-- Shared by the controller endpoint and the settings model: the editor never
-- touches /tmp/vnt2cli.toml itself (that file is re-exported from UCI on every
-- start). Saving is a partial merge - only keys present in the text are
-- written back to UCI, every other key keeps its value.

local function trim(value)
	return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

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

function M.toml_serialize_uci(uci)
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

function M.toml_parse_config(text)
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

local function toml_list_equal(current, items)
	local cur = {}
	if type(current) == "table" then
		for _, item in ipairs(current) do
			item = trim(item)
			if item ~= "" then
				cur[#cur + 1] = item
			end
		end
	elseif current ~= nil and trim(tostring(current)) ~= "" then
		cur[#cur + 1] = trim(tostring(current))
	end

	if #cur ~= #items then
		return false
	end
	for i, item in ipairs(items) do
		if cur[i] ~= item then
			return false
		end
	end
	return true
end

function M.toml_apply_to_uci(uci, values)
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

	-- Partial merge: only keys present in the text are considered, and only
	-- keys whose value actually differs are written; the stored configuration
	-- is never touched by a save that changes nothing.
	local applied = 0
	for _, key in ipairs(TOML_EDIT_KEY_ORDER) do
		local value = values[key]
		if value ~= nil then
			if TOML_EDIT_BOOL_KEYS[key] then
				local want = (value == true) and "1" or "0"
				if uci:get("vnt2", section, key) ~= want then
					uci:set("vnt2", section, key, want)
					applied = applied + 1
				end
			elseif TOML_EDIT_NUM_KEYS[key] then
				local want = tostring(value)
				if uci:get("vnt2", section, key) ~= want then
					uci:set("vnt2", section, key, want)
					applied = applied + 1
				end
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
				if not toml_list_equal(uci:get("vnt2", section, key), items) then
					uci:delete("vnt2", section, key)
					if #items > 0 then
						uci:set_list("vnt2", section, key, items)
					end
					applied = applied + 1
				end
			else
				local s = trim(tostring(value))
				if s == "" then
					local cur = uci:get("vnt2", section, key)
					if cur ~= nil and cur ~= "" then
						uci:delete("vnt2", section, key)
						applied = applied + 1
					end
				elseif uci:get("vnt2", section, key) ~= s then
					uci:set("vnt2", section, key, s)
					applied = applied + 1
				end
			end
		end
	end

	if applied > 0 then
		uci:commit("vnt2")
	end
	return true, applied
end

return M
