# kitchen-virtualbox

Run Test Kitchen against disposable Linux VirtualBox guests. This driver uses
VirtualBox 7.2's `VBoxManage`, Test Kitchen's shared box library and
Kitchen's SSH transport.

```yaml
driver:
  name: virtualbox
  box_manifest: /Volumes/nfs/bentox_boxes/manifest.json

platforms:
  - name: ubuntu-24.04
    driver:
      box:
        name: bento/ubuntu-24.04
        version: "202510.26.0"
```

Kitchen selects the VirtualBox archive for the host architecture and verifies
its size and SHA-256 before importing `box.ovf`. A trusted local `.box` path can
also be used directly. The archive should contain one Linux appliance.

The driver boots the imported VM headless and forwards its SSH port to a
loopback port. Bento bootstrap uses the guest's `vagrant` account and
VirtualBox Guest Additions to install a per-instance key. With an image that
already has credentials, configure `transport.ssh_key` or
`transport.password`. Set `insert_key: false` to leave key setup to the image.
The `vboxmanage` driver option can point to a binary outside `PATH`.

Set `driver.cpus` to the number of virtual processors and `driver.memory` to
guest RAM in MB when importing a new VM. Both settings accept positive
integers within VirtualBox 7.2's limits (1–64 CPUs and 4–2,097,152 MB).
Omit either setting to retain the corresponding value from the image.
Run `kitchen destroy` followed by
`kitchen create` to change the hardware of an existing Kitchen VM.

After adding a provisioner and suite, run `bundle exec kitchen test` from the
Kitchen project. This driver requires Test Kitchen 4.2 or newer for the
shared box catalog and cache API.
Set `TEST_KITCHEN_PATH` to use another compatible local checkout.

Kitchen stores verified catalog-backed boxes in its local cache. Use
`kitchen box prune --dry-run` to see unused archives and their size. Run
`kitchen destroy` to release a VM's cache lease.

## Download a pinned remote box

Use a local catalog with an HTTPS `url` in place of `file`. Record the
archive's exact byte count and SHA-256 from a trusted source. Keep separate
entries for each version, provider and architecture you offer. For example,
the following catalog structure uses illustrative values for the URL, size
and digest.

```json
[
  {
    "name": "bento/ubuntu-24.04",
    "version": "202510.26.0",
    "provider": "virtualbox",
    "architecture": "arm64",
    "url": "https://boxes.example.org/ubuntu-24.04-202510.26.0-virtualbox-arm64.box",
    "bytes": 123456789,
    "sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  }
]
```

Point `driver.box_manifest` at the catalog and set `driver.box` to
`{ name: bento/ubuntu-24.04, version: "202510.26.0" }`. On create, Kitchen
streams the matching archive into its cache and checks its size and SHA-256
before VirtualBox imports it. Later creates reuse the verified cache entry.

To update, add the new version and its integrity values to the catalog, run
`kitchen destroy`, change the pinned version in `driver.box`, then run
`kitchen create`. Remote entries require a Test Kitchen release with URL
catalog support. During development, set `TEST_KITCHEN_PATH` to a checkout
with that support. Use `kitchen box doctor --checksum` to download and verify
remote entries. Filter by name, version, provider and architecture to check
a specific archive.

## Networking

By default, Kitchen uses a random loopback TCP port to reach the guest over SSH.
To expose another guest TCP service on the host and connect guests on a private
VirtualBox internal network, configure either or both options:

```yaml
driver:
  name: virtualbox
  port_forward:
    host_port: 18080
    guest_port: 8080
  private_network: project-test
  private_address: 192.0.2.31/24
```

- `port_forward` binds one additional TCP port on `127.0.0.1`. Use a free host
  port for each VM that forwards a service. The service must listen on the
  guest's NAT interface.
- `private_network` attaches a second adapter to a VirtualBox internal
  network. Other VMs attached to the same named network can communicate. Pick
  a project-specific name and give each guest a distinct address on a subnet
  separate from the guest's NAT subnet.
- `private_address` requires `private_network` and assigns an IPv4 CIDR address
  to that adapter. Kitchen applies it over SSH after boot. It requires a Linux
  guest with `ip` and either root SSH access or passwordless `sudo` for `ip`.
  The address is runtime-only. After an independent guest reboot, rerun
  `kitchen create` to restore it. With the address omitted, the guest must
  already configure its private adapter.

SSH continues to use the first adapter and its loopback NAT forward.
By default, secondary adapters retain their imported settings. With
`private_network` configured, Kitchen replaces adapter 2's attachment and
disables adapters 3–8 so inherited connections cannot bypass the private network.
To change private networking for an existing VM or change forwarding while it
is running, run `kitchen destroy` followed by `kitchen create`. Bridged
networking, host-only adapters, IPv6 configuration and UDP forwarding are
unsupported.

## Status and diagnostics

Run `kitchen list --live` to see the state reported by VirtualBox for each
managed VM. Add `--probe` to check transport connectivity as well.
Run `kitchen doctor` to check host access and the configured VM source before
creating an instance. These checks read the provider and local configuration
without starting or modifying VMs.

## Apache smoke tests

Mount the NAS or set `KITCHEN_BOX_MANIFEST` to a manifest containing the
pinned Bento Ubuntu 24.04 box for your platform. Alternatively, set
`KITCHEN_VIRTUALBOX_UBUNTU_BOX` to a local box archive. Install Cinc Workstation
with `cinc-cli` on `PATH` for the Cinc suite.

Run these commands from the driver checkout:

```sh
bundle install
bundle exec ruby examples/apache2/run.rb test cinc --destroy always
bundle exec ruby examples/apache2/run.rb test puppet --destroy always
bundle exec ruby examples/apache2/run.rb test ansible --destroy always
```

Each suite creates its own VM, provisions Apache, verifies the service is
enabled and returns HTTP 200, and destroys the VM. Cinc and Ansible also
check that a second apply makes no changes. Puppet and Ansible install their
runtimes from the Ubuntu package repositories before applying the examples.

Set `VBOXMANAGE` if the VirtualBox CLI is outside `PATH`.
