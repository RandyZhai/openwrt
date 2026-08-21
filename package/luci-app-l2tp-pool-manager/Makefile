#
# Copyright (C) 2026 David
#
# This is free software, licensed under the MIT License.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-l2tp-pool-manager
PKG_VERSION:=1.0.0
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_MAINTAINER:=David

LUCI_TITLE:=L2TP Pool Manager (multi-SSID egress binding)
LUCI_DEPENDS:=\
	+luci-base \
	+xl2tpd \
	+ppp \
	+ppp-mod-pppol2tp \
	+pbr \
	+luci-app-pbr \
	+curl \
	+jsonfilter \
	+ip-full \
	+dnsmasq-full

LUCI_PKGARCH:=all

define Package/$(PKG_NAME)/description
  Multi-L2TP egress pool manager for x86_64 OpenWrt.
  Provides: multiple L2TP clients, multiple SSID/segments, SSID<->L2TP
  binding via PBR, per-interface redial, SSID egress rotation, public IP
  view and connection status. All controlled from /etc/config/l2tppool.
endef

include ../../luci.mk

# call BuildPackage - implicit via luci.mk
