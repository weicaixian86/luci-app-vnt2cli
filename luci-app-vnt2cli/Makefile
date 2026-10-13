#
# Copyright (C) 2008-2024 The LuCI Team
#
# This is free software, licensed under the Apache License, Version 2.0 .
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-vnt2cli
PKG_VERSION:=2.0.54
PKG_RELEASE:=1

LUCI_TITLE:=luci-app-vnt2cli - LuCI support for VNT2 CLI
LUCI_DESCRIPTION:=luci-app-vnt2cli OpenWrt LuCI application for managing the VNT2 command line client vnt2_cli and its control tool vnt2_ctrl
LUCI_DEPENDS:=+luci-base +luci-compat +kmod-tun +curl +ca-bundle +unzip +jsonfilter
LUCI_PKGARCH:=all

define Package/$(PKG_NAME)/conffiles
/etc/config/vnt2
endef

define Package/$(PKG_NAME)/prerm
#!/bin/sh
if [ -z "$${IPKG_INSTROOT}" ] && [ -x /etc/init.d/vnt2-upload-worker ] ; then
  /etc/init.d/vnt2-upload-worker stop >/dev/null 2>&1
  /etc/init.d/vnt2-upload-worker disable >/dev/null 2>&1
fi
if [ -z "$${IPKG_INSTROOT}" ] && [ -x /etc/init.d/vnt2-worker ] ; then
  /etc/init.d/vnt2-worker stop >/dev/null 2>&1
  /etc/init.d/vnt2-worker disable >/dev/null 2>&1
fi
if [ -z "$${IPKG_INSTROOT}" ] && [ -x /etc/init.d/vnt2 ] ; then
  if [ "$${PKG_UPGRADE}" != "1" ] ; then
    /etc/init.d/vnt2 stop >/dev/null 2>&1
    /etc/init.d/vnt2 disable >/dev/null 2>&1
  fi
fi
if [ -f /etc/config/vnt2 ] ; then
  echo "备份vnt2配置文件 /etc/config/vnt2 到 /tmp/vnt2_backup"
  echo "不重启设备前重新安装 luci-app-vnt2cli 可保留原配置"
  mv -f /etc/config/vnt2 /tmp/vnt2_backup
fi
endef

define Package/$(PKG_NAME)/postinst
#!/bin/sh
rm -f \
  "$${IPKG_INSTROOT}/etc/init.d/vnt2-version-worker" \
  "$${IPKG_INSTROOT}/etc/init.d/vnt2-preview-worker" \
  "$${IPKG_INSTROOT}/usr/libexec/vnt2/version-worker" \
  "$${IPKG_INSTROOT}/usr/libexec/vnt2/preview-worker" \
  "$${IPKG_INSTROOT}/usr/libexec/vnt2/cleanup-default-instance" \
  "$${IPKG_INSTROOT}/tmp/vnt2-version-check.pending" \
  "$${IPKG_INSTROOT}/tmp/vnt2-version-check.claimed" \
  "$${IPKG_INSTROOT}/tmp/vnt2-preview-check.pending" \
  "$${IPKG_INSTROOT}/tmp/vnt2-preview-check.claimed" \
  "$${IPKG_INSTROOT}/tmp/vnt2-preview.state" \
  "$${IPKG_INSTROOT}/vnt_current_config.txt" \
  "$${IPKG_INSTROOT}/tmp/vnt2-download-web.state"
rm -f "$${IPKG_INSTROOT}"/tmp/vnt2_latest_v2_*.tag "$${IPKG_INSTROOT}"/tmp/vnt2_latest_v3_*.tag
chmod 0755 \
  "$${IPKG_INSTROOT}/etc/init.d/vnt2" \
  "$${IPKG_INSTROOT}/etc/init.d/vnt2-upload-worker" \
  "$${IPKG_INSTROOT}/etc/init.d/vnt2-worker" \
  "$${IPKG_INSTROOT}/usr/libexec/vnt2/restart-worker" \
  "$${IPKG_INSTROOT}/usr/libexec/vnt2/upload-worker" >/dev/null 2>&1
if [ -f /tmp/vnt2_backup ] ; then
  echo "发现 vnt2 备份配置文件 /tmp/vnt2_backup，开始恢复到 /etc/config/vnt2"
  mv -f /tmp/vnt2_backup /etc/config/vnt2
  echo "请前往 VPN -> VNT2 页面按需重启服务"
fi
if [ -z "$${IPKG_INSTROOT}" ] ; then
  /etc/init.d/vnt2 enable >/dev/null 2>&1
  /etc/init.d/vnt2-upload-worker enable >/dev/null 2>&1
  /etc/init.d/vnt2-upload-worker restart >/dev/null 2>&1
  /etc/init.d/vnt2-worker enable >/dev/null 2>&1
  /etc/init.d/vnt2-worker restart >/dev/null 2>&1
  /etc/init.d/vnt2 schedule_restart >/dev/null 2>&1
fi
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
