# cni-from-scratch-lab

Container networking → the Kubernetes network model → CNI, built by hand.

Seven labs, each one building on the previous. Labs 1–3, 5 and 7 run on a single Linux machine:
"nodes" and "containers" are network namespaces. Labs 4 and 6 repeat the two-node scenarios on two
real EC2 instances, where the VPC pushes back in exactly the ways that shaped flannel, Calico and the
AWS VPC CNI. Nothing is scripted: you type every command and watch what changed.

| Lab | What you build | What you learn | Real-world counterpart |
|---|---|---|---|
| 1 | netns + veth | what a container is, network-wise | any CNI: "put an interface in the pod" |
| 2 | 2 netns + bridge | pod↔pod on one node, egress via SNAT | `bridge` + `host-local` + MASQUERADE |
| 3 | 2 nodes, same L2 (netns) | pod↔pod across nodes, no encapsulation | flannel host-gw, Calico without IPIP |
| 4 | 2 nodes, same L2 (**AWS**) | why host-gw "does not work on AWS" | source/dest check, VPC route tables, flannel aws-vpc |
| 5 | 2 nodes behind a router (netns) | overlay: tun+UDP, then VXLAN | flannel udp/vxlan, Calico IPIP |
| 6 | 2 nodes, different subnets (**AWS**) | overlay on a network you do not control | flannel vxlan / Calico vxlan on EC2 |
| 7 | your own CNI plugin in bash | runtime↔plugin contract, IPAM, DEL/CHECK, result cache | libcni, containerd, every plugin |

Files:

```
README.md          this guide
plugin/labcni      the bash CNI plugin (lab 7)
plugin/labnet.conf its network config
cleanup.sh         removes every local lab object
```

---

## 0. Setup

**Local labs (1, 2, 3, 5, 7).** Ubuntu with root (`sudo -i`). Everything below runs as root.

```bash
apt-get install -y iproute2 tcpdump socat jq bridge-utils conntrack
```
Check:
1. The lab names (`con1`, `node1`, `br0`, `lab-sw`, `cni0`, `tun0`) and subnets
   do not collide with anything on the node — check `ip route | head` against your VPC CIDR.
2. Labs 3, 5 and 7 live inside namespaces and do not touch the root netns (except one IP-less bridge).
3. In lab 7 you **never** put a config into `/etc/cni/net.d` — we use separate directories.

Cleanup after any local lab: `bash cleanup.sh` (only deletes objects with lab names).

**AWS labs (4, 6).** Two EC2 instances (t3.micro is enough), Ubuntu, in the same VPC, both reachable
by SSH, plus the AWS CLI with permissions for `ec2:ModifyInstanceAttribute`,
`ec2:ModifyNetworkInterfaceAttribute`, `ec2:AuthorizeSecurityGroupIngress`, `ec2:CreateRoute`.
Launching the instances is out of scope — the labs assume they exist. Lab 4 starts with both
nodes in the **same subnet**; lab 4 part B and lab 6 need them in **different subnets** (two
subnets in different AZs is the realistic setup). Throughout, substitute your own values:

```bash
NODE_A=<private IP of node A>      NODE_B=<private IP of node B>
INST_A=<instance id of A>          INST_B=<instance id of B>
ENI_A=<primary ENI id of A>        ENI_B=<primary ENI id of B>
SG=<security group both nodes use> RTB=<route table id of their subnet(s)>
IF=$(ip route | awk '/^default/{print $5; exit}')   # run on each node: ens5 on ENA, eth0 on older AMIs
```

**Command cheat sheet**

```bash
ip netns list                          # which namespaces exist
ip -n <ns> addr / link / route / neigh # run ip inside a namespace
ip netns exec <ns> <any command>       # ping, tcpdump, sysctl inside a namespace
ip -br link / ip -br addr              # compact output
bridge link show / bridge fdb show     # bridge ports and MAC table
tcpdump -ni <iface> icmp               # -n no DNS, -i interface
```

**The mental model we are testing:** a network namespace is a separate instance of the network
stack — its own interfaces, routing table, iptables, conntrack and sysctls (`ip_forward`, `rp_filter`).
Everything any CNI does is connecting these stacks to each other.

---

## Lab 1. One container (single network namespace)

**Goal:** see that "the container's network" is a netns, and that connectivity to the host is a
veth pair plus two routes.

```
 host (root netns)                          con1 (netns)
 ┌───────────────────────────┐              ┌──────────────────────┐
 │ eth0  <VPC IP>            │              │ eth0  172.16.0.2/24  │
 │                           │              │                      │
 │ veth1 172.16.0.1/24 ──────┼── veth pair ─┼── eth0               │
 │                           │              │                      │
 │ route: 172.16.0.0/24      │              │ route: default       │
 │        dev veth1          │              │   via 172.16.0.1     │
 └───────────────────────────┘              └──────────────────────┘
```

### Steps

```bash
ip netns add con1                       # 1. a fresh network stack. Only lo inside, and it is down
ip -n con1 link                         #    see for yourself

ip link add veth1 type veth peer name eth0 netns con1
                                        # 2. veth pair: veth1 stays on the host, the other end is
                                        #    born directly inside con1 as eth0
ip -br link | grep veth1                #    on the host: veth1@if<N> — N is the peer's index in the other ns
ip -n con1 -br link                     #    inside con1: eth0@if<M>

ip addr add 172.16.0.1/24 dev veth1     # 3. IP on the host end
ip link set veth1 up
ip route | grep 172.16                  #    the route 172.16.0.0/24 dev veth1 appeared BY ITSELF:
                                        #    addr add with /24 installs a connected route

ip -n con1 addr add 172.16.0.2/24 dev eth0   # 4. IP for the container
ip -n con1 link set eth0 up
ip -n con1 link set lo up
ip -n con1 route add default via 172.16.0.1  # 5. everything that is not 172.16.0.0/24 goes to the host
ip -n con1 route
```

### Check

```bash
ping -c2 172.16.0.2                     # host -> con1
ip netns exec con1 ping -c2 172.16.0.1  # con1 -> host
ip netns exec con1 ping -c2 8.8.8.8     # con1 -> internet. Does it work? Checking in next lab.
```

Things to notice:
- There is no process inside `con1`, yet ping is answered — the kernel stack inside the netns replies.
- `ip -n con1 neigh` shows the host's ARP entry; `ip neigh | grep 172.16` shows the container's.
  veth is an L2 link: ARP crosses it like a cable.
- `ping 8.8.8.8`: the packet leaves through the host's `eth0` with src `172.16.0.2`. If there is no
  reply, that is correct — nobody on the internet has a route back to `172.16.0.2`. If there **is**
  a reply, something already SNATs it: `iptables -t nat -S POSTROUTING`.
  Verify with `tcpdump -ni eth0 icmp` — what src IP does the packet really leave with?


```bash
bash cleanup.sh
```

---

## Lab 2. Two containers on one node (bridge)

**Goal:** see why a bridge is needed, why it gets an IP, and how egress to the internet works.

