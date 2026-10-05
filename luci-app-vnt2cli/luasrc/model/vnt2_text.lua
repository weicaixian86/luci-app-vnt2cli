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

return M
