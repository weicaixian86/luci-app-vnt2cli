local http = require "luci.http"
local fs = require "nixio.fs"
local nixio = require "nixio"
local util = require "luci.util"
local uci = require "luci.model.uci".cursor()

local UPLOAD_DIR = "/etc/vnt2/upload"
local UPLOAD_PENDING_FILE = "/etc/vnt2/upload.pending"
local CONFIG_DIR = "/vnt_config"
local MAX_UPLOAD_SIZE = 256 * 1024 * 1024

local m = Map("vnt2")

m:section(SimpleSection).template = "vnt2/vnt2_status"

local function trim(v)
	if v == nil then
		return ""
	end

	local t = type(v)
	if t == "string" then
		return util.trim(v)
	end

	if t == "number" or t == "boolean" then
		return util.trim(tostring(v))
	end

	return ""
end

-- CBI validators may need values from sibling fields in the same form post.
local cbi_options = {}


local function add_file_upload_handler(note_options)
	local fd, uploaded_name, staged_path, upload_size, upload_rejected
	local stat = fs.readfile("/proc/self/stat") or ""
	local pid = stat:match("^(%d+)") or tostring(os.time())

	local function set_note(message)
		for _, opt in ipairs(note_options or {}) do
			opt.value = message
		end
	end

	local function write_atomic(path, value)
		local temp = string.format("%s.%s.%s", path, pid, tostring(os.time()))
		if not fs.writefile(temp, value) then
			fs.remove(temp)
			return false
		end
		if not fs.chmod(temp, "0600") then
			fs.remove(temp)
			return false
		end
		if not os.rename(temp, path) then
			fs.remove(temp)
			return false
		end
		return true
	end

	local function new_staged_path()
		local base = string.format("%s/incoming.%s.%s", UPLOAD_DIR, pid, tostring(os.time()))
		local suffix = 0
		local path = base

		while fs.access(path) do
			suffix = suffix + 1
			path = string.format("%s.%s", base, tostring(suffix))
		end
		return path
	end

	if fs.mkdirr(UPLOAD_DIR) == nil then
		fs.mkdirr(UPLOAD_DIR)
	end
	fs.chmod(UPLOAD_DIR, "0700")

	http.setfilehandler(function(meta, chunk, eof)
		if not fd then
			if not meta then
				return
			end

			local raw_name = tostring(meta.file or "")
			uploaded_name = raw_name:match("([^/\\]+)$") or raw_name
			uploaded_name = uploaded_name:gsub("[\r\n%z]", "")
			uploaded_name = uploaded_name:gsub("[^%w%._-]", "_")
			if uploaded_name == "" then
				return
			end

			staged_path = new_staged_path()
			upload_size = 0
			upload_rejected = false
			fd = nixio.open(staged_path, "w")
			if not fd then
				set_note(translate("错误：无法创建上传暂存文件"))
				return
			end
		end

		if chunk and fd then
			upload_size = upload_size + #chunk
			if upload_size > MAX_UPLOAD_SIZE then
				upload_rejected = true
				fd:close()
				fd = nil
				fs.remove(staged_path)
				set_note(translate("错误：上传文件超过 256 MiB 限制"))
			else
				fd:write(chunk)
			end
		end

		if eof and fd then
			fd:close()
			fd = nil

			if upload_rejected then
				return
			end

			if not fs.chmod(staged_path, "0600") then
				fs.remove(staged_path)
				set_note(translate("错误：无法保护上传暂存文件"))
				return
			end

			local marker = string.format(
				"time=%s\npath=%s\nname=%s\nsize=%s\n",
				tostring(os.time()),
				staged_path,
				uploaded_name,
				tostring(upload_size or 0)
			)
			if not write_atomic(UPLOAD_PENDING_FILE, marker) then
				fs.remove(staged_path)
				set_note(translate("错误：无法排队后台上传任务"))
				return
			end

			set_note(translate("上传文件已接收并进入后台处理队列，请查看运行日志获取安装结果。"))
		end
	end)
end

local function validate_nonempty(self, value)
	value = trim(value)
	if value == "" then
		return nil, translate("该字段不能为空")
	end
	return value
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

local function bind_download_mirror(option)
	option:value("auto", translate("自动"))
	option:value("gh-proxy", "gh-proxy")
	option:value("github", "GitHub")
	-- Keep legacy values visible for existing UCI configurations; init normalizes them.
	option:value("gitee", "Gitee")
	option:value("gitlab", "GitLab")
	option:value("cloudflare", "Cloudflare R2")
	option:value("custom", translate("自定义"))
	option.default = "auto"
	option.rmempty = false
