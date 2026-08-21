#!/bin/sh
# l2tppool.sh - backend for luci-app-l2tp-pool-manager
# Commands: apply | status | redial <account> | rotate <binding>
#           | rotate_all | ipcheck <interface> | diagnostics
#
# All user-supplied arguments are validated against [A-Za-z0-9_-] / CIDR
# to prevent shell injection. Never use eval on user input.

CONFIG="l2tppool"
STATE_FILE="/etc/l2tppool.state"
IP_CACHE_DIR="/tmp/l2tppool"

. /lib/functions.sh

# ---------- helpers ----------
log() {
	logger -t l2tppool "$*"
}

# validate an identifier: only [A-Za-z0-9_-], non-empty
valid_id() {
	[ -n "${1:-}" ] || return 1
	case "$1" in
		*[!A-Za-z0-9_-]*) return 1 ;;
		*) return 0 ;;
	esac
}

# validate a CIDR like 192.168.10.0/24
valid_cidr() {
	[ -n "${1:-}" ] || return 1
	echo "$1" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$' || return 1
	return 0
}

# validate an IPv4
valid_ip() {
	[ -n "${1:-}" ] || return 1
	echo "$1" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' || return 1
	return 0
}

# escape a string for JSON output
json_esc() {
	# strip newlines, escape backslash & quote
	printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/	/\\t/g' | tr '\n' ' '
}

# get a uci option from l2tppool with default
gopt() {
	local s="$1" o="$2" d="${3:-}"
	local v
	v="$(uci -q get "$CONFIG.$s.$o" 2>/dev/null)"
	echo "${v:-$d}"
}

# get network interface status: online|offline|dialing
iface_status() {
	local ifn="$1" up json l3dev
	[ -n "$ifn" ] || { echo "offline"; return; }
	json="$(ubus call "network.interface.$ifn" status 2>/dev/null)" || { echo "offline"; return; }
	# up field
	up="$(printf '%s' "$json" | jsonfilter -e '@.up' 2>/dev/null)"
	if [ "$up" = "1" ]; then
		echo "online"
	else
		# has pending proto task => dialing, else offline
		if printf '%s' "$json" | jsonfilter -e '@.proto' 2>/dev/null | grep -q .; then
			echo "dialing"
		else
			echo "offline"
		fi
	fi
}

# resolve the L3 device name (pppN) of a logical interface
iface_dev() {
	local ifn="$1" json dev
	json="$(ubus call "network.interface.$ifn" status 2>/dev/null)" || return 0
	dev="$(printf '%s' "$json" | jsonfilter -e '@.l3_device' 2>/dev/null)"
	[ -n "$dev" ] || dev="$(printf '%s' "$json" | jsonfilter -e '@.device' 2>/dev/null)"
	echo "$dev"
}

# public IP via curl --interface, fallback to device
ipcheck() {
	local ifn="$1" dev url ip
	url="$(gopt global ip_check_url 'https://api.ipify.org')"
	# try logical interface name first
	ip="$(curl --interface "$ifn" -s --max-time 8 "$url" 2>/dev/null)"
	if valid_ip "$ip"; then
		echo "$ip"
		return 0
	fi
	# fallback to underlying device (pppN)
	dev="$(iface_dev "$ifn")"
	if [ -n "$dev" ]; then
		ip="$(curl --interface "$dev" -s --max-time 8 "$url" 2>/dev/null)"
		if valid_ip "$ip"; then
			echo "$ip"
			return 0
		fi
	fi
	echo ""
	return 1
}

cache_ip() {
	local ifn="$1" ip="$2"
	mkdir -p "$IP_CACHE_DIR"
	if [ -n "$ip" ]; then
		printf '%s' "$ip" > "$IP_CACHE_DIR/$ifn.ip"
	else
		rm -f "$IP_CACHE_DIR/$ifn.ip"
	fi
}

cached_ip() {
	local ifn="$1"
	[ -f "$IP_CACHE_DIR/$ifn.ip" ] && cat "$IP_CACHE_DIR/$ifn.ip" 2>/dev/null
}

# find account section name (id) by its network interface name
account_id_by_ifname() {
	local ifn="$1" sid name
	for sid in $(uci -q show "$CONFIG" 2>/dev/null | grep '=account$' | cut -d. -f2 | cut -d= -f1); do
		name="$(gopt "$sid" name)"
		[ "$name" = "$ifn" ] && { echo "$sid"; return 0; }
	done
	echo ""
}