```
 host (root netns)
 ┌─────────────────────────────────────────────────────────────┐
 │  con1 (netns)              con2 (netns)                     │
 │  ┌───────────────┐         ┌───────────────┐                │
 │  │eth0 172.16.0.2│         │eth0 172.16.0.3│                │
 │  └──────┬────────┘         └──────┬────────┘                │
 │       veth1                     veth2                       │
 │  ┌──────┴─────────────────────────┴───────┐                 │
 │  │  br0   172.16.0.1/24  (L2 switch + gw) │                 │
 │  └────────────────────────────────────────┘                 │
 │                                                             │
 │  eth0 <VPC IP>       route: 172.16.0.0/24 dev br0           │
 └─────────────────────────────────────────────────────────────┘
   inside containers: default via 172.16.0.1
```

### Steps

```bash
ip link add br0 type bridge             # 1. bridge = software L2 switch
ip addr add 172.16.0.1/24 dev br0       # 2. IP on the bridge -> it is the subnet's gateway (docker0 / cni0)
ip link set br0 up

for i in 1 2; do                        # 3. lab 1 twice, except the host end is plugged into
  ip netns add con$i                    #    the bridge instead of getting an IP
  ip link add veth$i type veth peer name eth0 netns con$i
  ip link set veth$i master br0         #    <- the key command: a port in the switch
  ip link set veth$i up
  ip -n con$i addr add 172.16.0.$((i+1))/24 dev eth0
  ip -n con$i link set eth0 up
  ip -n con$i link set lo up
  ip -n con$i route add default via 172.16.0.1
done

bridge link show                        # bridge ports
```

### Check

```bash
ip netns exec con1 ping -c2 172.16.0.3  # con1 -> con2
```

Look at **TTL=64** in the reply: the packet was not routed — it crossed the switch at L2.

```bash
tcpdump -ni br0 -c6 &                   # terminal 1
ip netns exec con1 ping -c2 172.16.0.3  # terminal 2
```
The dump shows ARP who-has/is-at first, then ICMP. The bridge learns MAC addresses:
```bash
bridge fdb show br br0 | grep -v permanent   # container MACs and which port they sit on
```

### Egress to the internet

```bash
ip netns exec con1 ping -c2 8.8.8.8     # works? tcpdump -ni eth0 icmp — which src? (execute in root netns)
sysctl net.ipv4.ip_forward              # must be 1 for the host to forward other people's packets
sysctl -w net.ipv4.ip_forward=1         # if not 1 from upper command

iptables -t nat -A POSTROUTING -s 172.16.0.0/24 ! -o br0 -j MASQUERADE
                                        # SNAT: src 172.16.0.x -> host IP, BUT not for traffic into
                                        # the bridge itself (pod->pod without NAT — the k8s model rule)
ip netns exec con1 ping -c2 8.8.8.8
tcpdump -ni eth0 icmp                   # src is now the host IP eth0 or ens5
tcpdump -ni br0 icmp
conntrack -L | grep 172.16              # the translation entry the kernel uses to return the reply to con1
```


**Note:** "Why does the bridge have an IP?" — without one it is a pure switch between
pods; with one it becomes the pods' default gateway and the entry point into the node's routing table.

```bash
iptables -t nat -D POSTROUTING -s 172.16.0.0/24 ! -o br0 -j MASQUERADE
iptables -D FORWARD -i br0 -j ACCEPT 2>/dev/null; iptables -D FORWARD -o br0 -j ACCEPT 2>/dev/null
bash cleanup.sh
```

---

## Lab 3. Two nodes on one L2 (host-gw), local

**Goal:** pod on node 1 → pod on node 2 with no encapsulation. The secret is one `ip route` line.

From here on nodes are namespaces too (`node1`, `node2`), so each has its own stack, its own
`ip_forward`, its own iptables. The switch between them is bridge `lab-sw` in the root netns
**without an IP**.

```
 node1 (netns)  podCIDR 172.16.0.0/24        node2 (netns)  podCIDR 172.16.1.0/24
 ┌───────────────────────────────┐            ┌───────────────────────────────┐
 │ n1c1 .2      n1c2 .3          │            │ n2c1 .2      n2c2 .3          │
 │   └─veth1──┐  └─veth2──┐      │            │   └─veth1──┐  └─veth2──┐      │
 │      br0 172.16.0.1/24        │            │      br0 172.16.1.1/24        │
 │                               │            │                               │
 │ eth0 10.0.0.10/24             │            │ eth0 10.0.0.20/24             │
 │ route 172.16.1.0/24 via       │            │ route 172.16.0.0/24 via       │
 │       10.0.0.20  <───────┐    │            │       10.0.0.10               │
 └────────────┬─────────────┼────┘            └────────────┬──────────────────┘
              │             │ THIS is host-gw              │
        ┌─────┴─────────────┴──────────────────────────────┴─────┐
        │                lab-sw  (L2, no IP)                     │
        └────────────────────────────────────────────────────────┘
```

### Steps

A node is built from the same commands as labs 1–2, only inside a netns. To avoid typing them
twice, define a function **in your shell** (read every line — nothing here is new):

```bash
mk_node() {   # mk_node <name> <switch> <node IP> <podCIDR prefix>
  local n=$1 sw=$2 nip=$3 p=$4
  ip netns add $n
  ip link add $n-eth0 type veth peer name eth0 netns $n   # the node's "NIC"
  ip link set $n-eth0 master $sw                          # plugged into the switch
  ip link set $n-eth0 up
  ip -n $n addr add $nip/24 dev eth0
  ip -n $n link set eth0 up
  ip -n $n link set lo up
  ip netns exec $n sysctl -qw net.ipv4.ip_forward=1       # a node is a router for its pods
  ip -n $n link add br0 type bridge                       # --- lab 2 from here ---
  ip -n $n addr add $p.1/24 dev br0
  ip -n $n link set br0 up
  local i c
  for i in 1 2; do
    c=${n/node/n}c$i                                      # node1 -> n1c1, n1c2
    ip netns add $c
    ip -n $n link add veth$i type veth peer name eth0 netns $c
    ip -n $n link set veth$i master br0
    ip -n $n link set veth$i up
    ip -n $c addr add $p.$((i+1))/24 dev eth0
    ip -n $c link set eth0 up
    ip -n $c link set lo up
    ip -n $c route add default via $p.1
  done
}
```

```bash
ip link add lab-sw type bridge && ip link set lab-sw up   # the switch between nodes
mk_node node1 lab-sw 10.0.0.10 172.16.0
mk_node node2 lab-sw 10.0.0.20 172.16.1

ip netns exec node1 ping -c2 10.0.0.20   # nodes see each other (one L2)
ip netns exec n1c1 ping -c2 172.16.1.2   # pod -> pod on the other node: does NOT work. Why? - No routes
ip -n node1 route                        # node1 has no route to 172.16.1.0/24
```

Add one line per node — this is everything flannel host-gw does:

```bash
ip -n node1 route add 172.16.1.0/24 via 10.0.0.20
ip -n node2 route add 172.16.0.0/24 via 10.0.0.10
ip netns exec n1c1 ping -c2 172.16.1.2
```

### Check