end

local function bind_custom_download_mirror(option, mirror_option)
	option:depends(mirror_option, "custom")
	option.placeholder = "https://gh-proxy.com/"
	option.validate = function(self, value)
		value = trim(value)
		if value == "" then
			return nil, translate("选择自定义镜像源时必须填写镜像源地址")
		end
		if not value:match("^https?://[^%s]+/?$") then
			return nil, translate("自定义镜像源地址必须以 http:// 或 https:// 开头，且不能包含空格")
		end
		return value
	end
end

-- ==================== vnt2_cli ====================
;(function()
local w = m:section(TypedSection, "vnt2_cli", translate("vnt2_cli 客户端设置"))
w.anonymous = true
w.addremove = false

w:tab("general", translate("基本设置"))
w:tab("upload", translate("上传程序"))

local enabled = w:taboption("general", Flag, "enabled", translate("启用vnt2_cli 客户端"))
enabled.rmempty = false
enabled.default = "0"
enabled.description = translate("启用后按下方选定的 TOML 配置启动 vnt2_cli；保存应用由后台 worker 完成重启")
enabled.write = function(self, section, value)
	self.map.uci:set(self.map.config, section, self.option, value)
end

local conf_path = w:taboption("general", DummyValue, "_conf_path", translate("配置文件路径"))
conf_path.cfgvalue = function()
	return "/vnt_config/*.toml"
end
conf_path.description = translate("运行时配置目录固定为 /vnt_config；请在“配置管理”页新建、编辑 TOML 配置")

local conf_file = w:taboption("general", ListValue, "conf_file", translate("启用配置文件"))
conf_file.rmempty = true
conf_file:value("", translate("- 未选择 -"))
local conf_options = list_toml_configs()
local active_conf = uci:get_first("vnt2", "vnt2_cli", "conf_file")
local active_listed = false
for _, name in ipairs(conf_options) do
	conf_file:value(name, name)
	if name == active_conf then
		active_listed = true
	end
end
if active_conf and active_conf ~= "" and not active_listed then
	-- Keep a configured file that vanished from /vnt_config visible instead of
	-- silently dropping it from the selector.
	conf_file:value(active_conf, active_conf .. " (" .. translate("文件缺失") .. ")")
end
if #conf_options == 0 then
	conf_file.description = translate("配置目录为空：请先前往“配置管理”页新建一个 TOML 配置，再回到此处选择启用")
else
	conf_file.description = translate("同一时刻只有一个 TOML 配置被 vnt2_cli 加载；切换后由后台 worker 重启生效")
end

local ctrl_port = w:taboption("general", Value, "ctrl_port", translate("控制端口"))
ctrl_port.placeholder = "11233"
ctrl_port.datatype = "port"
ctrl_port.description = translate("vnt2_cli 控制服务仅监听 127.0.0.1，状态页通过 vnt2_ctrl 查询运行信息")

local vnt2_cli_bin = w:taboption("general", Value, "vnt2_cli_bin", translate("vnt2_cli 程序路径"))
vnt2_cli_bin.placeholder = "/usr/bin/vnt2_cli"
vnt2_cli_bin.validate = validate_nonempty

local log_level = w:taboption("general", ListValue, "log_level", translate("日志级别"))
log_level.description = nil
for _, lv in ipairs({ "error", "warn", "info", "debug", "trace" }) do
	log_level:value(lv, lv)
end
log_level.default = "info"

local download_mirror = w:taboption("general", ListValue, "download_mirror", translate("下载镜像源"))
bind_download_mirror(download_mirror)
local custom_download_mirror = w:taboption("general", Value, "custom_download_mirror", translate("自定义镜像地址"))
bind_custom_download_mirror(custom_download_mirror, "download_mirror")

local cli_upload = w:taboption("upload", FileUpload, "upload_cli")
cli_upload.optional = true
cli_upload.default = ""
cli_upload.template = "vnt2/other_upload"

local cli_upload_note = w:taboption("upload", DummyValue, "_upload_note_cli")
cli_upload_note.rawhtml = true
cli_upload_note.template = "vnt2/other_dvalue"
cbi_options.cli_upload_note = cli_upload_note
end)()


add_file_upload_handler({
	cbi_options.cli_upload_note
})

return m