# list of account section ids (enabled only if $1=enabled)
account_list() {
	local only_en="${1:-all}" sid en out=""
	for sid in $(uci -q show "$CONFIG" 2>/dev/null | grep '=account$' | cut -d. -f2 | cut -d= -f1); do
		if [ "$only_en" = "enabled" ]; then
			en="$(gopt "$sid" enabled 0)"
			[ "$en" = "1" ] || continue
		fi
		out="$out $sid"
	done
	echo "$out"
}

# next account in pool (round_robin) different from current
next_pool_account() {
	local pool="$1" cur="$2" acc found="" first="" nxt=""
	local all
	all="$(uci -q get "$CONFIG.$pool.account" 2>/dev/null)"
	[ -n "$all" ] || { echo ""; return; }
	# list may be multiline from uci; normalize
	for a in $all; do
		valid_id "$a" || continue
		# only enabled accounts
		[ "$(gopt "$a" enabled 0)" = "1" ] || continue
		[ -z "$first" ] && first="$a"
		if [ -n "$found" ]; then
			nxt="$a"
			break
		fi
		[ "$a" = "$cur" ] && found=1
	done
	# wrap around
	[ -n "$nxt" ] || nxt="$first"
	# if next equals current (only one in pool), keep but still report
	echo "$nxt"
}