- **TTL=62**: routed twice (node1 and node2). Ping `10.0.0.20` from `n1c1` — TTL=63.
- The packet travels **without encapsulation**: real pod addresses are visible entering node2:
  ```bash
  ip netns exec node2 tcpdump -ni eth0 icmp -c2
  ```
- Trace the path: `ip netns exec n1c1 ip route get 172.16.1.2` → via 172.16.0.1;
  `ip netns exec node1 ip route get 172.16.1.2` → via 10.0.0.20 dev eth0.
- `ip -n node1 neigh` — node1 knows node2's MAC; ARP is required because the next hop is on the same L2.

### Break it
- `ip netns exec node2 sysctl -w net.ipv4.ip_forward=0` → packets reach node2 (tcpdump on eth0
  sees them) and die there: the node refuses to forward what is not its own.
- `ip -n node2 route del 172.16.0.0/24` → the request reaches `n2c1`, the reply never returns.
  Asymmetry: `tcpdump -ni br0` in node2 shows echo requests; the replies leave and get lost.

**Note:** "How does a node learn its neighbours' podCIDRs?" — someone must distribute them: the Kubernetes
API (flannel reads node.spec.podCIDR and publishes VTEP data in node annotations; standalone
flanneld used etcd directly), BGP (Calico), a cloud route table (aws-vpc backend). Here you did it by hand.

Keep this running if you go straight to lab 5 (`bash cleanup.sh` only if you want a fresh start).

---

## Lab 4. Two nodes on one L2 (host-gw), AWS

**Goal:** repeat lab 3 on two EC2 instances and discover that a VPC is not a real L2: the exact
same routes silently fail until you deal with the source/destination check and security groups.
Then move one node to another subnet and see the only way host-gw survives: VPC route tables.

### Part A — same subnet

```
 node A (EC2, subnet S1)  podCIDR 172.16.0.0/24    node B (EC2, subnet S1)  podCIDR 172.16.1.0/24
 ┌────────────────────────────────┐                 ┌────────────────────────────────┐
 │ c1 .2   c2 .3                  │                 │ c1 .2   c2 .3                  │
 │  └─veth1─┐ └─veth2─┐           │                 │  └─veth1─┐ └─veth2─┐           │
 │     br0 172.16.0.1/24          │                 │     br0 172.16.1.1/24          │
 │ ens5 $NODE_A                   │                 │ ens5 $NODE_B                   │
 │ route 172.16.1.0/24 via $NODE_B│                 │ route 172.16.0.0/24 via $NODE_A│
 └────────────┬───────────────────┘                 └───────────┬────────────────────┘
              │                                                 │
        ┌─────┴─────────────────────────────────────────────────┴─────┐
        │  VPC "L2": ARP is emulated, every packet is checked against │
        │  the ENI's IPs (source/dest check) and the security group   │
        └─────────────────────────────────────────────────────────────┘
```

On **each** node, build the pod side of lab 2 (bridge + two containers). `mk_pods` is the inner
half of `mk_node` from lab 3; the node itself is now real hardware:

```bash
mk_pods() {   # mk_pods <podCIDR prefix>      run as root on the node
  local p=$1 i
  sysctl -qw net.ipv4.ip_forward=1
  ip link add br0 type bridge
  ip addr add $p.1/24 dev br0
  ip link set br0 up
  for i in 1 2; do
    ip netns add c$i
    ip link add veth$i type veth peer name eth0 netns c$i
    ip link set veth$i master br0
    ip link set veth$i up
    ip -n c$i addr add $p.$((i+1))/24 dev eth0
    ip -n c$i link set eth0 up
    ip -n c$i link set lo up
    ip -n c$i route add default via $p.1
  done
}
```

```bash
# node A                                        # node B
mk_pods 172.16.0                                mk_pods 172.16.1
ip route add 172.16.1.0/24 via $NODE_B          ip route add 172.16.0.0/24 via $NODE_A
ip route get 172.16.1.2                         # via $NODE_B dev ens5 — the kernel is happy
ping -c2 $NODE_B                                # node -> node works
ip netns exec c1 ping -c2 172.16.1.2            # pod -> pod: nothing
```

Find where the packet dies:

```bash
# node A                                        # node B
tcpdump -ni ens5 icmp                           tcpdump -ni ens5 icmp
ip netns exec c1 ping -c2 172.16.1.2
```
Node A sends the packet (src 172.16.0.2, dst 172.16.1.2, correct dst MAC). Node B's tcpdump
sees **nothing**. The VPC dropped it in between — the packet's src IP is not one of ENI A's
addresses, and its dst IP is not one of ENI B's.
**Note:** this is specific to the VPC, not to Linux. On-prem a subnet is a real broadcast
domain: the switch forwards by MAC and any IP works inside the segment. A VPC subnet is
L2 *emulated* over a routed fabric: the hypervisor answers ARP itself, forwards by IP, and
only delivers packets whose src/dst belong to an ENI. There is no switch to be "honest".
The same `ip route` line that just works on-prem needs the cloud's permission here.

Fix 1 — the source/destination check, per ENI, both nodes:

```bash
aws ec2 modify-instance-attribute --instance-id $INST_A --no-source-dest-check
aws ec2 modify-instance-attribute --instance-id $INST_B --no-source-dest-check
ip netns exec c1 ping -c2 172.16.1.2            # still nothing? read on
```

Fix 2 — the security group. It did not need changing here, and that is worth understanding:
a rule whose source is a *security group* (`from sg-self`) matches on the sending ENI, not on
the packet's src IP, so pod traffic passes as soon as the source/dest check stops dropping it.
A rule whose source is a *CIDR* matches on the src IP in the header and will NOT match pod
addresses. If your SG only has CIDR rules between nodes, add the pod CIDR explicitly:

```bash
aws ec2 authorize-security-group-ingress --group-id $SG --protocol -1 --cidr 172.16.0.0/16
ip netns exec c1 ping -c2 172.16.1.2            # TTL=62 — lab 3, on real machines
```
Two different layers, two different things they look at: source/dest check — IPs in the header;
SG-by-reference — identity of the ENI; SG-by-CIDR — IPs in the header again.

### Check
- `tcpdump -ni ens5 icmp` on node B now shows the packet with pod addresses, no encapsulation.
- `ip neigh | grep $NODE_B` on node A — the "MAC" of node B. The VPC answered that ARP; there is
  no switch, the mapping service does it.
- `sysctl net.ipv4.conf.all.rp_filter` — Ubuntu defaults to 2 (loose), so the asymmetric-path
  trap from Chris's talk does not bite here. With 1 (strict) it would.

### Break it
- Re-enable the check on B only: `aws ec2 modify-instance-attribute --instance-id $INST_B
  --source-dest-check`. Node A still sends; tcpdump on B goes silent again, because the dst
  172.16.1.2 is not an address of ENI B. One flag, one direction, no error anywhere —
  this is why "host-gw on AWS" is a support ticket, not a config option.
- Replace the `from sg-self` rule with a CIDR rule for the node subnet only
  (`--cidr 172.31.0.0/16` in your VPC). Nodes still ping each other, pods do not: the SG now
  looks at src IPs, and 172.16.0.2 is not in the range. Flow logs would show REJECT; the hosts
  show nothing. Put the sg-self rule back (or add the pod CIDR) to recover.

