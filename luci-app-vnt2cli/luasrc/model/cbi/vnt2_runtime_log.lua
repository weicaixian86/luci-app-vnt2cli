local f = SimpleForm("vnt2", translate("运行日志"))
f.description = translate("实时查看 vnt2_cli 运行、下载与安装日志")
f.reset = false
f.submit = false
f:append(Template("vnt2/vnt2_runtime_log"))

return f