# ---------- apply ----------
cmd_apply() {
	local sid en name server user pass metric mtu group
	local bssid bnet bsub bacc bmode
	local radios radio dev
	local gen_ifaces="" gen_wifi="" gen_pbr="" gen_dhcp=""

	# load previous generated sets for cleanup
	local prev_ifaces="" prev_wifi="" prev_pbr="" prev_dhcp=""
	[ -f "$STATE_FILE" ] && . "$STATE_FILE" 2>/dev/null

	config_load "$CONFIG"

	# ---------- 1. L2TP interfaces (network) ----------
	for sid in $(uci -q show "$CONFIG" 2>/dev/null | grep '=account$' | cut -d. -f2 | cut -d= -f1); do
		en="$(gopt "$sid" enabled 0)"
		[ "$en" = "1" ] || continue
		name="$(gopt "$sid" name)"
		valid_id "$name" || { log "apply: skip invalid account name '$name'"; continue; }
		server="$(gopt "$sid" server)"
		user="$(gopt "$sid" username)"
		pass="$(gopt "$sid" password)"
		metric="$(gopt "$sid" metric 100)"
		mtu="$(gopt "$sid" mtu 1400)"
		# do not write password in clear logs
		uci -q set "network.$name=interface"
		uci -q set "network.$name.proto=l2tp"
		uci -q set "network.$name.server=$server"
		uci -q set "network.$name.username=$user"
		uci -q set "network.$name.password=$pass"
		uci -q set "network.$name.defaultroute=0"
		uci -q set "network.$name.peerdns=0"
		uci -q set "network.$name.ipv6=0"
		uci -q set "network.$name.metric=$metric"
		uci -q set "network.$name.mtu=$mtu"
		gen_ifaces="$gen_ifaces $name"
	done

	# ---------- 2. discover radios ----------
	radios=""
	for radio in $(uci -q show wireless 2>/dev/null | grep '=wifi-device$' | cut -d. -f2 | cut -d= -f1); do
		radios="$radios $radio"
	done
	# fallback names if no wireless config yet
	[ -n "$radios" ] || radios="radio0"

	# ---------- 3. bindings -> LAN segments + SSID + pbr ----------
	local idx=0
	for sid in $(uci -q show "$CONFIG" 2>/dev/null | grep '=binding$' | cut -d. -f2 | cut -d= -f1); do
		en="$(gopt "$sid" enabled 0)"
		[ "$en" = "1" ] || continue
		bssid="$(gopt "$sid" ssid)"
		bnet="$(gopt "$sid" network)"
		bsub="$(gopt "$sid" subnet)"
		bacc="$(gopt "$sid" account)"
		bmode="$(gopt "$sid" rotate_mode manual)"
		valid_id "$bnet" || { log "apply: skip invalid binding network '$bnet'"; continue; }
		valid_cidr "$bsub" || { log "apply: skip invalid subnet '$bsub'"; continue; }
		valid_id "$bacc" || { log "apply: skip invalid account '$bacc'"; continue; }

		# ipaddr = first host of subnet, netmask from /24 etc.
		local ipaddr netmask
		ipaddr="$(echo "$bsub" | cut -d/ -f1 | awk -F. '{print $1"."$2"."$3".1"}')"
		netmask="255.255.255.0"
		local plen
		plen="$(echo "$bsub" | cut -d/ -f2)"
		case "$plen" in
			8) netmask="255.0.0.0" ;;
			16) netmask="255.255.0.0" ;;
			24) netmask="255.255.255.0" ;;
		esac

		# LAN interface (static)
		uci -q set "network.$bnet=interface"
		uci -q set "network.$bnet.proto=static"
		uci -q set "network.$bnet.ipaddr=$ipaddr"
		uci -q set "network.$bnet.netmask=$netmask"
		gen_ifaces="$gen_ifaces $bnet"

		# DHCP pool
		uci -q set "dhcp.$bnet=dhcp"
		uci -q set "dhcp.$bnet.interface=$bnet"
		uci -q set "dhcp.$bnet.start=100"
		uci -q set "dhcp.$bnet.limit=150"
		uci -q set "dhcp.$bnet.leasetime=12h"
		uci -q set "dhcp.$bnet.dhcpv6=server"
		uci -q set "dhcp.$bnet.ra=server"
		gen_dhcp="$gen_dhcp $bnet"

		# wireless SSID on radio = round-robin across radios
		local pick
		pick=$(( idx % $(echo "$radios" | wc -w) ))
		dev="$(echo "$radios" | awk -v p="$pick" '{print $(p+1)}')"
		local wsec="wif_$sid"
		uci -q set "wireless.$wsec=wifi-iface"
		uci -q set "wireless.$wsec.device=$dev"
		uci -q set "wireless.$wsec.network=$bnet"
		uci -q set "wireless.$wsec.mode=ap"
		uci -q set "wireless.$wsec.ssid=$bssid"
		uci -q set "wireless.$wsec.encryption=psk2"
		uci -q set "wireless.$wsec.key=password1234"
		uci -q set "wireless.$wsec.isolate=1"
		gen_wifi="$gen_wifi $wsec"

		# resolve L2TP ifname bound to account
		local acc_ifname
		acc_ifname="$(gopt "$bacc" name)"
		[ -n "$acc_ifname" ] || acc_ifname="$bacc"

		# pbr policy
		local pname="pbr_$sid"
		uci -q set "pbr.$pname=policy"
		uci -q set "pbr.$pname.name=${bssid}_to_${acc_ifname}"
		uci -q set "pbr.$pname.src_addr=$bsub"
		uci -q set "pbr.$pname.interface=$acc_ifname"
		uci -q set "pbr.$pname.enabled=1"
		gen_pbr="$gen_pbr $pname"

		idx=$((idx+1))
	done

	# ensure pbr global enabled
	uci -q set "pbr.config=pbr" 2>/dev/null
	uci -q set "pbr.config.enabled=1" 2>/dev/null

	# ---------- 4. cleanup removed sections ----------
	local i
	for i in $prev_ifaces; do
		case " $gen_ifaces " in *" $i "*) ;; *) uci -q delete "network.$i" 2>/dev/null; uci -q delete "dhcp.$i" 2>/dev/null; esac
	done
	for i in $prev_dhcp; do
		case " $gen_dhcp " in *" $i "*) ;; *) uci -q delete "dhcp.$i" 2>/dev/null; esac
	done
	for i in $prev_wifi; do
		case " $gen_wifi " in *" $i "*) ;; *) uci -q delete "wireless.$i" 2>/dev/null; esac
	done
	for i in $prev_pbr; do
		case " $gen_pbr " in *" $i "*) ;; *) uci -q delete "pbr.$i" 2>/dev/null; esac
	done

	# ---------- 5. save state ----------
	cat > "$STATE_FILE" <<EOF