### Part B — different subnets

A primary ENI is bound to its subnet for the life of the instance, so "node B in another subnet"
means a **new** instance in subnet S2 (same security group, same key pair); the old node B can be
terminated. You need this layout for lab 6 anyway.

```
 node A (EC2, subnet S1)  podCIDR 172.16.0.0/24                 node B (EC2, subnet S2)  podCIDR 172.16.1.0/24
 ┌────────────────────────────────┐                             ┌────────────────────────────────┐
 │ c1 .2   c2 .3                  │                             │ c1 .2   c2 .3                  │
 │  └─veth1─┐ └─veth2─┐           │                             │  └─veth1─┐ └─veth2─┐           │
 │     br0 172.16.0.1/24          │                             │     br0 172.16.1.1/24          │
 │ ens5 $NODE_A  (src/dst check OFF)                            │ ens5 $NODE_B  (src/dst check OFF)
 │ route: default via S1 gw       │                             │ route: default via S2 gw       │
 │ (no route for 172.16.1.0/24 —  │                             │ (no route for 172.16.0.0/24 —  │
 │  "via $NODE_B" is refused:     │                             │  same)                         │
 │  next hop not on-link)         │                             │                                │
 └────────────┬───────────────────┘                             └───────────┬────────────────────┘
              │ subnet S1                                                   │ subnet S2
        ┌─────┴──────┐                                                ┌─────┴──────┐
        │  S1 gw     │                                                │  S2 gw     │
        └─────┬──────┘                                                └─────┬──────┘
              │                                                             │
        ┌─────┴─────────────────────────────────────────────────────────────┴─────┐
        │                            VPC router                                   │
        │  route table $RTB (attached to S1 and S2):                              │
        │     172.16.0.0/24  →  $ENI_A        <- create-route, one line per node  │
        │     172.16.1.0/24  →  $ENI_B                                            │
        │     local VPC CIDR →  local                                             │
        │  still checks src/dst against ENI IPs and the security group            │
        └─────────────────────────────────────────────────────────────────────────┘

 packet c1(A) → c1(B):  172.16.0.2 → 172.16.1.2, no encapsulation
   A: default route → S1 gw → VPC router: lookup 172.16.1.0/24 → $ENI_B → B: br0 → c1
   TTL 61 = routed by A, by the VPC router, by B
```

#### Step 1 — bring up the new node B and refresh the variables

```bash
NODE_B=<private IP of the new node B>   
INST_B=<its instance id>   
ENI_B=<its primary ENI id>

# on node B (fresh shell: define mk_pods again)
mk_pods 172.16.1                                       # includes ip_forward=1
aws ec2 modify-instance-attribute --instance-id $INST_B --no-source-dest-check   # a new instance has the check ON
```

Node A stays as it is from part A: `br0`, `c1`, `c2`, `ip_forward=1`, check disabled. Verify
before continuing — a stale `$NODE_B` (the old address, still in S1) would make the next step
succeed and hide the refusal it is meant to show:

```bash
echo $NODE_B                                           # must be an address in S2
aws ec2 describe-network-interfaces --network-interface-ids $ENI_A $ENI_B \
  --query 'NetworkInterfaces[].[NetworkInterfaceId,SourceDestCheck]'   # both false
```

#### Step 2 — host-gw is refused

```bash
# node A
ip route del 172.16.1.0/24                             # the part-A route, pointing at the old node B
ip route add 172.16.1.0/24 via $NODE_B                 # RTNETLINK answers: Nexthop has invalid gateway
ip route get $NODE_B                                   # via <S1 gw> dev ens5 — B is only reachable through the router
```

`via X` means "hand the frame directly to X", which needs ARP, which only works inside the
interface's subnet. `$NODE_B` is in S2, so the next hop is *not on-link* and the kernel refuses at
insert time, before any packet is sent. Same refusal as lab 5 step A — the difference is that in
lab 5 the router is yours.

#### Step 3 — teach the VPC router

The only non-overlay option left. This is flannel's `aws-vpc` backend and Calico's
"no encapsulation" mode on EC2: a route per node in the VPC route table, pointing at the node's ENI.

```bash
aws ec2 create-route --route-table-id $RTB --destination-cidr-block 172.16.0.0/24 --network-interface-id $ENI_A
aws ec2 create-route --route-table-id $RTB --destination-cidr-block 172.16.1.0/24 --network-interface-id $ENI_B
# nothing to add on the nodes: the other podCIDR already goes to the subnet gateway via the default route

# node A
ip netns exec c1 ping -c2 172.16.1.2                   # TTL=61: node A, VPC router, node B
```

Note on route tables: a table is attached to a subnet, so traffic from S1 is looked up in S1's
table and the reply in S2's. In a default VPC both subnets use the main table and `$RTB` is one
table; if S2 has its own table, add both routes to both.

#### Check

- `tcpdump -ni ens5 icmp` on node B: pod addresses on the wire, no encapsulation — the VPC router
  forwarded by its table, exactly like `rtr` in lab 5 step A.
- `ip route | grep 172.16` on either node: only the local `dev br0` route. All cross-node logic
  now lives in `$RTB`.
- Source/dest check must stay disabled on both ENIs: ENI B has to accept a dst that is not its own,
  ENI A has to send a src that is not its own. The SG must still admit pod IPs — `from sg-self`
  does (it matches the sending ENI); a CIDR-only SG needs the pod CIDR added.

#### Break it

- `aws ec2 delete-route --route-table-id $RTB --destination-cidr-block 172.16.1.0/24` → the request
  reaches the VPC router and is dropped there. Node A shows the packet leaving; node B sees nothing.
  Re-create the route to recover. This is what a node looks like whose `aws-vpc` daemon crashed
  before writing its route.
- `aws ec2 modify-instance-attribute --instance-id $INST_B --source-dest-check` → the route is
  fine, the router forwards, and ENI B drops the packet. Same silence, different layer.

#### Why nobody does this at scale

```bash
aws service-quotas get-service-quota --service-code vpc --quota-code L-93826ACB \
  --query 'Quota.Value'                                # routes per route table: 50 by default
```

One route per node, 50 per table (raisable to 1000, but every route is state in the fabric), and
every node running with the source/dest check off. A few dozen nodes is the practical ceiling. The
AWS VPC CNI took the opposite route: give pods real VPC addresses, so the VPC needs no routes, the ENI keeps its source/dest check, and the node needs no bridge. Compare on an EKS node:

```bash
aws ec2 describe-network-interfaces --network-interface-ids <ENI of an EKS node> \
  --query 'NetworkInterfaces[].SourceDestCheck'      # true — pod IPs are ENI addresses, so the check never
                                                     # sees a foreign IP and nothing needs to be disabled
ip route | grep -c ' dev eni'                        # one /32 per pod, no bridge, no overlay
```

The price moves to IPAM: subnet consumption and the per-instance ENI/IP limits — hence prefix
delegation and custom networking.

