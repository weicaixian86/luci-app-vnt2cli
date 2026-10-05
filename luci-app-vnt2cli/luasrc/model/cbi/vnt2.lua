local http = require "luci.http"
local fs = require "nixio.fs"
local nixio = require "nixio"
local util = require "luci.util"
local textutil = require "luci.model.vnt2_text"

local UPLOAD_DIR = "/etc/vnt2/upload"
local UPLOAD_PENDING_FILE = "/etc/vnt2/upload.pending"
local MAX_UPLOAD_SIZE = 256 * 1024 * 1024

local m = Map("vnt2")

-- Page-scoped CSS: pull the label column back to the left edge so the form
-- rows start at the section border instead of after a wide empty gutter.
m:section(SimpleSection).template = "vnt2/vnt2_form_css"

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

-- Options whose stored value the request explicitly cleared. The post-save
-- audit restores every other list that lost its value during the save.
local authorized_clear = {}
local list_options = {}

-- Bumped whenever the save path changes. Every form save logs it, so a report
-- can be matched against the code that produced it instead of guessing which
-- build the device is running.
local FORM_BUILD = "2026-10-05.7"

-- Audit trail for config mutations: when a populated list gets cleared the
-- running log records who did it, so silent losses are diagnosable.
local function dump_posted(value)
	if type(value) == "table" then
		local items = {}
		for i, item in ipairs(value) do
			items[i] = tostring(item)
		end
		return "[" .. table.concat(items, "|") .. "]"
	end
	return tostring(value)
end

