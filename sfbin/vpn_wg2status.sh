#! /bin/bash

# CONTEXT: VPN context. Called when WG goes UP or DOWN

# PARAMETERS: [output filename] [up/down] [interface]

# NOTE:
# POST_UP has all the set enviornment variables but
# PRE/POST_DOWN is started with all environment variables emptied.
# Is this a WireGuard bug?
# Solution: Save the important variables during POST_UP
if [[ -f /dev/shm/env.txt ]]; then
	source /dev/shm/env.txt
else
	echo -e "SF_DEBUG=\"${SF_DEBUG}\"\n\
SF_REDIS_AUTH=\"${SF_REDIS_AUTH}\"\n\
PROVIDER=\"${PROVIDER}\"\n" >/dev/shm/env.txt
fi

source /sf/bin/funcs.sh

# From all files update the VPN status file
create_vpn_status()
{
	local loc
	local exit_ip
	local geoip
	local provider

	for f in "${DSTDIR}"/status-*.log; do
		[[ ! -f "${f}" ]] && break
		# shellcheck disable=SC1090
		source "${f}"
		# loc+=("${SFVPN_LOCATION}[$SFVPN_EXIT_IP]")
		# loc+=("${SFVPN_LOCATION}")
		# exit_ip+=("$SFVPN_EXIT_IP")

		provider+="'${SFVPN_PROVIDER}' "
		exit_ip+="'${SFVPN_EXIT_IP}' "
		geoip+="'${SFVPN_GEOIP}' "
	done

	# Delete vpn_status unless there is at least 1 VPN
	if [[ -z $geoip ]]; then
		rm -f "/config/guest/vpn_status"
		return
	fi

	echo -en "\
IS_VPN_CONNECTED=1\n\
VPN_GEOIP=(${geoip})\n\
VPN_PROVIDER=(${provider})\n\
VPN_EXIT_IP=(${exit_ip})\n" >"/config/guest/vpn_status"
}

down()
{
	# NOTE: DEBUGF wont work because stderr is closed during
	# WireGuard PRE_DOWN/POST_DOWN
	[[ -f "${LOGFNAME}" ]] && rm -f "${LOGFNAME}"
	create_vpn_status

	ip route del 10.11.0.0/16 via "${SF_ROUTER_IP}" 2>/dev/null

	/sf/bin/rportfw.sh fw_delall

	redis-cli -h 172.20.2.254 RPUSH portd:cmd "vpndown ${PROVIDER}" >/dev/null

	[[ "${PROVIDER,,}" == "cryptostorm" ]] && curl -fsSL --retry 1 --max-time 5 http://10.31.33.7/fwd -ddelallfwd=1

	true
}

up()
{
	local t
	local geo
	local exit_ip
	local ep_ip

	t="$(wg show "${DEV:-wg0}" endpoints)" && {
		t="${t##*[[:space:]]}"
		ep_ip="${t%:*}"

		# First extract Geo Information from wg0.conf file before
		# asking the cloud.
		str=$(grep '# GEOIP=' "/etc/wireguard/wg0.conf")
      	geo="${str:8}"

		[[ -z $geo ]] && geo=$(curl -fsSL --retry 3 --max-time 15 https://ipinfo.io 2>/dev/null) && {
			local city
			local geo
			t=$(echo "$geo" | jq '.country | select(. != null)')
			country="${t//[^[:alnum:].-_ \/]}"
			t=$(echo "$geo" | jq '.city |  select(. != null)')
			city="${t//[^[:alnum:].-_ \/]}"
			t=$(echo "$geo" | jq '.ip | select(. != null)')
			exit_ip="${t//[^0-9.]}"
			geo="${city}/${country}"
		}
		# [[ -z $geo ]] && {
			# Query local DB for info
		# }
		[[ -z $exit_ip ]] && exit_ip=$(curl -fsSL --max-time 15 ifconfig.me 2>/dev/null)
	} # wg show

	if [[ -z $ep_ip ]]; then
		rm -f "${LOGFNAME}"
	else
		local myip
		myip=$(ip addr show | grep inet | grep -F 172.20.0.)
		myip="${myip#*inet }"
		myip="${myip%%/*}"
		echo -en "\
SFVPN_MY_IP=\"${myip}\"\n\
SFVPN_EXEC_TS=\"$(date -u +%s)\"\n\
SFVPN_ENDPOINT_IP=\"${ep_ip}\"\n\
SFVPN_GEOIP=\"${geo:-Artemis}\"\n\
SFVPN_PROVIDER=\"${PROVIDER}\"
SFVPN_EXIT_IP=\"${exit_ip:-333.1.2.3}\"\n" >"${LOGFNAME}"
	fi

	create_vpn_status

	# For Reverse Port Forward:
	ip route add 10.11.0.0/16 via "${SF_ROUTER_IP}" 2>/dev/null

	# Delete all old port forwards.
	[[ "${PROVIDER,,}" == "cryptostorm" ]] && curl -fsSL --retry 3 --max-time 10 http://10.31.33.7/fwd -ddelallfwd=1

	redis-cli -h 172.20.2.254 RPUSH portd:cmd "vpnup ${PROVIDER}" >/dev/null
	true
}

[[ -z $2 ]] && exit 254

export REDISCLI_AUTH="${SF_REDIS_AUTH}"

SF_ROUTER_IP="172.20.0.2"
LOGFNAME="$1"
OP="$2"
DEV="${3:-wg0}"
DSTDIR="$(dirname "${LOGFNAME}")"

[[ ! -d "${DSTDIR}" ]] && { umask 077; mkdir -p "${DSTDIR}"; }
[[ "$OP" == "down" ]] && { down; exit; }

source /check_vpn.sh
wait_for_handshake "${DEV}" || { echo -e "Handshake did not complete"; exit 255; }

check_vpn "${PROVIDER}" "${DEV}" || { echo -e "VPN Check failed"; exit 255; }

[[ "$OP" == "up" ]] && { up; exit; }

echo >&2 "OP=${OP}"
echo >&2 "Usage: [output filename] [up/pdown] [interface] <mullvad/cryptostorm>"
exit 255