**Note:** "Why does Calico default to IPIP on EC2?" — because plain routing needs
the source/dest check off and either a shared subnet or a VPC route per node; encapsulation needs
neither. "Why does the VPC CNI use ENI secondary IPs?" — to make pod traffic look like instance
traffic to the VPC, avoiding both problems at the cost of subnet IP consumption. "Why is host-gw
limited to one subnet?" — a `via` route is one L2 hop: the next hop must be on-link.

#### Cleanup (leave the instances as they are — lab 6 uses this layout)

```bash
# both nodes
ip route del 172.16.1.0/24 2>/dev/null; ip route del 172.16.0.0/24 2>/dev/null
for i in 1 2; do ip netns del c$i; done; ip link del br0
# VPC
aws ec2 delete-route --route-table-id $RTB --destination-cidr-block 172.16.0.0/24
aws ec2 delete-route --route-table-id $RTB --destination-cidr-block 172.16.1.0/24

bash cleanup.sh
```

---

## Lab 5. Two nodes behind a router → overlay, local

**Goal:** understand why an overlay is needed and how it is built (tun + UDP), then replace it
with in-kernel VXLAN.

Between the nodes there is now a router `rtr` that knows nothing about `172.16.x`. This is what a
cloud network or two racks in different subnets look like.

```
 node1 (netns)  podCIDR 172.16.0.0/24                     node2 (netns)  podCIDR 172.16.1.0/24
 ┌────────────────────────────────────┐                   ┌────────────────────────────────────┐
 │ n1c1 .2   n1c2 .3                  │                   │ n2c1 .2   n2c2 .3                  │
 │   └─veth1─┐ └─veth2─┐              │                   │   └─veth1─┐ └─veth2─┐              │
 │      br0 172.16.0.1/24             │                   │      br0 172.16.1.1/24             │
 │                                    │                   │                                    │
 │ tun0 / vxlan0 192.168.100.1 (step B/C)                 │ tun0 / vxlan0 192.168.100.2 (step B/C)
 │                                    │                   │                                    │
 │ eth0 10.0.1.10/24                  │                   │ eth0 10.0.2.10/24                  │
 │ routes:                            │                   │ routes:                            │
 │   default via 10.0.1.1             │                   │   default via 10.0.2.1             │
 │   step A: 172.16.1.0/24 via 10.0.1.1                   │   step A: 172.16.0.0/24 via 10.0.2.1
 │   step B: 172.16.1.0/24 dev tun0   │                   │   step B: 172.16.0.0/24 dev tun0   │
 │   step C: 172.16.1.0/24 via 192.168.100.2 dev vxlan0   │   step C: 172.16.0.0/24 via 192.168.100.1 dev vxlan0
 └───────────────┬────────────────────┘                   └───────────────┬────────────────────┘
                 │ node1-eth0 (root netns)                                │ node2-eth0 (root netns)
           ┌─────┴─────┐          ┌──────────────────────┐          ┌─────┴─────┐
           │    sw1    ├── rtr-r1 ┤ rtr (netns)          ├ rtr-r2 ──┤    sw2    │
           │ (no IP)   │          │  r1 10.0.1.1/24      │          │ (no IP)   │
           └───────────┘          │  r2 10.0.2.1/24      │          └───────────┘
                                  │  ip_forward=1        │
                                  │  step A only:        │
                                  │   172.16.0.0/24 via 10.0.1.10
                                  │   172.16.1.0/24 via 10.0.2.10
                                  │  steps B/C: knows nothing about 172.16
                                  └──────────────────────┘

 on the wire between sw1 and sw2:
   step A:   172.16.0.2 → 172.16.1.2            plain, TTL 61 at the far pod
   step B:   10.0.1.10:9000 → 10.0.2.10:9000    UDP, inner packet in payload
   step C:   10.0.1.10 → 10.0.2.10 UDP 4789     VXLAN, inner Ethernet frame in payload
```

### Steps: topology

```bash
ip link add sw1 type bridge && ip link set sw1 up
ip link add sw2 type bridge && ip link set sw2 up

ip netns add rtr                                     # router: two interfaces, forwarding on
ip link add rtr-r1 type veth peer name r1 netns rtr
ip link add rtr-r2 type veth peer name r2 netns rtr
ip link set rtr-r1 master sw1; ip link set rtr-r1 up
ip link set rtr-r2 master sw2; ip link set rtr-r2 up
ip -n rtr addr add 10.0.1.1/24 dev r1; ip -n rtr link set r1 up
ip -n rtr addr add 10.0.2.1/24 dev r2; ip -n rtr link set r2 up
ip -n rtr link set lo up
ip netns exec rtr sysctl -qw net.ipv4.ip_forward=1

mk_node node1 sw1 10.0.1.10 172.16.0                 # function from lab 3
mk_node node2 sw2 10.0.2.10 172.16.1
ip -n node1 route add default via 10.0.1.1
ip -n node2 route add default via 10.0.2.1

ip netns exec node1 ping -c2 10.0.2.10               # nodes see each other via the router (TTL 63)
```

### Step A: why host-gw no longer works

```bash
ip -n node1 route add 172.16.1.0/24 via 10.0.2.10
# RTNETLINK answers: Nexthop has invalid gateway  <- next hop is not on our L2, the kernel refuses
```

The "teach the router" option (what cloud route tables and BGP peering with the ToR do):
```bash
ip -n node1 route add 172.16.1.0/24 via 10.0.1.1
ip -n node2 route add 172.16.0.0/24 via 10.0.2.1
ip -n rtr route add 172.16.0.0/24 via 10.0.1.10
ip -n rtr route add 172.16.1.0/24 via 10.0.2.10
ip netns exec n1c1 ping -c2 172.16.1.2               # works, TTL=61 (3 hops)
```
Now assume the router is not yours. Remove its knowledge and move to an overlay:
```bash
ip -n rtr route del 172.16.0.0/24; ip -n rtr route del 172.16.1.0/24
ip -n node1 route del 172.16.1.0/24; ip -n node2 route del 172.16.0.0/24
```

### Step B: overlay by hand — tun + UDP (flannel udp backend)

Idea: `tun0` is an interface with no hardware behind it; whatever the kernel routes into it is
handed to a user-space process as a raw IP packet. The process (`socat` here) wraps it in UDP and
sends it to the **node IP**, which the router does know. The other side mirrors it.

```
 n1c1 ──br0──> node1 kernel: dst 172.16.1.2 -> route dev tun0
                 │
                 v
               tun0 ──> socat: [UDP 10.0.1.10:9000 -> 10.0.2.10:9000 | payload = IP packet 172.16.0.2->172.16.1.2]
                 │
              eth0 ──> sw1 ──> rtr ──> sw2 ──> node2 eth0 ──> socat:9000 ──> tun0 ──> node2 kernel ──> br0 ──> n2c1
```

```bash
ip netns exec node1 socat UDP-DATAGRAM:10.0.2.10:9000,bind=:9000 TUN:192.168.100.1/24,tun-name=tun0,iff-up &
ip netns exec node2 socat UDP-DATAGRAM:10.0.1.10:9000,bind=:9000 TUN:192.168.100.2/24,tun-name=tun0,iff-up &
sleep 1; jobs
ip -n node1 -br link show tun0; ip -n node2 -br link show tun0
ip -n node1 route add 172.16.1.0/24 dev tun0
ip -n node2 route add 172.16.0.0/24 dev tun0
ip netns exec n1c1 ping -c2 172.16.1.2 # TTL=62
```