prev_ifaces="$gen_ifaces"
prev_dhcp="$gen_dhcp"
prev_wifi="$gen_wifi"
prev_pbr="$gen_pbr"
EOF

	uci -q commit network
	uci -q commit dhcp
	uci -q commit wireless
	uci -q commit pbr

	# reload
	/etc/init.d/network reload 2>/dev/null
	/etc/init.d/dnsmasq restart 2>/dev/null
	wifi reload 2>/dev/null
	/etc/init.d/pbr restart 2>/dev/null

	log "apply: config generated and reloaded"
	echo "OK apply complete"
}

# ---------- status ----------
cmd_status() {
	local sid en name server metric st ip dev uptime
	local acc_objs="" acc_first=1
	local bssid bnet bsub bacc bmode acc_ifname

	printf '{"accounts":['
	for sid in $(uci -q show "$CONFIG" 2>/dev/null | grep '=account$' | cut -d. -f2 | cut -d= -f1); do
		en="$(gopt "$sid" enabled 0)"
		name="$(gopt "$sid" name)"
		metric="$(gopt "$sid" metric)"
		st="$(iface_status "$name")"
		dev="$(iface_dev "$name")"
		ip="$(ipcheck "$name")"
		cache_ip "$name" "$ip"
		uptime="$(ubus call "network.interface.$name" status 2>/dev/null | jsonfilter -e '@.uptime' 2>/dev/null)"
		[ -n "$uptime" ] || uptime=0
		[ "$acc_first" = "1" ] || printf ','
		acc_first=0
		printf '{"id":"%s","name":"%s","ifname":"%s","status":"%s","public_ip":"%s","uptime":%s,"enabled":%s}' \
			"$(json_esc "$sid")" "$(json_esc "$name")" "$(json_esc "$dev")" \
			"$(json_esc "$st")" "$(json_esc "$ip")" "$uptime" "$en"
	done
	printf '],"bindings":['

	local bfirst=1
	for sid in $(uci -q show "$CONFIG" 2>/dev/null | grep '=binding$' | cut -d. -f2 | cut -d= -f1); do
		en="$(gopt "$sid" enabled 0)"
		bssid="$(gopt "$sid" ssid)"
		bnet="$(gopt "$sid" network)"
		bsub="$(gopt "$sid" subnet)"
		bacc="$(gopt "$sid" account)"
		bmode="$(gopt "$sid" rotate_mode manual)"
		acc_ifname="$(gopt "$bacc" name)"
		[ -n "$acc_ifname" ] || acc_ifname="$bacc"
		st="$(iface_status "$acc_ifname")"
		ip="$(ipcheck "$acc_ifname")"
		cache_ip "$acc_ifname" "$ip"
		[ "$bfirst" = "1" ] || printf ','
		bfirst=0
		printf '{"id":"%s","ssid":"%s","subnet":"%s","network":"%s","account":"%s","interface":"%s","public_ip":"%s","status":"%s","rotate_mode":"%s","enabled":%s}' \
			"$(json_esc "$sid")" "$(json_esc "$bssid")" "$(json_esc "$bsub")" \
			"$(json_esc "$bnet")" "$(json_esc "$bacc")" "$(json_esc "$acc_ifname")" \
			"$(json_esc "$ip")" "$(json_esc "$st")" "$(json_esc "$bmode")" "$en"
	done
	printf ']}'
	echo
}

# ---------- redial ----------
cmd_redial() {
	local acc="$1" name wait ip
	valid_id "$acc" || { echo "ERR invalid account id"; exit 1; }
	name="$(gopt "$acc" name)"
	[ -n "$name" ] || { echo "ERR account not found"; exit 1; }
	wait="$(gopt global redial_wait 3)"
	log "redial: $acc ($name)"
	ifdown "$name" 2>/dev/null
	sleep "$wait"
	ifup "$name" 2>/dev/null
	# wait briefly for dial
	local i
	for i in 1 2 3 4 5 6 7 8 9 10; do
		sleep 1
		[ "$(iface_status "$name")" = "online" ] && break
	done
	ip="$(ipcheck "$name")"
	cache_ip "$name" "$ip"
	echo "OK redial $name ip=${ip:-unknown}"
}

