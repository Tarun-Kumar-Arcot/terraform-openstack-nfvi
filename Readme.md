# terraform-openstack-nfvi

Terraform configuration for provisioning multi-tenant logical network segments on an OpenStack NFVI fabric using the Neutron Networking API. Designed for VIM (Virtualized Infrastructure Manager) environments following ETSI NFV architecture patterns.

Includes a full local development setup guide using LXD + DevStack on Fedora Linux.

---

## What This Provisions

Two isolated tenant network segments with explicit VNI assignments:

| Tenant | Segment ID | VRF | CIDR |
|---|---|---|---|
| tenant-enterprise-alpha | 10100 | VRF_ALPHA | 10.100.10.0/24 |
| tenant-enterprise-beta | 10200 | VRF_BETA | 10.200.10.0/24 |

Each tenant gets a dedicated Neutron network (Geneve encapsulation, OVN-backed) and a subnet with DHCP disabled — appropriate for NFVI data plane segments managed externally.

---

## Repository Structure

```
terraform-openstack/
├── main.tf        # Provider, variables, network/subnet resources, outputs
├── README.md
└── .gitignore
```

---

## Prerequisites

### System Requirements (Local Dev)
- Fedora Linux (tested on Fedora 42)
- At least 8 GB RAM available
- At least 30 GB free disk space
- KVM support: `ls /dev/kvm` must return the device
- LXD installed via snap

### Tools Required
- Terraform >= 1.5.0
- LXD >= 5.x (snap)
- OpenStack CLI (installed inside DevStack VM)

---

## Part 1 — Local OpenStack Setup (LXD + DevStack)

### 1.1 Install and Configure LXD

```bash
# Add yourself to the lxd group (no sudo for lxd commands)
sudo usermod -aG lxd $USER
newgrp lxd

# Start the LXD snap service
sudo snap start lxd

# Verify LXD is accessible
lxc list
```

### 1.2 Check Existing LXD Config

```bash
lxc storage list
lxc network list
lxc profile show default
```

If `lxdbr0` bridge and `default` storage pool already exist, skip `lxd init`. Otherwise:

```bash
cat <<EOF | lxd init --preseed
config: {}
networks:
- name: lxdbr0
  type: bridge
  config:
    ipv4.address: 10.147.165.1/24
    ipv4.nat: "true"
    ipv6.address: none
storage_pools:
- name: default
  driver: dir
profiles:
- name: default
  devices:
    eth0:
      name: eth0
      network: lxdbr0
      type: nic
    root:
      path: /
      pool: default
      type: disk
EOF
```

### 1.3 Create Ubuntu 24.04 VM

DevStack master (2026.x) requires Ubuntu 24.04 (noble). Ubuntu 22.04 is no longer in the supported distro list.

```bash
# Verify KVM is available
ls /dev/kvm

# Launch VM
lxc launch ubuntu:24.04 devstack-vm --vm \
  --config limits.cpu=4 \
  --config limits.memory=8GiB

# Set disk size (thin-provisioned — won't consume 28 GiB immediately)
lxc config device override devstack-vm root size=28GiB

# Wait for boot
sleep 30 && lxc list devstack-vm
```

### 1.4 Assign Static IP to VM

The LXD bridge IP range is `10.147.165.0/24`. Assign a static IP inside the VM:

```bash
lxc exec devstack-vm -- bash -c "cat > /etc/netplan/99-static.yaml << 'EOF'
network:
  version: 2
  ethernets:
    enp5s0:
      dhcp4: false
      addresses:
        - 10.147.165.100/24
      routes:
        - to: default
          via: 10.147.165.1
      nameservers:
        addresses: [8.8.8.8, 1.1.1.1]
EOF"

lxc exec devstack-vm -- chmod 600 /etc/netplan/99-static.yaml
lxc exec devstack-vm -- netplan apply

# Verify
lxc list devstack-vm
# IPV4 column should show 10.147.165.100
```

### 1.5 Set Up DevStack Inside the VM

```bash
# Enter VM
lxc exec devstack-vm -- bash

# Create stack user (DevStack must not run as root)
useradd -s /bin/bash -d /opt/stack -m stack
echo "stack ALL=(ALL) NOPASSWD: ALL" | tee /etc/sudoers.d/stack
chmod 440 /etc/sudoers.d/stack

# Install git
apt-get update -q && apt-get install -y git

# Switch to stack user
su - stack
```

### 1.6 Clone DevStack and Write local.conf

```bash
git clone https://opendev.org/openstack/devstack /opt/stack/devstack
cd /opt/stack/devstack

cat > local.conf << 'EOF'
[[local|localrc]]
ADMIN_PASSWORD=admin123
DATABASE_PASSWORD=admin123
RABBIT_PASSWORD=admin123
SERVICE_PASSWORD=admin123

HOST_IP=10.147.165.100

# Disable unused services to reduce RAM and install time
disable_service tempest
disable_service s-proxy s-object s-container s-account
disable_service cinder c-sch c-api c-vol
disable_service horizon

# Disable legacy ML2/OVS agents — OVN replaces all of these
# q-agt conflicts with OVN and will cause stack.sh to fail
disable_service q-agt q-dhcp q-l3 q-meta

# OVN-based Neutron (DevStack master default)
enable_service neutron q-svc

NEUTRON_CREATE_INITIAL_NETWORKS=False

[[post-config|/etc/neutron/plugins/ml2/ml2_conf.ini]]
[ml2]
type_drivers = flat,vlan,geneve,vxlan
tenant_network_types = geneve
mechanism_drivers = ovn

[ml2_type_geneve]
vni_ranges = 10000:20000

[ml2_type_vxlan]
vni_ranges = 10000:20000
EOF

./stack.sh
```