### Check: three layers of one packet

```bash
ip netns exec n1c1 ping 172.16.1.2 > /dev/null &

ip netns exec rtr   tcpdump -ni r1  udp port 9000 -c2   # 1. at the router: only 10.0.1.10 -> 10.0.2.10,
                                                        #    pod addresses are hidden in the payload
ip netns exec node2 tcpdump -ni tun0 -c2                # 2. after decapsulation: 172.16.0.2 -> 172.16.1.2
ip netns exec node2 tcpdump -ni br0  -c2                # 3. same packet, wrapped in Ethernet for the switch
```
TTL is still 62: encapsulation is not a hop; routing happens only on the two nodes.

### MTU — the mandatory overlay trap

```bash
ip -n node1 link show tun0 | grep mtu                   # 1500 by default — but the outside adds 28 bytes IP+UDP
ip netns exec n1c1 ping -c1 -M do -s 1472 172.16.1.2    # 1472+28 = 1500 inside; 1528 outside -> fragmentation
ip netns exec rtr tcpdump -ni r1 -c4 'ip[6:2] & 0x3fff != 0'   # you see the fragments
ip -n node1 link set tun0 mtu 1472; ip -n node2 link set tun0 mtu 1472
ip netns exec n1c1 ping -c1 -M do -s 1472 172.16.1.2    # now an honest refusal: message too long
```
This is why flannel udp sets MTU 1472 and VXLAN 1450 (50 bytes of headers), and why the AWS VPC
CNI, having no overlay, lets pods run at 9001.

### Step C: the same thing in the kernel — VXLAN (flannel vxlan, Calico vxlan, Cilium)

Replace socat with a vxlan interface: the kernel encapsulates, no user-space round trip.

```bash
pkill -f 'tun-name=tun0'
ip -n node1 link add vxlan0 type vxlan id 42 dev eth0 local 10.0.1.10 remote 10.0.2.10 dstport 4789
ip -n node2 link add vxlan0 type vxlan id 42 dev eth0 local 10.0.2.10 remote 10.0.1.10 dstport 4789
ip -n node1 addr add 192.168.100.1/24 dev vxlan0; ip -n node1 link set vxlan0 up
ip -n node2 addr add 192.168.100.2/24 dev vxlan0; ip -n node2 link set vxlan0 up
ip -n node1 route add 172.16.1.0/24 via 192.168.100.2
ip -n node2 route add 172.16.0.0/24 via 192.168.100.1
ip netns exec n1c1 ping -c2 172.16.1.2

ip -n node1 link show vxlan0 | grep mtu                  # 1450 — the kernel computed it
ip netns exec rtr tcpdump -ni r1 udp port 4789 -c2       # tcpdump decodes VXLAN and shows the inner
                                                         # packet — compare with the socat version
bridge -n node1 fdb show dev vxlan0                      # 00:00:00:00:00:00 dst 10.0.2.10 — where to send
```

Difference from the tun version: vxlan is an **L2** tunnel (an Ethernet frame inside, hence ARP
through the tunnel and an fdb entry), tun is L3. Hence `+50` bytes instead of `+28`.

### Break it
- `ip netns exec rtr iptables -A FORWARD -p udp --dport 4789 -j DROP` — "the firewall between
  subnets drops VXLAN". Nodes ping, pods do not. The most common production overlay incident.
- Put the MTU of tun0/vxlan0 back to 1500 and push large packets with `curl`/`iperf`: small pings
  live, large TCP segments fragment or vanish silently (if DF is set somewhere).

**Note:** "Overlay vs native routing?" — an overlay works on any network and does not
require it to know pod addresses; it pays in MTU, CPU and debugging complexity. Native (host-gw,
BGP, VPC routes) is faster and transparent but needs the network's cooperation or its IP space.
VXLAN won in k8s.

```bash
bash cleanup.sh
```

---

## Lab 6. Two nodes in different subnets → overlay, AWS

**Goal:** lab 5 on the network you actually run on. Nodes in different subnets (ideally different
AZs); the VPC router between them plays `rtr`. See why the overlay needs none of lab 4's VPC
changes, which single security-group rule it does need, and how MTU behaves with 9001 jumbo frames.

```
 node A (EC2, subnet S1, AZ a)                       node B (EC2, subnet S2, AZ b)
 podCIDR 172.16.0.0/24                               podCIDR 172.16.1.0/24
 ┌──────────────────────────────┐                    ┌──────────────────────────────┐
 │ c1 .2  c2 .3 ── br0 .1       │                    │ c1 .2  c2 .3 ── br0 .1       │
 │ vxlan0 192.168.100.1  mtu 8951                    │ vxlan0 192.168.100.2  mtu 8951
 │ route 172.16.1.0/24 via 192.168.100.2             │ route 172.16.0.0/24 via 192.168.100.1
 │ ens5 $NODE_A  mtu 9001       │                    │ ens5 $NODE_B  mtu 9001       │
 └────────────┬─────────────────┘                    └────────────┬─────────────────┘
              │      UDP 4789  $NODE_A -> $NODE_B  (outer IPs = ENI IPs)          │
        ┌─────┴───────────────────────────────────────────────────────────────────┴─────┐
        │   VPC router: sees only instance traffic. Source/dest check ON. No routes.    │
        └───────────────────────────────────────────────────────────────────────────────┘
```

### Steps

First put the VPC back to its defaults — the point of this lab is that the overlay does not need
lab 4's changes:

```bash
aws ec2 modify-instance-attribute --instance-id $INST_A --source-dest-check
aws ec2 modify-instance-attribute --instance-id $INST_B --source-dest-check
aws ec2 revoke-security-group-ingress --group-id $SG --protocol -1 --cidr 172.16.0.0/16
aws ec2 authorize-security-group-ingress --group-id $SG --protocol udp --port 4789 --source-group $SG
                                                # "from sg-self" works now: outer src IPs ARE ENI IPs
```

On each node — pods (from lab 4), then the tunnel (from lab 5 step C) with real addresses:

```bash
# node A                                                   # node B
mk_pods 172.16.0                                           mk_pods 172.16.1
ip link add vxlan0 type vxlan id 42 dev $IF \              ip link add vxlan0 type vxlan id 42 dev $IF \
   local $NODE_A remote $NODE_B dstport 4789                  local $NODE_B remote $NODE_A dstport 4789
ip addr add 192.168.100.1/24 dev vxlan0                    ip addr add 192.168.100.2/24 dev vxlan0
ip link set vxlan0 up                                      ip link set vxlan0 up
ip route add 172.16.1.0/24 via 192.168.100.2               ip route add 172.16.0.0/24 via 192.168.100.1
ip netns exec c1 ping -c2 172.16.1.2                       # TTL=62, across AZs, no VPC changes
```

### Check