-- Diagnostic: every key of this request that belongs to one widget. Knowing
-- which of <cbid>, <cbid>.__stored, <cbid>.__empty and <cbid>.__diag actually
-- arrived tells whether the browser hydrated the widget, which is impossible
-- to infer on the server side alone.
local function dump_post_keys(map, prefix)
	local keys = {}
	local ok, values = pcall(map.formvaluetable, map, prefix)
	if ok and type(values) == "table" then
		for key in pairs(values) do
			keys[#keys + 1] = tostring(key)
		end
	end
	table.sort(keys)
	return "{" .. table.concat(keys, ",") .. "}"
end
local function config_audit(message)
	local f = io.open("/tmp/vnt2-download.log", "a")
	if f then
		f:write(os.date("%Y-%m-%d %H:%M:%S") .. " config : " .. message .. "\n")
		f:close()
	end
end

-- Cheap deterministic fingerprint of a blob of text, exported by vnt2_text so
-- templates can stamp the text they render.


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

local function normalized_list_values(value)
	local result = {}

	if type(value) == "string" then
		value = { value }
	end

	if type(value) ~= "table" then
		return result
	end

	for _, item in ipairs(value) do
		item = trim(item)
		if item ~= "" then
			result[#result + 1] = item
		end
	end

	return result
end

-- The page script reports a widget's item list as one value per line.
local function split_posted_values(value)
	if value == nil then
		return {}
	end

	local result = {}
	for line in tostring(value):gmatch("[^\r\n]+") do
		line = trim(line)
		if line ~= "" then
			result[#result + 1] = line
		end
	end
	return result
end

local function option_is_empty(value)
	if value == nil then
		return true
	end
	if type(value) == "table" then
		return #normalized_list_values(value) == 0
	end
	return trim(value) == ""
end

-- Compact single-line rendering of a value for the save audit. Secrets are
-- only reported by length so an audit line never leaks them into the log.
local function audit_value(option, value)
	if option == "password" or option == "subscription" then
		if option_is_empty(value) then
			return "空"
		end
		return "已设置(" .. #tostring(type(value) == "table" and (value[1] or "") or value) .. ")"
	end
	if type(value) == "table" then
		return "[" .. table.concat(normalized_list_values(value), "|") .. "]"
	end
	return tostring(value)
end

local function same_list(a, b)
	if #a ~= #b then
		return false
	end
	for i = 1, #a do
		if a[i] ~= b[i] then
			return false
		end
	end
	return true
end

local function validate_server_item(value, allow_udp)
	value = trim(value)
	if value == "" then
		return value
	end

	local scheme = value:match("^([a-zA-Z][a-zA-Z0-9+.-]*)://")
	local address = value
	if scheme then
		scheme = scheme:lower()
		if scheme ~= "quic" and scheme ~= "tcp" and scheme ~= "wss" and scheme ~= "dynamic"
			and not (allow_udp and scheme == "udp") then
			if allow_udp then
				return nil, translate("直连节点地址协议仅支持 tcp、udp 或 dynamic")
			end
			return nil, translate("服务器地址协议仅支持 quic、tcp、wss 或 dynamic")
		end
		if scheme == "dynamic" then
			return value:match("^dynamic://.+$") and value or nil, translate("dynamic 地址不能为空")
		end
		address = value:gsub("^[a-zA-Z][a-zA-Z0-9+.-]*://", "")
	end

	if address:match("^%d+%.%d+%.%d+%.%d+:%d+$")
		or address:match("^%[[0-9a-fA-F:]+%]:%d+$")
		or address:match("^[%w._-]+:%d+$") then
		return value
	end

	return nil, translate("地址格式错误，支持 host:port、IPv4:port、[IPv6]:port 或 quic://host:port 等格式")
end

local function validate_peer_address(self, value)
	if type(value) == "table" then
		local values = normalized_list_values(value)
		if #values == 0 then
			return {}
		end

		local result = {}
		for _, item in ipairs(values) do
			local valid, err = validate_server_item(item, true)
			if not valid then
				return nil, err
			end
			result[#result + 1] = valid
		end
		return result
	end

	value = trim(value)
	if value == "" then
		return value
	end

	return validate_server_item(value, true)
end

local function validate_server(self, value)
	if type(value) == "table" then
		local values = normalized_list_values(value)
		if #values == 0 then
			return {}
		end

		local result = {}
		for _, item in ipairs(values) do
			local valid, err = validate_server_item(item)
			if not valid then
				return nil, err
			end
			if valid ~= "" then
				result[#result + 1] = valid
			end
		end
		return result
	end

	value = trim(value)
	if value == "" then
		return value
	end

	return validate_server_item(value)
end

local function socket_port(value)
	value = trim(value)
	local port = value:match("^%[[^%]]+%]:(%d+)$") or value:match("^[^:]+:(%d+)$")
	port = tonumber(port or "")
	if port and port >= 0 and port <= 65535 then
		return port
	end
	return nil
end

local function is_ipv4(value)
	local count = 0
	for part in value:gmatch("[^%.]+") do
		count = count + 1
		if not part:match("^%d+$") or #part > 3 or tonumber(part) > 255 then
			return false
		end
	end
	return count == 4 and not value:match("^%.") and not value:match("%.$")
end

local function valid_ipv6_part(part)
	if part == "" or part:match("^:") or part:match(":$") then
		return false, 0
	end

	local count = 0
	for group in part:gmatch("[^:]+") do
		if group ~= "v" and not group:match("^[0-9a-fA-F]+$") then
			return false, 0
		end
		if group ~= "v" and #group > 4 then
			return false, 0
		end
		count = count + 1
	end
	return count > 0, count
end

local function is_ipv6(value)
	if not value:find(":", 1, true) then
		return false
	end

	local normalized = value
	if value:find(".", 1, true) then
		local prefix, suffix = value:match("^(.*:)([^:]+)$")
		if not prefix or not is_ipv4(suffix) then
			return false
		end
		normalized = prefix .. "v:v"
	end

	local left, right = normalized:match("^(.-)::(.-)$")
	if left ~= nil then
		if normalized:match("::.*::") then
			return false
		end
		local left_ok, left_count = valid_ipv6_part(left)
		local right_ok, right_count = valid_ipv6_part(right)
		if (left ~= "" and not left_ok) or (right ~= "" and not right_ok) then
			return false
		end
		return (left_count + right_count) < 8
	end

	if normalized:match("^:") or normalized:match(":$") then
		return false
	end
	local ok, count = valid_ipv6_part(normalized)
	return ok and count == 8
end

local function is_domain(value)
	if #value == 0 or #value > 253 then
		return false
	end
	if value:find("..", 1, true) then
		return false
	end
	for label in value:gmatch("[^%.]+") do
		if #label > 63 or label:match("^-") or label:match("-$")
			or not label:match("^[A-Za-z0-9-]+$") then
			return false
		end
	end
	return not value:match("^%.") and not value:match("%.$")
end

local function validate_cidr(self, value)
	value = trim(value)
	if value == "" then
		return value
	end

	local address, prefix = value:match("^(%d+%.%d+%.%d+%.%d+)/(%d+)$")
	if address and is_ipv4(address) and tonumber(prefix) <= 32 then
		return value
	end

	return nil, translate("CIDR 格式错误，例如 10.26.0.0/24")
end

local function ipv4_network_key(value)
	local address, prefix = value:match("^(%d+%.%d+%.%d+%.%d+)/(%d+)$")
	local a, b, c, d = address:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
	local ip = ((tonumber(a) * 256 + tonumber(b)) * 256 + tonumber(c)) * 256 + tonumber(d)
	local prefix_number = tonumber(prefix)
	local host_size = 2 ^ (32 - prefix_number)
	return math.floor(ip / host_size) * host_size .. "/" .. prefix
end

local function is_ipv4_or_cidr(value)
	return validate_cidr(nil, value) or trim(value):match("^%d+%.%d+%.%d+%.%d+$")
end

local function validate_turn_item(value)
	value = trim(value)
	if value == "" then
		return value
	end
	local target, relay = value:match("^([^,]+),([^,]+)$")
	if not target or not relay or not is_ipv4_or_cidr(target) or not is_ipv4(trim(relay)) then
		return nil, translate("格式错误，应为目标 IP/CIDR,转发服务器 IPv4 地址")
	end
	return value
end

local function validate_punch_model_item(value)
	value = trim(value)
	if value == "" then
		return value
	end
	local target, modes = value:match("^([^,]+),(.+)$")
	if not target or not is_ipv4_or_cidr(target) then
		return nil, translate("格式错误，应为目标 IP/CIDR,IPv4Tcp,IPv4Udp 等打洞模式")
	end
	for mode in modes:gmatch("[^,]+") do
		if mode ~= "IPv4Tcp" and mode ~= "IPv4Udp" and mode ~= "IPv6Tcp" and mode ~= "IPv6Udp" then
			return nil, translate("打洞模式仅支持 IPv4Tcp、IPv4Udp、IPv6Tcp、IPv6Udp")
		end
	end
	return value
end

local function validate_subnet_mapping_item(value)
	value = trim(value)
	if value == "" then
		return value
	end

	local first, second = value:match("^([^,]+),([^,]+)$")
	if not first or not second
		or not validate_cidr(nil, first) or not validate_cidr(nil, second) then
		return nil, translate("格式错误，应为映射 CIDR,实际 CIDR")
	end
	local _, mapped_prefix = first:match("^(%d+%.%d+%.%d+%.%d+)/(%d+)$")
	local _, actual_prefix = second:match("^(%d+%.%d+%.%d+%.%d+)/(%d+)$")
	if tonumber(mapped_prefix) ~= tonumber(actual_prefix) then
		return nil, translate("映射 CIDR 与实际 CIDR 的前缀长度必须相同")
	end
	if ipv4_network_key(first) == ipv4_network_key(second) then
		return nil, translate("映射网段与实际网段不能相同")
	end
	return value
end

local function validate_subnet_mapping(self, value)
	if type(value) ~= "table" then
		return validate_subnet_mapping_item(value)
	end

	local result = {}
	local mapped_to_actual = {}
	local actual_to_mapped = {}
	for _, item in ipairs(normalized_list_values(value)) do
		local valid, err = validate_subnet_mapping_item(item)
		if not valid then
			return nil, err
		end

		local mapped, actual = valid:match("^([^,]+),([^,]+)$")
		local mapped_key = ipv4_network_key(mapped)
		local actual_key = ipv4_network_key(actual)
		if mapped_to_actual[mapped_key] and mapped_to_actual[mapped_key] ~= actual_key then
			return nil, translate("存在冲突的映射网段")
		end
		if actual_to_mapped[actual_key] and actual_to_mapped[actual_key] ~= mapped_key then
			return nil, translate("存在冲突的实际网段映射")
		end
		mapped_to_actual[mapped_key] = actual_key
		actual_to_mapped[actual_key] = mapped_key
		result[#result + 1] = valid
	end
	return result
end

local function validate_dynamic_items(item_validator)
	return function(self, value)
		if type(value) == "table" then
			local result = {}
			for _, item in ipairs(normalized_list_values(value)) do
				local valid, err = item_validator(item)
				if not valid then
					return nil, err
				end
				if valid ~= "" then
					result[#result + 1] = valid
				end
			end
			return result
		end
		return item_validator(value)
	end
end

local function validate_input_rule_item(value)
	value = trim(value)
	if value == "" then
		return value
	end
	if not value:match("^[^,]+,%s*%d+%.%d+%.%d+%.%d+$") then
		return nil, translate("格式错误，应为 CIDR,目标虚拟IP，例如 192.168.1.0/24,10.26.0.2")
	end
	return value
end

local function validate_port_mapping_item(value)
	value = trim(value)
	if value == "" then
		return value
	end
	if not value:match("^[%w]+://.+%-.+%-.+$") then
		return nil, translate("格式错误，应为 协议://本地监听地址-目标虚拟IP-目标映射地址")
	end
	return value
end

local function validate_cert_mode(self, value)
	value = trim(value)
	if value == "" then
		return value
	end
	if value == "skip" or value == "standard" or value:match("^finger:[0-9a-fA-F]+$") then
		return value
	end
	return nil, translate("证书验证模式仅支持 skip、standard 或 finger:指纹")
end

local function validate_stun_item(value)
	value = trim(value)
	if value == "" then
		return value
	end

	local host, port = value:match("^(.+):(%d+)$")
	if host then
		if tonumber(port) < 1 or tonumber(port) > 65535 then
			return nil, translate("STUN 地址端口必须为 1~65535")
		end
	else
		host = value
	end

	if not is_ipv4(host) and not is_ipv6(host) and not is_domain(host) then
		return nil, translate("STUN 地址必须为域名、IPv4 或 IPv6 地址，可带端口")
	end
	return value
end

local function validate_virtual_ip(self, value)
	value = trim(value)
	if value == "" then
		return value
	end
	if is_ipv4(value) then
		return value
	end
	return validate_cidr(self, value)
end

local function validate_uint_range(minimum, maximum, message)
	return function(self, value)
		value = trim(value)
		if value == "" then
			return value
		end
		local n = tonumber(value)
		if n and math.floor(n) == n and n >= minimum and n <= maximum then
			return tostring(math.floor(n))
		end
		return nil, translate(message)
	end
end

local function current_option(self, option)
	local value
	local option_object = cbi_options[option]
	if option_object and type(option_object.formvalue) == "function" then
		local ok, result = pcall(option_object.formvalue, option_object, self.section)
		if ok then
			value = result
		end
	end
	if value == nil and self.map and type(self.map.formvalue) == "function" then
		local ok, result = pcall(self.map.formvalue, self.map, self.section, option)
		if ok then
			value = result
		end
	end
	if type(value) == "table" then
		value = value[1]
	end
	if value == nil then
		value = self.map.uci:get(self.map.config, self.section, option)
	end
	return trim(value)
end

local function bind_list_option(option)
	option.cfgvalue = function(self, section)
		-- Read the raw UCI value directly: MultiValue (and any widget whose
		-- cast is "string") makes AbstractValue.cfgvalue truncate a stored
		-- list to its first item, which left every firewall direction but the
		-- first unchecked after each page load.
		local value
		if self.tag_error[section] then
			value = self:formvalue(section)
		else
			value = self.map:get(section, self.alias or self.option)
		end
		local result = normalized_list_values(value)
		if #result == 0 then
			return nil
		end
		return result
	end

	option.write = function(self, section, value)
		local values = normalized_list_values(value)
		self.map.uci:delete(self.map.config, section, self.option)
		if #values > 0 then
			self.map.uci:set_list(self.map.config, section, self.option, values)
		end
		return true
	end

	option.remove = function(self, section)
		self.map.uci:delete(self.map.config, section, self.option)
	end

	-- Lists are built by client side widgets: the inputs only exist after
	-- cbi.js hydration replaced the placeholder markup, and the stored values
	-- are mirrored into <cbid>.__stored inputs rendered outside that
	-- placeholder so hydration can never remove them. An empty post is
	-- ambiguous - the user may have removed the last item, or the widget may
	-- never have reported its state - and writing an empty list would silently
	-- drop the stored configuration. The page script resolves it: __hyd says
	-- the widget took over, and __values then carries exactly what it holds
	-- (an empty value means the user removed every item). Server rendered
	-- widgets post __present instead, which always arrives when the widget is
	-- in the form. Without either signal the stored values win, and every
	-- decision is recorded in the log.
	option.__vnt2_managed_parse = true
	list_options[option.option] = true
	option.parse = function(self, section, novld)
		local cbid = self:cbid(section)
		local posted = self:formvalue(section)
		local values = normalized_list_values(posted)
		local stored = normalized_list_values(self.map:formvalue(cbid .. ".__stored"))
		-- Server rendered presence marker (multi value widgets): it always
		-- posts, so "marker without values" is a real user deselection.
		local present = self.map:formvalue(cbid .. ".__present") ~= nil
		local hyd = self.map:formvalue(cbid .. ".__hyd")
		local diag = self.map:formvalue(cbid .. ".__diag") or ""
		local seen_diag = diag:match("s=1") ~= nil
		local touched_diag = diag:match("t=1") ~= nil

		-- Map.parse runs Node.parse a second time with novld=true after
		-- on_after_save. The save-audit has already restored any list that was
		-- silently cleared during the first pass; letting the second pass run
		-- the same widget logic with the original form values would undo that
		-- correction, so managed lists must be a no-op during the re-parse.
		if novld then
			return nil
		end

		local function list_parse_audit(decision, extra)
			config_audit("列表解析 " .. tostring(self.option)
				.. " [" .. decision .. "]"
				.. " hyd=" .. tostring(hyd)
				.. " values=" .. #values
				.. " stored=" .. #stored
				.. " present=" .. tostring(present)
				.. " diag=" .. tostring(diag)
				.. " post=" .. dump_post_keys(self.map, cbid)
				.. (extra or ""))
		end

		if hyd == "1" then
			-- The widget owns this list: take its own item list verbatim.
			values = split_posted_values(self.map:formvalue(cbid .. ".__values"))
			-- An empty authoritative list with stored values is only trusted
			-- when the browser confirms it actually displayed the items and
			-- the user removed them. Otherwise a hydration race or rebuilt
			-- widget would wipe the configuration.
			if #values == 0 and #stored > 0 and not (seen_diag and touched_diag) then
				list_parse_audit("拒信空列表", "，已回退到 stored")
				return nil
			end
			authorized_clear[self.option] = true
		elseif #values == 0 and #stored > 0 and not present then
			list_parse_audit("保留原值")
			return nil
		end

		if #values == 0 then
			authorized_clear[self.option] = true
			if #stored > 0 then
				config_audit("用户清空了 " .. tostring(self.option)
					.. "（原有 " .. #stored .. " 项，hyd=" .. tostring(hyd) .. "）")
			end
		end

		local result = values
		if type(self.validate) == "function" then
			local err
			result, err = self:validate(values, section)
			if not result then
				self:add_error(section, "invalid", err)
				return nil
			end
		end

		result = normalized_list_values(result)
		-- Idempotent: only touch UCI when the parsed list really differs from
		-- what is stored now, so saving an unchanged form neither rewrites the
		-- config nor marks the page as changed (which would queue a restart).
		local current = normalized_list_values(
			self.map.uci:get(self.map.config, section, self.option))
		if #result > 0 then
			if not same_list(current, result) then
				self:write(section, result)
				self.section.changed = true
			end
		elseif #current > 0 then
			self:remove(section)
			self.section.changed = true
		end
	end
end

local function bind_dynamiclist(option)
	bind_list_option(option)
	-- Custom template: renders the current values as fallback hidden inputs
	-- inside the data-ui-widget div, so a form save cannot clear the list
	-- when cbi.js hydration never ran for the widget.
	option.template = "vnt2/dynlist"
end

-- LuCI deletes an option whenever its widget contributed no value to the
-- request: AbstractValue.parse removes rmempty/optional fields without a form
-- value and Flag.parse removes flags that lack the cbi.cbe existence marker.
-- Every widget on this page is hydrated asynchronously by cbi.js, so a submit
-- that races hydration (or follows a hydration error) carries no values at all
-- and would silently wipe the stored configuration. Treat "widget absent from
-- this request" as "keep the stored value"; a widget that is present but empty
-- still clears its field. List options carry their own parse that additionally
-- requires a positive "emptied" signal before dropping stored values.
local function keep_absent_options(section)
	local flag_prefix = FEXIST_PREFIX or "cbi.cbe."
	local flag_parse = Flag and Flag.parse or nil

	for _, opt in ipairs(section.children) do
		local name = opt.option
		if name and not opt.__vnt2_managed_parse
			and name ~= "upload_cli" and name ~= "_toml_edit" and name ~= "_upload_note_cli" then
			-- Flags carry their own parse (existence marker based); every other
			-- widget inherits AbstractValue.parse.
			local is_flag = opt.template == "cbi/fvalue"
			local base = (is_flag and flag_parse) or AbstractValue.parse

			opt.parse = function(self, sect, novld)
				-- A widget took part in this request when it posted its value or
				-- (for flags, which post nothing while unchecked) its existence
				-- marker. Anything else never reached the browser form.
				local present = self:formvalue(sect) ~= nil
				if not present then
					present = self.map:formvalue(flag_prefix .. self.map.config
						.. "." .. tostring(sect) .. "." .. self.option) ~= nil
				end
				if not present then
					return nil
				end
				return base(self, sect, novld)
			end
		end
	end
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
local w = m:section(TypedSection, "vnt2_cli")
w.anonymous = true
w.addremove = false

w:tab("general", translate("基本设置"))
w:tab("device", translate("设备与网卡"))
w:tab("tunnel", translate("传输与隧道"))
w:tab("forward", translate("子网与转发"))
w:tab("security", translate("安全"))
w:tab("edit", translate("编辑配置"))
w:tab("upload", translate("上传程序"))

local enabled = w:taboption("general", Flag, "enabled", translate("启用客户端"))
enabled.rmempty = false
enabled.default = "0"
enabled.description = translate("启用后插件将本页配置导出为唯一运行配置并启动 vnt2_cli；保存应用由后台 worker 完成重启")
enabled.write = function(self, section, value)
	self.map.uci:set(self.map.config, section, self.option, value)
end

local network_code = w:taboption("general", Value, "network_code", translate("网络编号"))
network_code.placeholder = "your_network_code"
network_code.rmempty = true
network_code.description = translate("相同网络编号的设备会组在同一个虚拟网；与订阅链接至少填写其一")
network_code.validate = function(self, value)
	value = trim(value)
	if value ~= "" then
		return value
	end
	if trim(current_option(self, "subscription")) ~= "" then
		return value
	end
	return nil, translate("网络编号与订阅链接至少填写其一")
end

local subscription = w:taboption("general", Value, "subscription", translate("订阅链接"))
subscription.placeholder = "vnt2://join/2/..."
subscription.rmempty = true
subscription.description = translate("服务端签发的配置源；本页显式填写的同名字段仍覆盖订阅下发值")
cbi_options.subscription = subscription
subscription.validate = function(self, value)
	value = trim(value)
	if value == "" then
		if trim(current_option(self, "network_code")) ~= "" then
			return value
		end
		return nil, translate("网络编号与订阅链接至少填写其一")
	end
	if not value:match("^vnt2://.+") then
		return nil, translate("订阅链接必须以 vnt2:// 开头")
	end
	return value
end

local server = w:taboption("general", DynamicList, "server", translate("服务器地址"))
server.placeholder = "quic://1.2.3.4:29872"
server.description = translate("支持 quic/tcp/wss/dynamic 协议；留空且填写固定虚拟 IP 时为无服务器模式")
bind_dynamiclist(server)
server.validate = validate_server

local peer_address = w:taboption("general", DynamicList, "peer_address", translate("可直连节点"))
peer_address.placeholder = "1.2.3.4:29873"
peer_address.description = translate("支持 ip:port、tcp://、udp:// 或 dynamic://；地址端口应为对端隧道监听端口")
bind_dynamiclist(peer_address)
peer_address.validate = validate_peer_address

local turn_rules = w:taboption("general", DynamicList, "turn", translate("优先中转"))
turn_rules.placeholder = "10.26.0.0/24,10.26.0.2"
turn_rules.description = translate("指定目标 IP/网段的优先中转虚拟 IP，每项格式 目标,中转IP；命中目标不参与打洞")
bind_dynamiclist(turn_rules)
turn_rules.validate = validate_dynamic_items(validate_turn_item)

local punch_model = w:taboption("general", DynamicList, "punch_model", translate("打洞模式规则"))
punch_model.placeholder = "10.26.0.2,IPv4Udp"
punch_model.description = translate("指定目标 IP/网段允许的打洞方式，每项格式 目标,模式[,模式...]；模式为 IPv4Tcp、IPv4Udp、IPv6Tcp、IPv6Udp")
bind_dynamiclist(punch_model)
punch_model.validate = validate_dynamic_items(validate_punch_model_item)

local ctrl_port = w:taboption("general", Value, "ctrl_port", translate("控制端口"))
ctrl_port.placeholder = "11233"
ctrl_port.datatype = "port"
ctrl_port.description = translate("vnt2_cli 控制服务仅监听 127.0.0.1，运行信息页通过 vnt2_ctrl 查询运行状态")

local vnt2_cli_bin = w:taboption("general", Value, "vnt2_cli_bin", translate("vnt2_cli 程序路径"))
vnt2_cli_bin.placeholder = "/usr/bin/vnt2_cli"
vnt2_cli_bin.validate = validate_nonempty

local log_level = w:taboption("general", ListValue, "log_level", translate("日志级别"))
for _, lv in ipairs({ "error", "warn", "info", "debug", "trace" }) do
	log_level:value(lv, lv)
end
log_level.default = "info"

local download_mirror = w:taboption("general", ListValue, "download_mirror", translate("下载镜像源"))
bind_download_mirror(download_mirror)
local custom_download_mirror = w:taboption("general", Value, "custom_download_mirror", translate("自定义镜像地址"))
bind_custom_download_mirror(custom_download_mirror, "download_mirror")

local device_mode = w:taboption("device", ListValue, "device_mode", translate("虚拟网卡模式"))
device_mode:value("tun", translate("tun（三层网卡）"))
device_mode:value("tap", translate("tap（二层网卡）"))
device_mode:value("no", translate("no（无虚拟网卡）"))
device_mode.default = "tun"
device_mode.rmempty = false
device_mode.description = translate("TUN/TAP 模式下插件自动同步 VNT2 网络接口与防火墙区域")

local tun_name = w:taboption("device", Value, "tun_name", translate("虚拟网卡名称"))
tun_name.placeholder = "vnt-tun"
tun_name.rmempty = true

local virtual_ip = w:taboption("device", Value, "ip", translate("固定虚拟 IP"))
virtual_ip.placeholder = "10.26.0.2/24"
virtual_ip.rmempty = true
virtual_ip.description = translate("IP 或 CIDR（纯 IP 默认 /24）；无服务器或多服务器时必填")
virtual_ip.validate = validate_virtual_ip

local device_name = w:taboption("device", Value, "device_name", translate("设备名称"))
device_name.rmempty = true
device_name.description = translate("留空时默认读取路由器主机名")

local device_id = w:taboption("device", Value, "device_id", translate("设备 ID"))
device_id.rmempty = true
device_id.description = translate("留空时使用自动生成的持久化设备 ID（/etc/machine-id）")

local outbound_interface = w:taboption("device", Value, "outbound_interface", translate("出口网卡"))
outbound_interface.rmempty = true
outbound_interface.description = translate("绑定对外通信 Socket 的出口网卡名称，可选")

local mtu = w:taboption("device", Value, "mtu", translate("MTU"))
mtu.placeholder = "1400"
mtu.rmempty = true
mtu.validate = validate_uint_range(1, 65535, "MTU 必须为 1~65535 的整数")

local function add_flag(tab, name, label, description)
	local flag = w:taboption(tab, Flag, name, label)
	flag.rmempty = false
	flag.default = "0"
	if description then
		flag.description = translate(description)
	end
	flag.write = function(self, section, value)
		self.map.uci:set(self.map.config, section, self.option, value)
	end
	return flag
end

add_flag("tunnel", "rtx", "启用 quic 优化传输", nil)
add_flag("tunnel", "compress", "启用 LZ4 压缩", nil)
add_flag("tunnel", "fec", "启用 FEC 前向纠错", "损失一定带宽提升网络稳定性")
add_flag("tunnel", "no_punch", "关闭自动 P2P 打洞", "显式直连节点地址仍可连接")
add_flag("tunnel", "no_broadcast", "关闭虚拟网广播/组播转发", nil)
add_flag("tunnel", "auto_sync_subnet", "自动同步出口子网", "自动获取并应用其他在线节点上报的出口子网")
add_flag("tunnel", "allow_ikev2", "允许与 IKEv2 客户端通信", nil)
add_flag("tunnel", "allow_wireguard", "允许与 WireGuard 客户端通信", nil)

local tunnel_addr = w:taboption("tunnel", DynamicList, "tunnel_addr", translate("P2P 隧道监听地址"))
tunnel_addr.placeholder = "192.168.1.10:29873"
tunnel_addr.description = translate("IPv4 与 IPv6 各最多一个且必须使用相同端口；与旧版隧道端口互斥")
bind_dynamiclist(tunnel_addr)
tunnel_addr.validate = function(self, value)
	local values = normalized_list_values(value)
	local seen_ipv4 = false
	local seen_ipv6 = false
	local common_port
	local result = {}

	for _, item in ipairs(values) do
		local ipv4, ipv6, port
		local host, host_port = item:match("^([^:]+):(%d+)$")
		if host then
			ipv4 = host:match("^%d+%.%d+%.%d+%.%d+$")
			port = tonumber(host_port)
		else
			host, host_port = item:match("^%[([^%]]+)%]:(%d+)$")
			ipv6 = host
			port = tonumber(host_port)
		end

		if ipv4 and not is_ipv4(ipv4) then
			ipv4 = nil
		end
		if ipv6 and not is_ipv6(ipv6) then
			ipv6 = nil
		end
		if not port or port < 0 or port > 65535 or (not ipv4 and not ipv6) then
			return nil, translate("隧道地址必须为 IPv4:port 或 [IPv6]:port，端口 0 表示自动分配")
		end
		if common_port and common_port ~= port then
			return nil, translate("所有隧道地址必须使用相同端口")
		end
		common_port = port
		if ipv4 then
			if seen_ipv4 then
				return nil, translate("隧道地址每种 IP 地址族最多填写一个地址")
			end
			seen_ipv4 = true
		else
			if seen_ipv6 then
				return nil, translate("隧道地址每种 IP 地址族最多填写一个地址")
			end
			seen_ipv6 = true
		end
		result[#result + 1] = item
	end

	return #result > 0 and result or value
end

local tunnel_port = w:taboption("tunnel", Value, "tunnel_port", translate("旧版隧道端口"))
tunnel_port.placeholder = "29873"
tunnel_port.rmempty = true
tunnel_port.description = translate("仅保留兼容；不能与上方隧道监听地址同时填写")
tunnel_port.validate = validate_uint_range(0, 65535, "隧道端口必须为 0~65535 的整数")

local input_rules = w:taboption("forward", DynamicList, "input", translate("入栈监听网段"))
input_rules.placeholder = "192.168.1.0/24,10.26.0.2"
input_rules.description = translate("点对网：将指定网段的流量发送到目标节点，每项格式 CIDR,目标虚拟IP")
bind_dynamiclist(input_rules)
input_rules.validate = validate_dynamic_items(validate_input_rule_item)

local output_rules = w:taboption("forward", DynamicList, "output", translate("出栈允许网段"))
output_rules.placeholder = "0.0.0.0/0"
output_rules.description = translate("点对网：允许指定网段的转发，每项为 CIDR")
bind_dynamiclist(output_rules)
output_rules.validate = validate_dynamic_items(validate_cidr)

local subnet_mapping = w:taboption("forward", DynamicList, "subnet_mapping", translate("出栈网段映射"))
subnet_mapping.placeholder = "192.168.2.0/24,192.168.1.0/24"
subnet_mapping.description = translate("将访问端使用的映射网段转换为真实网段，两侧掩码必须相同")
bind_dynamiclist(subnet_mapping)
subnet_mapping.validate = validate_subnet_mapping

local port_mapping = w:taboption("forward", DynamicList, "port_mapping", translate("端口映射"))
port_mapping.placeholder = "tcp://0.0.0.0:81-10.0.0.2-10.0.0.2:80"
port_mapping.description = translate("格式：协议://本地监听地址-目标虚拟IP-目标映射地址")
bind_dynamiclist(port_mapping)
port_mapping.validate = validate_dynamic_items(validate_port_mapping_item)

add_flag("forward", "allow_mapping", "允许作为端口映射出口", "开启后虚拟网其他设备可使用本设备当跳板访问其他网络")

local vnt2_forward = w:taboption("forward", MultiValue, "vnt2_forward", translate("防火墙转发方向"))
vnt2_forward:value("vnt2fwlan", translate("VNT2 -> LAN"))
vnt2_forward:value("vnt2fwwan", translate("VNT2 -> WAN"))
vnt2_forward:value("lanfwvnt2", translate("LAN -> VNT2"))
vnt2_forward:value("wanfwvnt2", translate("WAN -> VNT2"))
vnt2_forward.description = translate("VNT2 与 LAN/WAN 之间允许的转发方向；未选择的方向不自动放行")
bind_list_option(vnt2_forward)
-- MultiValue.validate joins the selection into one delimiter-separated string,
-- which bind_list_option would store as a single list item containing spaces.
-- Keep the managed firewall directions a real UCI list instead.
vnt2_forward.template = "vnt2/multilist"
vnt2_forward.validate = function(self, value)
	local choices = {}
	for _, key in ipairs(self.keylist or {}) do
		choices[key] = true
	end

	local selected = {}
	local function add(item)
		item = trim(item)
		if item ~= "" and choices[item] and not util.contains(selected, item) then
			selected[#selected + 1] = item
		end
	end

	if type(value) == "table" then
		for _, item in ipairs(value) do
			for part in tostring(item):gmatch("%S+") do
				add(part)
			end
		end
	elseif value ~= nil then
		for part in tostring(value):gmatch("%S+") do
			add(part)
		end
	end

	return selected
end

local password = w:taboption("security", Value, "password", translate("加密密码"))
password.password = true
password.rmempty = true
password.description = translate("虚拟网数据加密密码；同一虚拟网内所有设备必须一致")

local cert_mode = w:taboption("security", Value, "cert_mode", translate("证书校验模式"))
cert_mode.placeholder = "skip"
cert_mode.rmempty = true
cert_mode.description = translate("skip（默认，跳过验证）、standard（系统证书验证）或 finger:服务端证书指纹")
cert_mode.validate = validate_cert_mode

local udp_stun = w:taboption("security", DynamicList, "udp_stun", translate("UDP STUN 地址"))
udp_stun.placeholder = "stun.chat.bilibili.com"
udp_stun.description = translate("用于 UDP 打洞；不填写使用默认 STUN，未带端口时默认 3478")
bind_dynamiclist(udp_stun)
udp_stun.validate = validate_dynamic_items(validate_stun_item)

local tcp_stun = w:taboption("security", DynamicList, "tcp_stun", translate("TCP STUN 地址"))
tcp_stun.placeholder = "stun.nextcloud.com:443"
tcp_stun.description = translate("用于 TCP 打洞；不填写使用默认 STUN，未带端口时默认 3478")
bind_dynamiclist(tcp_stun)
tcp_stun.validate = validate_dynamic_items(validate_stun_item)

local event_script = w:taboption("security", Value, "event_script", translate("事件脚本"))
event_script.rmempty = true
event_script.description = translate("网卡创建成功、掉线、重连成功、IP 变化时以参数方式调用的脚本路径/命令，可选")

local toml_edit = w:taboption("edit", DummyValue, "_toml_edit")
toml_edit.rawhtml = true
toml_edit.template = "vnt2/vnt2_toml_edit"

local cli_upload = w:taboption("upload", FileUpload, "upload_cli")
cli_upload.optional = true
cli_upload.default = ""
cli_upload.template = "vnt2/other_upload"

local cli_upload_note = w:taboption("upload", DummyValue, "_upload_note_cli")
cli_upload_note.rawhtml = true
cli_upload_note.template = "vnt2/other_dvalue"
cbi_options.cli_upload_note = cli_upload_note

keep_absent_options(w)
end)()

add_file_upload_handler({
	cbi_options.cli_upload_note
})

-- ---------- save audit ----------
-- The stored configuration is captured before anything in this request can
-- change it and compared again once the map has saved: every list that lost
-- its value without the request asking for it is written back. This is the
-- last line of defence against a silent loss and it does not depend on which
-- code path dropped the value - a widget that posted nothing, a merge that
-- skipped a key, or a CBI rule that removed an option it thought was empty.
local save_sid = nil
local save_before = nil

local function capture_save_state()
	save_sid = m.uci:get_first("vnt2", "vnt2_cli")
	save_before = save_sid and m.uci:get_all("vnt2", save_sid) or nil
end

m.on_after_save = function()
	if not save_sid or not save_before then
		return
	end

	local now = m.uci:get_all("vnt2", save_sid) or {}
	local restored = {}
	local changed = {}

	for key, before in pairs(save_before) do
		if key:sub(1, 1) ~= "." then
			local after = now[key]
			if option_is_empty(after) and not option_is_empty(before) then
				if list_options[key] and not authorized_clear[key] then
					m.uci:delete("vnt2", save_sid, key)
					if type(before) == "table" then
						local items = normalized_list_values(before)
						if #items > 0 then
							m.uci:set_list("vnt2", save_sid, key, items)
						end
					else
						m.uci:set("vnt2", save_sid, key, tostring(before))
					end
					restored[#restored + 1] = key
						.. "(" .. #normalized_list_values(before) .. " 项)"
				else
					changed[#changed + 1] = key .. " 已清空"
				end
			else
				local was = audit_value(key, before)
				local is = audit_value(key, after)
				if was ~= is then
					changed[#changed + 1] = key .. ": " .. was .. " → " .. is
				end
			end
		end
	end

	if #restored > 0 then
		table.sort(restored)
		config_audit("保存审计：已恢复被清空的 " .. table.concat(restored, "、")
			.. "（本次请求未提交清空）")
		-- The restores above were written after Map.parse had already taken its
		-- UCI savepoint (uci:save runs before on_after_save). LuCI's deferred
		-- apply commits from that savepoint, not from the live cursor, so the
		-- corrected lists would otherwise be thrown away by the later commit.
		-- Re-take the savepoint so the restored values actually persist.
		m.uci:save("vnt2")
	end
	if #changed > 0 then
		table.sort(changed)
		config_audit("保存审计：变更 " .. table.concat(changed, "；"))
	end
end

-- The edit-config tab's textarea posts with the form (name=_toml_editor_text).
-- Save its content before the form options parse so the documented order
-- holds: the text config is merged first, the form's own values are applied
-- on top of it. Only text the user actually edited participates - an
-- untouched runtime snapshot must never overwrite the stored configuration.
m.on_parse = function()
	-- Snapshot first: the audit compares the state before this request
	-- against the state the map saved, which is what makes a silent loss
	-- visible instead of merely suspected.
	capture_save_state()

	-- The editor textarea posts with every form save, so its presence marks a
	-- real POST (page views never carry it). Log the build once per save.
	if http.formvalue("_toml_editor_text") ~= nil then
		config_audit("表单保存开始（build=" .. FORM_BUILD .. "）")
	end

	local content = http.formvalue("_toml_editor_text")
	if type(content) == "table" then
		content = table.concat(content, "\n")
	end
	content = tostring(content or ""):gsub("%z", "")

	if trim(content) == "" then
		return
	end

	-- The merge must run on the map's own cursor and must not commit early:
	-- a second cursor would write a delta the map's later commit overwrites,
	-- which is why the edited text silently vanished on save & apply.
	local rendered = http.formvalue("_toml_editor_text_fingerprint")
	if rendered ~= nil and textutil.text_fingerprint(content) == tostring(rendered) then
		return
	end

	if http.formvalue("_toml_editor_text_dirty") ~= "1" then
		config_audit("编辑配置随表单保存：文本与页面渲染内容不同但未标记为已编辑"
			.. "（长度 " .. #content .. "），按运行时快照处理，未写入")
		return
	end

	local values, err = textutil.toml_parse_config(content)
	if not values then
		config_audit("编辑配置随表单保存：解析失败（" .. tostring(err) .. "），文本未写入")
		return
	end

	local ok, applied = textutil.toml_apply_to_uci(m.uci, values, false)
	if not ok then
		config_audit("编辑配置随表单保存失败：" .. tostring(applied))
		return
	end
	if applied > 0 then
		config_audit("编辑配置随表单保存：部分合并 " .. tostring(applied)
			.. " 个键（其余保持不变）")
	else
		config_audit("编辑配置随表单保存：文本无实际变化，未写入")
	end
end

return m
