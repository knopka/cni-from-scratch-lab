#!/bin/bash
# Full cleanup after any local lab. Touches ONLY objects with lab names.
set -u

# 1. overlay processes (lab 5)
pkill -f 'socat .*tun-name=tun0' 2>/dev/null

# 2. all lab netns (veth/bridge/tun inside them die with the netns)
for ns in con1 con2 n1c1 n1c2 n2c1 n2c2 node1 node2 rtr; do
  ip netns del "$ns" 2>/dev/null
done

# 3. objects in the root netns
for l in br0 lab-sw sw1 sw2 veth1 cni0 tun0 vxlan0; do
  ip link del "$l" 2>/dev/null
done
ip route del 172.16.0.0/24 2>/dev/null
ip route del 172.16.1.0/24 2>/dev/null

# 4. plugin state and libcni result cache (lab 7)
rm -rf /var/lib/labcni
rm -f /var/lib/cni/results/labnet-* 2>/dev/null

echo "lab cleaned; remaining lab objects (should be empty):"
ip netns list
ip -br link | grep -E 'br0|lab-sw|sw[12]|veth|cni0|tun0|vxlan0' || true