```bash
tcpdump -ni $IF udp port 4789 -c2       # on node B: outer $NODE_A -> $NODE_B, inner 172.16.0.2 -> 172.16.1.2
ip link show $IF | grep mtu             # 9001 — EC2 jumbo frames inside the VPC
ip link show vxlan0 | grep mtu          # 8951 — the kernel subtracted the 50 bytes itself

for i in 1 2; do ip link set veth$i mtu 9001; ip -n c$i link set eth0 mtu 9001; done
ip link set br0 mtu 9001
ip -n c1 link show eth0 | grep mtu      # 9001

ip netns exec c1 ping -c1 -M do -s 8000 172.16.1.2   # 8 KB pings pass — the encapsulation tax is almost invisible
ip netns exec c1 ping -c1 -M do -s 8923 172.16.1.2   # upper border 8951 — pass
ip netns exec c1 ping -c1 -M do -s 8924 172.16.1.2   # From 172.16.0.1: Frag needed (mtu = 8951)
```

### Break it
- `aws ec2 revoke-security-group-ingress --group-id $SG --protocol udp --port 4789 --source-group $SG`
  → nodes still ping each other, pods do not. `tcpdump` on B shows nothing on 4789. This is the
  overlay incident you will actually meet: "cluster networking is down, all nodes are healthy".
- MTU mismatch, the realistic version. Only on node B: `ip link set $IF mtu 1500` (the other node
  sits behind a 1500-byte link: VPC peering, VPN, on-prem). Then from node A:
  `ip netns exec c1 ping -c1 -M do -s 2000 172.16.1.2` — still works, TTL 62. Two things happened
  that are worth seeing:
  1. The 2078-byte VXLAN packet from A was *accepted* by B: on Linux, MTU limits what an
     interface transmits, not what it receives. A "small-MTU receiver" is not what breaks overlays.
  2. B's reply was *fragmented*: `tcpdump -ni $IF udp port 4789` on B shows the reply as
     `truncated-ip - 578 bytes missing!` — the first 1500-byte fragment of a 2078-byte outer packet.
     vxlan defaults to `df unset` on the outer header, so instead of an error you get fragments,
     and A reassembles them. Confirm on A: `tcpdump -ni $IF 'ip[6:2] & 0x1fff != 0'`.
  This is how a real MTU mismatch usually looks at first: nothing fails, throughput quietly drops
  and every large packet costs two. It turns into an outage the moment something on the path drops
  fragments or oversized frames without sending ICMP (a firewall, a VPN, some cloud LBs) — you
  built exactly that in lab 5 with `iptables -A FORWARD -f -j DROP` on `rtr`.
  The fix is on the sender's tunnel, never on the receiver: `ip link set vxlan0 mtu 1450` on both
  nodes makes A refuse the packet at the first hop with an ICMP "frag needed (mtu 1450)" that the
  pod can actually see, so PMTUD works and the outer packet never exceeds 1500. Then
  `ip netns exec c1 ping -c1 -M do -s 2000 172.16.1.2` → `From 172.16.0.1: Frag needed`, and
  `-s 1422` passes with no fragments on the wire. Restore: `ip link set $IF mtu 9001` on B,
  `ip link set vxlan0 mtu 8951` on both, `ip netns exec c1 ip route flush cache`.

### Compare with EKS node

```bash
ip -br link | grep -E 'vxlan|tun|cni0|br0'     # nothing: VPC CNI has no overlay and no bridge
ip route | head; ip rule                        # /32 routes per pod on veth, policy routing per ENI
ip link show $IF | grep mtu                     # 9001, and pods get it too — no encapsulation tax
```

**Note:** "Overlay on AWS: what breaks and why?" — nothing the VPC controls: no
routes, no source/dest check, only UDP 4789 (or 8472 for Cilium/flannel legacy) in the security
group. What breaks is MTU when the path is not uniformly 9001, and throughput per core on
encap-heavy workloads. "Why does the VPC CNI avoid it?" — the VPC already routes instance
traffic; making pods look like instances (ENI secondary IPs) removes the overlay entirely, at the
price of subnet IP consumption and ENI/IP limits per instance type.

```bash
# node side, both nodes
ip link del vxlan0; ip route del 172.16.1.0/24 2>/dev/null; ip route del 172.16.0.0/24 2>/dev/null
for i in 1 2; do ip netns del c$i; done; ip link del br0

bash cleanup.sh
```

---

## Lab 7. Your own CNI plugin in bash

**Goal:** see the runtime↔plugin contract from the plugin's side: what arrives in env and stdin,
what must be returned, who caches the result, and how DEL and CHECK work.

The plugin `./labcni` is lab 2 wrapped in the CNI contract (read it in full, ~100 lines,
everything is familiar). The runtime will be `cnitool` — a tiny wrapper around `libcni`, the same
library containerd uses. Kubernetes is not required.

```
 cnitool (libcni)                                  labcni (bash)
 ─ reads NETCONFPATH/labnet.conf ────────────────► stdin: JSON config
 ─ sets env CNI_COMMAND/NETNS/IFNAME/CONTAINERID ─► env
 ─ execs CNI_PATH/labcni                           does: bridge, veth, IP, routes
 ◄─ stdout: JSON result ──────────────────────────
 ─ caches the result in /var/lib/cni/results/
 ─ on CHECK/DEL puts it on stdin as prevResult ───► plugin compares it with reality
```

### Setup

```bash
go install github.com/containernetworking/cni/cnitool@latest     # ~/go/bin/cnitool
export PATH=$PATH:$HOME/go/bin

mkdir -p /opt/labcni/bin /opt/labcni/net.d                        # NOT /etc/cni/net.d
cp ./labcni /opt/labcni/bin/ && chmod +x /opt/labcni/bin/labcni
cp plugin/labnet.conf /opt/labcni/net.d/
export CNI_PATH=/opt/labcni/bin NETCONFPATH=/opt/labcni/net.d     # cnitool reads these two variables
cat /opt/labcni/net.d/labnet.conf                                 # type=labcni -> the binary's name
```

### Steps

```bash
ip netns add con1; ip netns add con2                     # containerd's role: sandbox = an empty netns

cnitool add labnet /var/run/netns/con1                   # ADD: cnitool prints the result JSON
cnitool add labnet /var/run/netns/con2

cat /var/log/labcni.log                                  # WHAT the plugin received: env + stdin
ip -br addr show cni0; bridge link show                  # what the plugin did on the node
ip -n con1 addr; ip -n con1 route                        # ...and inside the container
ls /var/lib/labcni                                       # IPAM: one file per allocated IP
ip -br link | grep veth
ip netns exec con1 ping -c2 172.16.0.3                   # pod -> pod
```

The result cache:
```bash
ls /var/lib/cni/results/                                 # labnet-cnitool-<id>-eth0
cat /var/lib/cni/results/labnet-* | jq .                 # this is what OUR plugin returned
```

CHECK — "is the pod's network still alive?":
```bash
cnitool check labnet /var/run/netns/con1; echo rc=$?     # 0
tail -30 /var/log/labcni.log                             # stdin now contains prevResult — from the cache
ip -n con1 addr del 172.16.0.2/24 dev eth0               # "something broke the pod's network"
cnitool check labnet /var/run/netns/con1; echo rc=$?     # 1 + JSON with msg. A runtime would recreate the pod
```

