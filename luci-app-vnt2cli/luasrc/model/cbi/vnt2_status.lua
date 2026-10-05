local f = SimpleForm("vnt2", translate("运行信息"))
f.description = translate("实时查看运行状态、控制信息、节点列表与路由列表")
f.reset = false
f.submit = false
f:append(Template("vnt2/vnt2_status"))

return f