Install takes 20–40 minutes. Successful completion shows:

```
Keystone is serving at http://10.147.165.100/identity/
2026-XX-XX XX:XX:XX | stack.sh completed in XXX seconds.
```

---

## Part 2 — Terraform Setup

### 2.1 Install Terraform on Fedora

```bash
sudo dnf config-manager addrepo \
  --from-repofile=https://rpm.releases.hashicorp.com/fedora/hashicorp.repo
sudo dnf install terraform -y
terraform version
```

### 2.2 Verify Connectivity to OpenStack API

```bash
ping -c 3 10.147.165.100
curl -s http://10.147.165.100/identity/v3 | python3 -m json.tool | head -10
```

The curl should return a JSON `version` block confirming Keystone is reachable from the host.

### 2.3 Provider Configuration

The provider block targets your local DevStack instance:

```hcl
provider "openstack" {
  auth_url    = "http://10.147.165.100/identity/v3"
  region      = "RegionOne"
  user_name   = "admin"
  password    = "admin123"
  tenant_name = "admin"
  domain_name = "Default"
  insecure    = true
}
```

> **Note:** For production environments, credentials must never be hardcoded. Use `OS_*` environment variables or a `clouds.yaml` file instead.

---

## Part 3 — Running Terraform

```bash
cd terraform-openstack/

# Download OpenStack provider (~2.x)
terraform init

# Validate HCL syntax
terraform validate

# Preview what will be created — review before applying
terraform plan

# Save plan to file (best practice for approval gates)
terraform plan -out=tfplan

# Apply saved plan
terraform apply tfplan

# Or apply interactively
terraform apply
```

---

## Part 4 — Verification

### From Terraform

```bash
# List all managed resources
terraform state list

# Full state dump with all attributes
terraform show

# Just the network UUID output
terraform output allocated_vim_segments
```

### From OpenStack CLI

```bash
lxc exec devstack-vm -- bash
source /opt/stack/devstack/openrc admin admin

openstack network list
openstack network show tenant-enterprise-alpha-net
openstack network show tenant-enterprise-beta-net
openstack subnet list
openstack subnet show tenant-enterprise-alpha-subnet
openstack subnet show tenant-enterprise-beta-subnet
```

### Expected State

Both networks should show:

```
| provider:network_type     | geneve  |
| provider:segmentation_id  | 10100   |  (or 10200)
| status                    | ACTIVE  |
```

---

## Part 5 — Teardown

```bash
# Destroy all Terraform-managed resources
terraform destroy

# Stop DevStack (inside VM)
lxc exec devstack-vm -- bash
su - stack
cd /opt/stack/devstack && ./unstack.sh

# Delete the VM entirely
lxc delete devstack-vm --force
```

---

## Architecture Notes

### Why Geneve Instead of VXLAN

The original Terraform file used `network_type = "vxlan"`. DevStack master defaults to OVN as the ML2 mechanism driver. OVN uses Geneve for tenant tunnel encapsulation internally. The legacy ML2/OVS agent (`q-agt`) that supported VXLAN directly conflicts with OVN and was removed in this configuration.

This aligns with Red Hat's product direction: RHOSP 17.1 is the last release supporting ML2/OVS, and RHOSO 18.0 (OpenStack Services on OpenShift) mandates OVN exclusively.

### Segment IDs

VNIs 10100 and 10200 fall within the configured `vni_ranges = 10000:20000`. If you extend this configuration, ensure new segment IDs stay within this range or update the range in `local.conf` and restart neutron-server.

### MTU

Both networks show `mtu = 1442`. Geneve adds a 58-byte header overhead versus standard 1500 MTU — this is correct and expected for tunnelled overlay networks.

---

## Troubleshooting

### DevStack fails with `FORCE=yes` required

Ubuntu 22.04 (jammy) is no longer in DevStack master's supported distro list. Use Ubuntu 24.04 (noble) instead. Recreate the LXD VM with `lxc launch ubuntu:24.04`.

### `q-agt/neutron-agt service must be disabled with OVN`

Our `local.conf` enabled the legacy OVS ML2 agent alongside OVN services (which are DevStack master defaults). Fix: add `disable_service q-agt q-dhcp q-l3 q-meta` to `local.conf` and run `./unstack.sh` before retrying `./stack.sh`.

### VM has no IPv4 address

LXD's DHCP from `lxdbr0` can be unreliable for VMs. Assign a static IP via netplan inside the VM (see Section 1.4). Ubuntu 24.04 uses systemd-networkd, not dhclient — running `dhclient` manually will hang.

### `lxd init` fails with `Pool source cannot be changed`

LXD was already initialised from a previous setup. Check `lxc storage list` and `lxc network list`. If the `default` pool and `lxdbr0` bridge exist and are in `CREATED` state, skip `lxd init` entirely and proceed to VM creation.

### Permission denied on LXD socket

Do not use `sudo` with `lxd`/`lxc` commands. Add your user to the `lxd` group: `sudo usermod -aG lxd $USER && newgrp lxd`.

---

## References

- [DevStack Documentation](https://docs.openstack.org/devstack/latest/)
- [Terraform OpenStack Provider](https://registry.terraform.io/providers/terraform-provider-openstack/openstack/latest)
- [Red Hat OpenStack Services on OpenShift (RHOSO 18.0)](https://docs.redhat.com/en/documentation/red_hat_openstack_services_on_openshift/18.0)
- [OVN Architecture](https://docs.ovn.org/en/latest/topics/architecture.html)
