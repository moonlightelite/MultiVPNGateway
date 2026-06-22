#!/usr/bin/env bash

set -ex

[[ $UID != 0 ]] && exec sudo -E "$(readlink -f "$0")" "$@"

NS="vpn"
WGIF="wg"
#WGCONF="/etc/wireguard/$WGIF.conf"
#WGADDRIPV4="10.10.10.10/24"
gatewayIP="172.30.30."
wgIP=(10.5.0.2/32 10.5.0.2/32 10.5.0.2/32 10.5.0.2/32 10.5.0.2/32)

up() {
    brctl addbr br0 || true
    brctl addif br0 ens20 || true

    echo 1 > /proc/sys/net/ipv4/ip_forward
    for ((i=0;i<${#wgIP[@]};i++)); 
    do
        WGCONF="/etc/wireguard/$WGIF$i.conf"
        ip netns add $NS$i
        ip link add $WGIF$i type wireguard
        wg setconf $WGIF$i $WGCONF
        ip link set $WGIF$i netns $NS$i
	ip link add name vethhost$i type veth peer name vethvpn$i
	ip link set vethhost$i up
	ip link set vethvpn$i up
	ip link set vethvpn$i netns $NS$i
	brctl addif br0 vethhost$i

        ip -n $NS$i addr add ${wgIP[$i]} dev $WGIF$i
        ip -n $NS$i link set lo up
        ip -n $NS$i link set $WGIF$i up
        ip -n $NS$i link set vethvpn$i up
        ip -n $NS$i route add default dev $WGIF$i
        ip netns exec $NS$i bash -c "echo 1 > /proc/sys/net/ipv4/ip_forward"
	ip netns exec $NS$i ip addr add $gatewayIP$(($i + 1))/24 dev vethvpn$i
        ip netns exec $NS$i iptables -w -t nat -A POSTROUTING -o $WGIF$i -j MASQUERADE 
        ip netns exec $NS$i iptables -w -A FORWARD -i vethvpn$i -j ACCEPT
    done
}

down() {
    for ((i=0;i<${#wgIP[@]};i++)); 
    do
        ip -n $NS$i link set $WGIF$i down
        ip -n $NS$i link del $WGIF$i
	sleep 1
        ip netns del $NS$i
    done
}

status() {
    for ((i=0;i<${#wgIP[@]};i++)); 
    do
        ip netns exec $NS$i wg
    done
}

execi() {
    exec ip netns exec $NS$1 sudo -E -u \#${SUDO_UID:-$(id -u)} -g \#${SUDO_GID:-$(id -g)} -- "${@:2}"
}

command="$1"
shift

case "$command" in
    up) up "$@" ;;
    down) down "$@" ;;
    exec) execi "$@" ;;
    status) status "$@" ;;
    *) echo "Usage: $0 up|down|exec" >&2; exit 1 ;;
esac
