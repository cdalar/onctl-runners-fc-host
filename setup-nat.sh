#!/usr/bin/env bash
# Sets up IP forwarding and NAT masquerade on the fc-host so Firecracker
# microVMs can reach the internet. Run ON the fc-host after OS install.
#
# Usage: bash fc-host/scripts/setup-nat.sh [outbound-interface]
#
# The outbound interface defaults to the one used by the default route.
# On Hetzner AX41 this is typically enp41s0.
set -euo pipefail

IFACE="${1:-$(ip route show default | awk '/default/ {print $5; exit}')}"

echo "==> outbound interface: $IFACE"
echo "==> enabling IP forwarding"
echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-fc.conf
sysctl -p /etc/sysctl.d/99-fc.conf

echo "==> adding iptables NAT rules (bridge: fcbr0 -> $IFACE)"
iptables -t nat -A POSTROUTING -o "$IFACE" -j MASQUERADE
iptables -A FORWARD -i fcbr0 -o "$IFACE" -j ACCEPT
iptables -A FORWARD -i "$IFACE" -o fcbr0 -m state --state RELATED,ESTABLISHED -j ACCEPT

echo "==> persisting rules"
apt-get install -y -qq iptables-persistent >/dev/null
netfilter-persistent save

echo "==> done. microVMs on fcbr0 (172.16.0.0/24) can now reach the internet via $IFACE"
