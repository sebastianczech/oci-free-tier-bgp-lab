# OCI Always Free BGP lab

A hub-and-spoke network lab on Oracle Cloud that stays inside the **Always Free** limits. It uses BGP on VMs (FRR), a Site-to-Site VPN with BGP to a simulated on-prem data centre, a pair of router VMs behind a transparent Network Load Balancer, and a public Load Balancer. It practises the same patterns as an Azure transit VNet with NVAs: UDRs to an internal LB, GatewaySubnet routing, and BGP over VPN. The [Azure mapping](#azure-mapping) and [AWS mapping](#aws-mapping) sections list the equivalents.

Everything is vendor-neutral: Ubuntu 24.04, FRR, Libreswan and iptables. Nothing here needs a licence.

## Topology

![Topology: hub VCN with public LB, router pair behind a private NLB and the app VM; on-prem VCN with the CPE; DRG and two IPSec tunnels with BGP; inbound, outbound and on-prem flows](diagrams/topology.png)

*Editable source: [`topology.excalidraw.svg`](diagrams/topology.excalidraw.svg) (open in Excalidraw).*

**Route tables**

| Where | Destination | Next hop | Why |
|---|---|---|---|
| `lb` subnet | 0.0.0.0/0 | Internet gateway | public LB |
| `nva` subnet | 0.0.0.0/0 | Internet gateway | routers' own traffic and SNAT'd app egress |
| `nva` subnet | 172.16.0.0/16, 192.168.100.0/24 | DRG | routers → on-prem |
| `app` subnet | 0.0.0.0/0, 172.16.0.0/16, 192.168.100.0/24 | NLB private IP 10.0.1.100 | everything leaving the VCN goes through the routers |
| DRG attachment (VCN ingress) | 10.0.2.0/24 | NLB private IP 10.0.1.100 | on-prem → app goes through the routers |
| DRG (auto, BGP) | 172.16.0.0/24, 192.168.100.0/24 | IPSec tunnels | learned from the CPE |

## Packet flows

**On-prem → app** (`ping 10.0.2.10` from the CPE):
1. The CPE has learned 10.0.0.0/16 by BGP from both tunnels, so the packet leaves through `vti1` or `vti2`. The source is 172.16.0.10, because the `SET-SRC` route-map stops Linux from using the 169.254 tunnel address.
2. The OCI VPN headend decrypts the packet and the DRG forwards it to the hub VCN attachment.
3. The attachment's **ingress route table** sends 10.0.2.0/24 to the NLB, not straight to the subnet.
4. The NLB keeps the source and destination unchanged and hashes the flow to one router. Symmetric hashing gives the reply the same hash.
5. The router forwards the packet (`ip_forward`, skip source/destination check on its VNIC) to 10.0.2.10.
6. The reply: the app subnet route 172.16.0.0/16 → NLB sends it to **the same router**, then the `nva` route 172.16.0.0/16 → DRG, then the tunnel, then the CPE.

**App → internet** (`curl ifconfig.me` from the app VM):
1. The app subnet's 0.0.0.0/0 → NLB route sends the packet to a router.
2. The router SNATs the packet to its own private IP (iptables `MASQUERADE` for traffic leaving the hub and on-prem ranges).
3. The `nva` route 0.0.0.0/0 → internet gateway applies, and the IGW maps the router's private IP to the router's public IP. `curl ifconfig.me` therefore returns a **router's** public IP.
4. The reply comes back to that router (the IGW reverses its mapping, then conntrack undoes the SNAT), and the router forwards it to the app.

**Internet → app** (`curl <app_url>`):
1. The public LB (a full proxy) opens a new connection from its own private IP in `lb` to 10.0.2.10:80.
2. The reply goes to the LB inside the VCN, so it never touches the routers and return-path symmetry isn't an issue.

## BGP sessions

| Session | Type | Path | What is exchanged |
|---|---|---|---|
| CPE ↔ DRG, ×2 | eBGP 65010 ↔ 31898 over VTI | inside each IPSec tunnel | The CPE advertises 172.16.0.0/24 and 192.168.100.0/24 (prefix-list `ONPREM`). The DRG advertises 10.0.0.0/16. |
| CPE ↔ router-1, router-2 | eBGP multihop 65010 ↔ 65020 | across the VPN, TCP 179 | The routers advertise their loopbacks 10.255.0.x/32. The CPE advertises the on-prem prefixes. |

![BGP sessions: CPE to DRG over both tunnels, CPE to both routers multihop through the VPN; the routers' loopbacks are not reachable because the DRG never learns them](diagrams/bgp-sessions.png)

*Editable source: [`bgp-sessions.excalidraw.svg`](diagrams/bgp-sessions.excalidraw.svg) (open in Excalidraw).*

The second session holds the **key lesson**, which is the same one as in Azure. BGP between VMs only changes the VMs' own routing tables. The CPE learns 10.255.0.1/32, but a ping to it fails: the packet goes into the tunnel, and the DRG has no route for 10.255.0.0/24 because nothing advertised it to OCI. OCI has no equivalent of Azure Route Server or AWS VPC Route Server, so a VM can't program the VCN or DRG with BGP. Only the DRG's own sessions over IPSec or FastConnect do that.

## Always Free usage

| Resource | Used | Always Free limit |
|---|---|---|
| Ampere A1 | router-1, router-2: 1 OCPU + 6 GB each | 2 OCPU, 12 GB in total |
| E2.1.Micro | cpe, app | 2 |
| Boot volumes | 4 × 50 GB | 200 GB |
| VCNs | hub, onprem | 2 (Free Tier accounts) |
| Flexible Load Balancer | 1, 10 Mbps | 1 |
| Network Load Balancer | 1 | 1 |
| Site-to-Site VPN | 1 connection, 2 IPSec tunnels | 50 IPSec connections |
| DRG | 1 | Oracle lists no charge for DRG |
| Public IPs | 3 ephemeral (cpe, routers) | ephemeral IPs on Always Free VMs |
| Flow logs | `nva` subnet | 10 GB/month |
| NAT gateway | **not used**: the app goes out through the routers instead | n/a |

Sources: [Always Free Resources](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm) · [Dynamic Routing Gateway](https://www.oracle.com/cloud/networking/dynamic-routing-gateway/) · [VCN pricing](https://www.oracle.com/cloud/networking/virtual-cloud-network/pricing/)

> ⚠️ **Check after the first apply.** On a Pay-As-You-Go account, anything over the limits above is billed. Look at *Billing → Cost Analysis* the next day, and set a budget alert (for example $1) beforehand. Oracle can reclaim Always Free VMs that stay idle for 7 days, so destroy the lab between sessions.

## Deploy

Prerequisites: an OCI account (home region = `region`), `~/.oci/config` with an API key, Terraform ≥ 1.5, and an SSH key pair. Terraform SSHes to the CPE VM to push the VPN config, so it uses `ssh_private_key_path`.

```bash
cp terraform.tfvars.example terraform.tfvars   # set region, config_file_profile, compartment_id
terraform init
terraform plan -out=lab.tfplan
terraform apply lab.tfplan                     # ~10-15 min, mostly the VPN and cloud-init
terraform output
```

If you get **"Out of host capacity"** for A1, change `a1_ad_index` or retry later. Micro VMs only work in one AD in multi-AD regions. If they fail, try `micro_ad_index` = 1 or 2.

## Test

```bash
# CPE: tunnels and BGP
ssh ubuntu@<cpe>
sudo ipsec trafficstatus                     # both tunnels with traffic counters
sudo vtysh -c "show bgp summary"             # 2 OCI peers + 2 routers Established
sudo vtysh -c "show ip route bgp"            # 10.0.0.0/16 via vti1 and vti2 (ECMP), 10.255.0.x/32
ping -c3 10.0.2.10                           # on-prem → app through DRG, NLB, router
ping -c3 -I 192.168.100.1 10.0.2.10          # from the on-prem "LAN"
ping -c3 10.255.0.1                          # fails: see "BGP sessions" above

# Router: see traffic flowing through
ssh ubuntu@<router-1>
sudo tcpdump -ni any icmp or port 80         # run on both routers, ping from the CPE
sudo vtysh -c "show bgp summary"

# App (private, via router-1)
ssh -J ubuntu@<router-1> ubuntu@10.0.2.10
curl -s ifconfig.me                          # = public IP of router-1 or router-2 (SNAT)
traceroute -n 172.16.0.10

# From your Mac
curl http://<lb-ip>                          # app_url output
```

In the OCI console, *Networking → Site-to-Site VPN → tunnels* shows the IPSec and BGP status. *DRG → DRG route tables → Get all route rules* shows the BGP-learned on-prem routes.

## Exercises

1. **Tunnel preference:** on the CPE, prepend `65010 65010` towards `169.254.20.1` (a route-map `out`), then watch the DRG route tables and `ipsec trafficstatus`.
2. **Router failover:** run `sudo systemctl stop ssh` on router-1 (the NLB health check is TCP 22), keep a ping running from the CPE, and watch the flow move to router-2.
3. **Asymmetry:** set `is_symmetric_hash_enabled = false` on the NLB, use `tcpdump` on both routers, and look for flows whose two directions hit different routers.
4. **Make the loopbacks reachable:** advertising 10.255.0.0/24 from the CPE to OCI doesn't help, because the DRG would send it back down the tunnel. What does? (Hint: VCN route rules → private IP, and only for prefixes inside the VCN. Compare with what Azure Route Server does.)
5. **Flow logs:** *Logging → Log groups → bgp-lab-logs* shows on-prem → app flows accepted on the router VNICs.

## Destroy

```bash
terraform destroy
```

## Azure mapping

| This lab (OCI) | Azure equivalent |
|---|---|
| DRG + Site-to-Site VPN, BGP | VPN Gateway (active-active) + Local Network Gateway, BGP |
| VCN ingress route table on the DRG attachment | UDR on GatewaySubnet |
| Private NLB, preserve source/destination, symmetric hash, ANY/0 | Internal Standard LB, HA ports |
| Route rule → NLB private IP | UDR next hop *Virtual appliance* = ILB frontend IP |
| `skip_source_dest_check` on the router VNIC | IP forwarding on the NIC |
| Security lists | NSGs |
| No equivalent | Azure Route Server (NVA ↔ fabric BGP) |

## AWS mapping

| This lab (OCI) | AWS equivalent |
|---|---|
| DRG + Site-to-Site VPN, BGP | Virtual private gateway or Transit Gateway + Customer gateway + Site-to-Site VPN (two tunnels), BGP |
| VCN ingress route table on the DRG attachment | Gateway route table with an edge association to the virtual private gateway (ingress routing) |
| Private NLB, preserve source/destination, symmetric hash, ANY/0 | Gateway Load Balancer (GENEVE, so the appliances must handle encapsulation) |
| Route rule → NLB private IP | Route target = Gateway Load Balancer endpoint |
| `skip_source_dest_check` on the router VNIC | Disable source/destination check on the ENI |
| Security lists (subnet scope, stateful) | Security groups (stateful); network ACLs are subnet scope but stateless |
| Public Load Balancer | Application Load Balancer |
| No equivalent | VPC Route Server (NVA ↔ VPC route table BGP), or Transit Gateway Connect (GRE + BGP to the TGW) |

* [Control traffic entering your VPC using a gateway route table](https://docs.aws.amazon.com/vpc/latest/userguide/associate-route-table-gateway.html): ingress routing on the virtual private gateway, the DRG ingress route table equivalent
* [Announcing the general availability of Amazon VPC Route Server](https://aws.amazon.com/about-aws/whats-new/2025/04/amazon-vpc-route-server): BGP from appliances into VPC route tables, which OCI doesn't have

## Files

- `network.tf`: VCNs, subnets, route tables, security lists, flow logs
- `vpn.tf`: DRG, CPE, IPSec connection, tunnels (BGP, IKEv2), and the SSH push of the CPE config
- `compute.tf`: the 4 VMs
- `load_balancers.tf`: the NLB in front of the routers and the public LB in front of the app
- `templates/`: cloud-init for each VM, plus the Libreswan and FRR config templates for the CPE
- `diagrams/`: Excalidraw diagrams (`.excalidraw.svg` is the editable source, `.png` is embedded here). They are generated by `tools/diagrams/build.py`: `cd tools/diagrams && npm install && npm run build`

## References

* [Always Free Resources](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm): limits for compute, storage and networking
* [Libreswan CPE configuration](https://docs.oracle.com/en-us/iaas/Content/Network/Reference/libreswanCPE.htm): the route-based VTI config this lab is based on
* [Enabling Network Load Balancer Source/Destination Preservation](https://docs.oracle.com/en-us/iaas/Content/NetworkLoadBalancer/NetworkLoadBalancers/preserve-source-id.htm): NLB as a transparent next hop, symmetric hashing
* [VCN Route Tables](https://docs.cloud.oracle.com/Content/Network/Tasks/managingroutetables.htm): private IP as a route target
* [Learn About Deploying Palo Alto firewall in Active/Active mode with OCI Flexible Network Load Balancer](https://docs.oracle.com/en/solutions/oci-nlb-palo-alto-active-active/index.html): the production version of this pattern
* [Is an asymmetric traffic path allowed in OCI?](https://www.ateam-oracle.com/a-routing-scenario-is-an-asymmetric-traffic-path-allowed-in-oci): routing through NVAs