# ---------- rotate ----------
cmd_rotate() {
	local bid="$1" cur pool nxt acc_ifname
	valid_id "$bid" || { echo "ERR invalid binding id"; exit 1; }
	cur="$(gopt "$bid" account)"
	pool="default"
	# determine pool from account group; default pool = 'default'
	nxt="$(next_pool_account "$pool" "$cur")"
	[ -n "$nxt" ] || { echo "ERR no other enabled account in pool"; exit 1; }
	if [ "$nxt" = "$cur" ]; then
		echo "WARN pool has only one enabled account; no change"
		exit 0
	fi
	uci -q set "$CONFIG.$bid.account=$nxt"
	uci -q commit "$CONFIG"
	# regenerate pbr policy for this binding
	acc_ifname="$(gopt "$nxt" name)"
	local bssid bsub
	bssid="$(gopt "$bid" ssid)"
	bsub="$(gopt "$bid" subnet)"
	local pname="pbr_$bid"
	uci -q set "pbr.$pname.interface=$acc_ifname"
	uci -q set "pbr.$pname.name=${bssid}_to_${acc_ifname}"
	uci -q commit pbr
	/etc/init.d/pbr restart 2>/dev/null
	local ip
	ip="$(ipcheck "$acc_ifname")"
	cache_ip "$acc_ifname" "$ip"
	log "rotate: $bid $cur -> $nxt"
	echo "OK rotate $bid to $nxt ($acc_ifname) ip=${ip:-unknown}"
}

cmd_rotate_all() {
	local bid out=""
	for bid in $(uci -q show "$CONFIG" 2>/dev/null | grep '=binding$' | cut -d. -f2 | cut -d= -f1); do
		[ "$(gopt "$bid" enabled 0)" = "1" ] || continue
		out="$out
$(cmd_rotate "$bid" 2>&1)"
	done
	echo "$out" | sed '/^$/d'
}

# ---------- diagnostics ----------
cmd_diagnostics() {
	echo "===== /etc/config/l2tppool ====="
	uci show "$CONFIG" 2>/dev/null
	echo
	echo "===== generated network interfaces ====="
	uci show network 2>/dev/null | grep -E 'proto=(l2tp|static)' | sed 's/=interface$//'
	echo
	echo "===== pbr policies ====="
	uci show pbr 2>/dev/null | grep -E '\.pbr$|\.policy$|src_addr|interface|\.name'
	echo
	echo "===== ip route (L2TP/LAN) ====="
	ip route 2>/dev/null | grep -E 'ppp|l2tp|192\.168\.'
	echo
	echo "===== interface states ====="
	for n in $(uci -q show "$CONFIG" 2>/dev/null | grep '=account$' | cut -d. -f2 | cut -d= -f1); do
		name="$(gopt "$n" name)"
		printf '%-12s %s\n' "$name" "$(iface_status "$name")"
	done
	echo
	echo "===== recent log ====="
	logread 2>/dev/null | grep -iE 'l2tp|xl2tpd|ppp|pbr' | tail -n 30
}

usage() {
	cat <<EOF
Usage: l2tppool.sh <command> [args]
  apply                 generate network/wireless/dhcp/pbr from l2tppool and reload
  status                output JSON status of accounts and bindings
  redial <account>      ifdown/ifup a L2TP account to change public IP
  rotate <binding>      switch a binding to next account in its pool
  rotate_all            rotate every enabled binding
  ipcheck <interface>   probe public IP of a logical interface
  diagnostics           dump interface/route/pbr/log diagnostics
EOF
}

# ---------- main ----------
CMD="${1:-}"
[ -n "$CMD" ] || { usage; exit 1; }

case "$CMD" in
	apply)        cmd_apply ;;
	status)       cmd_status ;;
	redial)       [ $# -ge 2 ] || { echo "ERR redial needs <account>"; exit 1; }; cmd_redial "$2" ;;
	rotate)       [ $# -ge 2 ] || { echo "ERR rotate needs <binding>"; exit 1; }; cmd_rotate "$2" ;;
	rotate_all)   cmd_rotate_all ;;
	ipcheck)      [ $# -ge 2 ] || { echo "ERR ipcheck needs <interface>"; exit 1; }
	              valid_id "$2" || { echo "ERR invalid interface"; exit 1; }
	              ip="$(ipcheck "$2")"; cache_ip "$2" "$ip"; echo "${ip:-unknown}" ;;
	diagnostics)  cmd_diagnostics ;;
	*)            usage; exit 1 ;;
esac