DEL — must be idempotent:
```bash
cnitool del labnet /var/run/netns/con1
ls /var/lib/labcni                                       # IP released
ip link | grep veth                                      # the veth pair is gone
cnitool del labnet /var/run/netns/con1; echo rc=$?       # second DEL -> 0, no errors
ip netns del con2; cnitool del labnet /var/run/netns/con2; echo rc=$?   # netns already gone -> still 0
```

### Break it
- In `labnet.conf` change `subnet` to `/30` and do 3 ADDs → the third gets `no free IPs`. This is
  the "no IP available" you get after a broken DEL leaks addresses.
- Comment out `rm -f "$STATE/$IP"` in DEL → run add/del/add a few times and watch `/var/lib/labcni`
  grow. That is how real IPAMs leak.
- Remove `ip link set lo up` → the pod comes up, but `curl localhost` inside it fails. Real
  plugins bring lo up (or a separate `loopback` plugin in the chain does).

```bash
bash cleanup.sh
```


### Optional: the same plugin under a real kubelet (kind)

The only "magic" here is Kubernetes itself; everything it does to the network you have already seen.

```bash
cat > kind.yaml <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  disableDefaultCNI: true          # no kindnet — networking is ours
  podSubnet: 172.16.0.0/16
nodes:
- role: control-plane
- role: worker
EOF
kind create cluster --config kind.yaml
kubectl get nodes -o wide          # NotReady: no CNI. This is what a node without a plugin looks like
kubectl get node -o custom-columns=NAME:.metadata.name,CIDR:.spec.podCIDR,IP:.status.addresses[0].address
                                   # kube-controller-manager assigned a podCIDR to each node

curl -Lo jq-static https://github.com/jqlang/jq/releases/latest/download/jq-linux-amd64
for n in kind-control-plane kind-worker; do
  docker cp ./labcni $n:/opt/cni/bin/labcni
  docker cp jq-static     $n:/usr/bin/jq; docker exec $n chmod +x /usr/bin/jq /opt/cni/bin/labcni
  cidr=$(kubectl get node $n -o jsonpath='{.spec.podCIDR}'); gw=${cidr%.*}.1
  docker exec -i $n sh -c 'cat > /etc/cni/net.d/10-labnet.conf' <<EOF
{ "cniVersion": "0.4.0", "name": "labnet", "type": "labcni",
  "bridge": "cni0", "subnet": "$cidr", "gateway": "$gw" }
EOF
done
kubectl get nodes                  # Ready: containerd found the config in /etc/cni/net.d

# host-gw between nodes (lab 3) + egress (lab 2), on each node:
cp_ip=$(kubectl get node kind-control-plane -o jsonpath='{.status.addresses[0].address}')
wk_ip=$(kubectl get node kind-worker -o jsonpath='{.status.addresses[0].address}')
docker exec kind-control-plane ip route add 172.16.1.0/24 via $wk_ip
docker exec kind-worker         ip route add 172.16.0.0/24 via $cp_ip
for n in kind-control-plane kind-worker; do
  docker exec $n iptables -t nat -A POSTROUTING -s 172.16.0.0/16 ! -o cni0 -j MASQUERADE
done

kubectl run a --image=nginx --overrides='{"spec":{"nodeName":"kind-control-plane"}}'
kubectl run b --image=nginx --overrides='{"spec":{"nodeName":"kind-worker"}}'
kubectl get pods -o wide           # the IPs come from OUR result JSON
docker exec kind-worker cat /var/log/labcni.log | head -40   # what containerd really sent:
                                   # CNI_NETNS=/var/run/netns/cni-..., CNI_CONTAINERID=<sandbox id>, CNI_ARGS with K8S_POD_*
docker exec kind-worker crictl pods                           # sandbox = the pause container whose netns we configured
kubectl exec a -- curl -s $(kubectl get pod b -o jsonpath='{.status.podIP}') | head -3
kubectl delete pod a b             # DEL: watch the log and /var/lib/labcni on the node
```

If something does not come up: `docker exec kind-worker journalctl -u containerd | grep -i cni`
and `/var/log/labcni.log` — they show which command the plugin failed on and what it received.

```bash
kind delete cluster; bash cleanup.sh
```

---

## 8. Map: lab → reality

| You did by hand | In a cluster it is done by |
|---|---|
| `ip netns add` | containerd on `RunPodSandbox` (the pause container holds the netns) |
| veth + IP + default route in the pod | `bridge`/`ptp` plugin, or the aws-node/calico/cilium agent |
| `br0` with an IP | `cni0` (flannel), `docker0`; the AWS VPC CNI has no bridge — /32 routes to veths |
| `alloc_ip()` into a file | `host-local` (files in `/var/lib/cni/networks`), Calico IPAM, VPC ENI secondary IPs |
| `ip route add podCIDR via nodeIP` | flannel host-gw / Calico BGP / `aws-vpc` route tables |
| `--no-source-dest-check` | done by Calico/flannel aws-vpc installers and by aws-node itself |
| VPC route per node | flannel `aws-vpc` backend, Calico no-encap on EC2 (50-route quota) |
| socat tun + UDP | flannel udp (educational) |
| vxlan0 | flannel vxlan, Calico vxlan, Cilium vxlan; Calico IPIP is the same idea, L3-in-L3 |
| SG rule for UDP 4789 | the "allow VXLAN between nodes" line in every EC2 CNI install guide |
| MASQUERADE `! -o br0` | `AWS-SNAT-CHAIN`, `KUBE-POSTROUTING`, Calico `cali-nat-outgoing` |
| FORWARD ACCEPT for podCIDR | `firewall` plugin, `KUBE-FORWARD` |
| `/var/lib/cni/results` | libcni's result cache inside containerd — what CHECK/DEL rely on |
| `labnet.conf` in NETCONFPATH | `/etc/cni/net.d/10-aws.conflist` on your EKS node |


*"What happens to networking when a pod is scheduled onto a node?"* — kubelet asks containerd via
CRI to create a sandbox → containerd creates the netns (pause) → reads the first conflist in
`/etc/cni/net.d`, execs the chain's plugins with `CNI_COMMAND=ADD`, the netns path and JSON on
stdin → the plugin creates a veth, moves one end into the netns, allocates an IP from the node's
podCIDR, attaches to a bridge (or installs a host route), sets the default gateway → returns a
result; containerd caches it and the IP lands in the pod status → cross-node reachability was
prepared earlier by the daemon (routes / BGP / overlay). On deletion: DEL with the cached config
and result.

*"Pod A on node 1 cannot reach pod B on node 2, the nodes see each other. How do you debug?"* —
layer by layer, as in labs 3–6: `ip route get` in the pod and on the node → `ip_forward` → tcpdump
on node 2's NIC (did the packet arrive? encapsulated or not?) → the route back → iptables FORWARD
→ MTU (`ping -M do -s`) → if overlay: is UDP 4789/8472 blocked between subnets → if AWS without
overlay: source/dest check and security-group CIDR rules.

*"Why the pause container?"* — it keeps the netns alive independently of app-container restarts;
CNI is configured once per sandbox, not once per container.
