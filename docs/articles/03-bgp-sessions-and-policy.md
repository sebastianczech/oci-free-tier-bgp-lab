# BGP hands-on: eBGP between on-prem and the cloud

*Part 3 of 5 in the OCI Always Free BGP lab series. Previous: [Site-to-Site VPN with Libreswan](02-site-to-site-vpn-libreswan.md). Next: [DRG routing and the missing Route Server](04-drg-routing-no-route-server.md).*

Every hybrid cloud design uses BGP: VPN gateways, ExpressRoute, Direct Connect, FastConnect, SD-WAN appliances. Most people configure it once from a vendor template and never see what it does. This article uses the lab to look at BGP up close: the sessions, the policy every eBGP session needs, how the AS path prevents loops and steers traffic, and where BGP stops being useful in a cloud.

All exercises are in this article. They run on two VMs with FRR, so nothing here needs a licence.

## Three sessions

![BGP sessions: the cpe peers with the DRG over each tunnel, and with router-1 multihop through the VPN; only the DRG sessions change OCI's route table](../../diagrams/bgp-sessions.png)

| Session | Type | What is exchanged |
|---|---|---|
| cpe ↔ DRG, ×2 | eBGP 65010 ↔ 31898, one per tunnel, peers 169.254.21.1 and 169.254.22.1 | The cpe sends 172.16.0.0/24 and 192.168.100.0/24. The DRG sends the hub VCN's subnets, 10.0.0.0/24 and 10.0.1.0/24 (not the 10.0.0.0/16 VCN CIDR). |
| cpe ↔ router-1 | eBGP multihop 65010 ↔ 65020, TCP 179 through the VPN | router-1 sends its loopback 10.255.0.1/32. The cpe sends the on-prem prefixes. |

Some terms first:

- **AS number (ASN).** Each side of an eBGP session belongs to an autonomous system. The lab uses private ASNs 65010 (on-prem) and 65020 (router-1). The DRG uses Oracle's public ASN 31898.
- **eBGP vs iBGP.** eBGP runs between different ASNs, iBGP within one. Every session here is eBGP.
- **Multihop.** eBGP assumes the peer is directly connected, and FRR checks this before it opens the session. The cpe and router-1 are several hops apart (the VPN, the DRG, the VCN), so both sides set `ebgp-multihop 5` and `update-source` their own IP.
- **Next-hop tracking.** FRR only uses a peer it can reach through a known route. router-1 reaches 172.16.0.10 through its default route, which FRR ignores by default. `ip nht resolve-via-default` tells it to accept that.

## Policy on every eBGP session

![eBGP policy: route-maps FROM-OCI and ONPREM-ONLY between the cpe and the DRG; FROM-ROUTERS, ONPREM-ONLY, TO-CPE and FROM-CPE between the cpe and router-1](../../diagrams/bgp-policy.png)

Both FRR configs start with `frr defaults traditional`. That turns on `bgp ebgp-requires-policy`, from [RFC 8212](https://datatracker.ietf.org/doc/html/rfc8212): an eBGP session without an inbound policy accepts nothing, and one without an outbound policy sends nothing. The session still comes up, which makes this easy to miss. So every eBGP neighbor in the lab has an `in` and an `out` route-map:

| VM | Neighbor | Accepts (`in`) | Sends (`out`) |
|---|---|---|---|
| cpe | DRG 169.254.21.1, .22.1 (peer-group `OCI`) | `FROM-OCI`: 10.0.0.0/16 and longer | `ONPREM-ONLY`: 172.16.0.0/24, 192.168.100.0/24 |
| cpe | router-1 10.0.1.11 (peer-group `ROUTERS`) | `FROM-ROUTERS`: 10.255.0.1/32 | `ONPREM-ONLY` |
| router-1 | cpe 172.16.0.10 | `FROM-CPE`: 172.16.0.0/16, 192.168.100.0/24 and longer | `TO-CPE`: 10.255.0.1/32 |

The cpe's side, from `templates/cpe-frr.conf.tftpl`:

```
ip prefix-list ONPREM seq 10 permit 172.16.0.0/24
ip prefix-list ONPREM seq 20 permit 192.168.100.0/24
ip prefix-list HUB permit 10.0.0.0/16 le 32
!
route-map ONPREM-ONLY permit 10
 match ip address prefix-list ONPREM
route-map FROM-OCI permit 10
 match ip address prefix-list HUB
!
router bgp 65010
 neighbor OCI peer-group
 neighbor OCI remote-as 31898
 neighbor 169.254.21.1 peer-group OCI
 neighbor 169.254.22.1 peer-group OCI
 address-family ipv4 unicast
  network 172.16.0.0/24
  network 192.168.100.0/24
  maximum-paths 2
  neighbor OCI route-map FROM-OCI in
  neighbor OCI route-map ONPREM-ONLY out
```

Two more lines in that file matter:

- **`maximum-paths 2`** lets the cpe install both DRG paths for the same prefix (ECMP), so it sends traffic over both tunnels.
- **`SET-SRC`** (`ip protocol bgp route-map SET-SRC`, with `set src 172.16.0.10`). Without it, Linux would pick the tunnel address 169.254.21.2 as the source for traffic to BGP routes, and OCI has no route back to it.

## How BGP picks a path

When BGP has several paths to the same prefix, it compares them attribute by attribute until one wins. The full list is long. The first steps that matter in this lab are:

1. **Highest local-preference.** Set on routes you receive, it stays inside your AS. It decides which way *your* traffic leaves.
2. **Shortest AS path.** The neighbor sees your AS path, so prepending your own ASN makes a path less attractive *to them*. It decides which way traffic comes *back* to you.

With equal attributes, `maximum-paths` lets FRR use several paths at once.

![AS-path prepending: the cpe advertises 172.16.0.0/24 with AS path 65010 over tunnel 1 and 65010 65010 65010 over tunnel 2, so the DRG sends traffic to on-prem over tunnel 1](../../diagrams/bgp-prepend.png)

## Exercises

Run FRR commands with `sudo vtysh` (or `sudo vtysh -c "<command>"`). The exercises build on each other, but each one ends with a cleanup step, so you can do them in any order. Each one has an **Azure link** and an **AWS link** that names the same decision in those clouds. The expected outputs come from the configs and FRR's documented behaviour; they have not been captured from a live run yet.

### Exercise 1: Sessions and the state machine

On the cpe:

```
show bgp summary
show bgp neighbors 169.254.21.1
show ip route bgp
```

All three neighbors should show a number in `State/PfxRcd`, which means *Established*: 2 prefixes (10.0.0.0/24 and 10.0.1.0/24) from each DRG peer and 1 (10.255.0.1/32) from router-1. In `show bgp neighbors 169.254.21.1`, find the remote AS (31898), the hold time, and `External BGP neighbor may be up to 1 hops away`. For `10.0.1.11` the same line says `up to 5 hops`. `show ip route bgp` shows each hub subnet with two next hops, one per VTI (`maximum-paths 2`).

Break and fix: take one tunnel down and watch its session drop while the hub stays reachable over the other one:

```bash
sudo ipsec auto --down oci-tunnel-1
sudo vtysh -c "show bgp summary"           # 169.254.21.1 Active/Connect, 169.254.22.1 still up
curl -s http://10.0.1.100                  # still works through vti2
sudo ipsec auto --up oci-tunnel-1
```

In the console, *Site-to-Site VPN → Tunnels* shows tunnel 1 *Down* and its BGP status *Down*.

**Azure link:** an active-active VPN Gateway also has two instances and two BGP peers; the on-prem device loses one session, not connectivity.
**AWS link:** every Site-to-Site VPN connection has two tunnels, each with its own BGP session; AWS performs maintenance on one at a time, so both must be up.

### Exercise 2: eBGP requires policy

On router-1, remove the inbound policy:

```
conf t
router bgp 65020
 address-family ipv4 unicast
  no neighbor 172.16.0.10 route-map FROM-CPE in
end
clear bgp 172.16.0.10 soft in
show bgp summary
show bgp neighbors 172.16.0.10
```

The session stays Established, but `PfxRcd` shows `(Policy)` and the neighbor output says `Inbound updates discarded due to missing policy`. `show ip route bgp` is now empty. Put it back with `neighbor 172.16.0.10 route-map FROM-CPE in` and the same soft clear.

Try the same on the cpe with `no neighbor OCI route-map FROM-OCI in`: the cpe loses the hub routes, and `curl http://10.0.1.100` leaves through the internet gateway instead of the tunnels and fails. Put it back with `neighbor OCI route-map FROM-OCI in` and `clear bgp 169.254.21.1 soft in`, `clear bgp 169.254.22.1 soft in`.

**Azure link:** filter what an NVA accepts from Azure Route Server and what it advertises to it. A missing export filter can push a default route to every VNet that ARS feeds.
**AWS link:** VPC Route Server and Transit Gateway Connect peers are ordinary eBGP sessions. Filter both directions on the appliance.

### Exercise 3: AS path and loop prevention

The cpe learns the hub subnets from the DRG over both tunnels. Let it advertise them back to OCI:

```
# cpe
conf t
ip prefix-list ONPREM permit 10.0.0.0/16 le 24
end
clear bgp 169.254.21.1 soft out
clear bgp 169.254.22.1 soft out
show bgp neighbors 169.254.22.1 advertised-routes
```

The cpe now sends 10.0.0.0/24 and 10.0.1.0/24 to the DRG with path `65010 31898`. In the console, *DRG → DRG route tables → Get all route rules* still shows them only through the VCN attachment, never through a tunnel: the path already contains 31898, the DRG's own ASN, so the DRG treats it as a loop and drops it. FRR has a knob for the receiving side (`neighbor … allowas-in`); cloud gateways don't expose it.

**Azure link:** this is why an NVA can't hand Azure Route Server back a route that ARS learned from the VPN/ER gateway: the path already contains 65515, so ARS drops it.
**AWS link:** the same eBGP rule applies to the Amazon-side ASN of a virtual private gateway or Transit Gateway: a path that already contains it is dropped.

Clean up: `no ip prefix-list ONPREM permit 10.0.0.0/16 le 24` on the cpe, then the two soft clears.

### Exercise 4: Tunnel preference with AS-path prepending

Make tunnel 2 the backup for traffic coming *from* OCI:

```
# cpe
conf t
route-map OCI-T2-OUT permit 10
 match ip address prefix-list ONPREM
 set as-path prepend 65010 65010
router bgp 65010
 address-family ipv4 unicast
  neighbor 169.254.22.1 route-map OCI-T2-OUT out
end
clear bgp 169.254.22.1 soft out
```

In the console, *DRG → DRG route tables → Get all route rules* still lists 172.16.0.0/24 and 192.168.100.0/24, now only through tunnel 1. Run `ping 172.16.0.10` on router-1 and watch `sudo ipsec trafficstatus` on the cpe: only tunnel 1's inbound counter grows. The cpe still sends its own traffic over both tunnels (ECMP). Exercise 5 fixes that direction.

**Azure link:** prepending on one link of an active-active VPN or ExpressRoute is how on-prem picks the primary path into Azure.
**AWS link:** AWS also prefers the shorter AS path when choosing between VPN tunnels, so prepending sets the active tunnel.

Keep this config for exercise 5, or clean up: `neighbor 169.254.22.1 route-map ONPREM-ONLY out`, `no route-map OCI-T2-OUT`, then the soft clear.

### Exercise 5: Local-preference for the outbound direction

Prepending changes what the DRG picks. To make the cpe itself prefer tunnel 1, lower the local-preference of everything it learns over tunnel 2:

```
# cpe
conf t
route-map OCI-T2-IN permit 10
 match ip address prefix-list HUB
 set local-preference 50
router bgp 65010
 address-family ipv4 unicast
  neighbor 169.254.22.1 route-map OCI-T2-IN in
end
clear bgp 169.254.22.1 soft in
show bgp ipv4 unicast 10.0.1.0/24
show ip route bgp
```

`show bgp ipv4 unicast 10.0.1.0/24` lists two paths: the one from 169.254.21.1 with the default local-preference 100 is `best`, and the one from 169.254.22.1 shows `localpref 50`. ECMP is gone because the paths are no longer equal, so `show ip route bgp` has one next hop per hub subnet, through `vti1`. With exercise 4 still in place, both directions now use tunnel 1, and tunnel 2 is a real backup. Take tunnel 1 down (as in exercise 1) to watch both directions move to tunnel 2.

The route-map has only one `permit` entry that matches `HUB`, so it filters the same prefixes as `FROM-OCI`. If it didn't match them, they would be dropped.

**Azure link:** on-prem sets local-preference on routes learned from the two Azure VPN or ExpressRoute paths to pick the primary path *to* Azure.
**AWS link:** the same for routes learned from the two tunnels (or Direct Connect vs VPN): the customer gateway decides with local-preference.

Clean up: `neighbor 169.254.22.1 route-map FROM-OCI in`, `no route-map OCI-T2-IN`, then `clear bgp 169.254.22.1 soft in`. Clean up exercise 4 too if you kept it.

### Exercise 6: Protect a session with maximum-prefix

A peer that suddenly sends far more routes than expected (a leak, or a missing filter on its side) can fill your routing table. `maximum-prefix` sets a limit per neighbor. On router-1, which receives 2 prefixes from the cpe, set the limit to 1:

```
# router-1
conf t
router bgp 65020
 address-family ipv4 unicast
  neighbor 172.16.0.10 maximum-prefix 1
end
clear bgp 172.16.0.10
show bgp summary
```

router-1 receives the second prefix, goes over the limit and tears the session down. `show bgp summary` shows the neighbor as `Idle (PfxCt)`, and it stays down until you clear it by hand (or until a `restart` interval, if you configure one). The FRR docs point out that this is destructive: for routes you don't want, a prefix-list is better. Use `maximum-prefix` as the last safety net, often with `warning-only`, which only logs.

Clean up:

```
conf t
router bgp 65020
 address-family ipv4 unicast
  no neighbor 172.16.0.10 maximum-prefix 1
end
clear bgp 172.16.0.10
```

**Azure link:** Azure Route Server and ExpressRoute private peering limit how many prefixes they accept from you, and drop the session when you go over.
**AWS link:** a Site-to-Site VPN BGP session also has a limit on the routes it accepts from the customer gateway; going over it brings the session down.

### Exercise 7: Watch BGP on the wire

On router-1:

```bash
sudo tcpdump -ni any -v tcp port 179
```

In another session run `sudo vtysh -c "clear bgp 172.16.0.10"` and watch the OPEN, KEEPALIVE and UPDATE messages. With `-v`, tcpdump prints the IP TTL: the session crosses the VCN, the DRG, the tunnel and the on-prem VCN, which is why `ebgp-multihop` is needed. On the cpe, `sudo tcpdump -ni vti1 tcp port 179` shows the session with the DRG inside tunnel 1. Those packets never show up on `ens3`, which only carries ESP over UDP 4500 ([part 2](02-site-to-site-vpn-libreswan.md)).

### Exercise 8: The route that goes nowhere

On the cpe:

```bash
sudo vtysh -c "show ip route 10.255.0.1"     # via 10.0.1.11, recursive through vti1/vti2
ping -c3 -I 192.168.100.1 10.255.0.1         # fails
```

The cpe has a valid BGP route to router-1's loopback, but the ping fails. The packet goes into the tunnel, and the DRG has no route for 10.255.0.0/24, because nothing advertised it to OCI. router-1's BGP session only changes routing on the cpe and on router-1. It doesn't change the VCN or the DRG.

This is the main lesson of the lab. In Azure, Azure Route Server would learn 10.255.0.1/32 from router-1 and program it into the VNet and the VPN gateway. AWS has VPC Route Server for the same job. OCI has no equivalent: only the DRG's own BGP sessions, over IPSec or FastConnect, change OCI routing. [Part 4](04-drg-routing-no-route-server.md) makes the ping work with static routes.

**Azure link:** without Azure Route Server, a VNet ignores BGP on an NVA too; the route has to be a UDR.
**AWS link:** without VPC Route Server, a VPC route table only gets the appliance's prefixes as static routes.

## Links

* [RFC 8212: Default External BGP (EBGP) Route Propagation Behavior without Policies](https://datatracker.ietf.org/doc/html/rfc8212): why an eBGP session without policy exchanges nothing
* [BGP — FRR latest documentation](https://docs.frrouting.org/en/latest/bgp.html): `ebgp-multihop`, `ip nht resolve-via-default`, `maximum-prefix`, `allowas-in`, route-maps
* [Site-to-Site VPN Overview](https://docs.oracle.com/en-us/iaas/Content/Network/Tasks/overviewIPsec.htm): tunnels, CPE object, BGP or static routing
* [Dynamic Routing Gateways](https://docs.oracle.com/en-us/iaas/Content/Network/Tasks/managingDRGs.htm): DRG route tables and what the DRG learns over BGP
* [About BGP and VPN Gateway](https://learn.microsoft.com/en-us/azure/vpn-gateway/vpn-gateway-bgp-overview): BGP over S2S VPN, ASN 65515, APIPA peer addresses
* [What is Azure Route Server?](https://learn.microsoft.com/en-us/azure/route-server/overview): BGP between NVAs and the VNet, which OCI doesn't have
* [Tunnel options for your AWS Site-to-Site VPN connection](https://docs.aws.amazon.com/vpn/latest/s2svpn/VPNTunnels.html): two tunnels per connection, inside CIDRs, IKE settings
* [Dynamic routing in your VPC using VPC Route Server](https://docs.aws.amazon.com/vpc/latest/userguide/dynamic-routing-route-server.html): BGP from appliances into VPC route tables, which OCI doesn't have
