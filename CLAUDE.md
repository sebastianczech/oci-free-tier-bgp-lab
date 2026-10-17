# CLAUDE.md

This file guides Claude Code when it works in this repository.

## Purpose

This is a personal learning lab: a single Terraform root module that builds a BGP and hub-and-spoke networking lab on Oracle Cloud, using only **Always Free** resources. The README's Azure and AWS mapping tables give the equivalents in those clouds.

## Rules

- **Never run `terraform plan/apply/destroy` or any `oci` CLI command.** They act on the user's tenancy, so only the user runs them. Offline checks are fine: `terraform init -backend=false`, `validate` and `fmt`. To test templates, render them with `templatefile()` in a scratch folder.
- **Stay within the Always Free limits** (see the README table). Before adding a resource, check that it is Always Free or no-charge, with a link to the source. Don't add a second LB, NLB or VCN, a NAT gateway, or VMs beyond the 2 A1 (2 OCPU / 12 GB in total) + 2 E2.1.Micro. Don't let boot volumes exceed 200 GB in total.
- The VMs have fixed private IPs (`local.ip` in `main.tf`), so the BGP and route configs can be written before the VMs exist. If you change an IP, change it everywhere.
- The CPE's IPSec/BGP config can't go into cloud-init (the tunnel IPs only exist after the CPE VM exists). `terraform_data.cpe_config` in `vpn.tf` pushes it over SSH.
- Oracle's Ubuntu images ship iptables REJECT rules. Every cloud-init removes them, and the security lists do the filtering.
- Links use this format: `* [Exact page title](url): what it is useful for`, verified before adding.
- Diagrams use Excalidraw, not Mermaid or ASCII. `tools/diagrams/build.py` holds the layouts and writes `diagrams/<name>.excalidraw.svg` plus a `<name>.png` that the README embeds (`cd tools/diagrams && npm install && npm run build`). Flow colours: green inbound, purple outbound, amber east-west, pink on-prem, dashed grey BGP. Check the PNG visually after each change. Regenerating overwrites hand edits.
