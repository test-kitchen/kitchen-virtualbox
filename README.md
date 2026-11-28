# kitchen-virtualbox

Run Test Kitchen against disposable Linux VirtualBox guests. This driver uses
VirtualBox 7.2's `VBoxManage`, the box library in this Test Kitchen checkout and
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

After adding a provisioner and suite, run `bundle exec kitchen test` from the
Kitchen project. This driver requires Test Kitchen 4.2 or newer for the
shared box catalog and cache API.
Set `TEST_KITCHEN_PATH` to use another compatible local checkout.

Catalog-backed boxes are copied to the local Kitchen cache. Use
`kitchen box prune --dry-run` to see unused archives and their size. Run
`kitchen destroy` to release a VM's cache lease.

## Packaging an instance

Create a fresh instance with `driver.insert_key: false` and supply your own
SSH credentials. Shut down the guest completely, then run
`kitchen package INSTANCE` to create `INSTANCE.box` in the Kitchen root.
The source VM stays registered and an existing output file is preserved.
Set `driver.box` to the new archive to create another instance.

Packaging requires a fresh import with a recorded history of no Kitchen SSH
key injection. Instances created by older driver versions must be recreated.
The archive includes guest disk contents, including any credentials or data
that you placed in the guest or inherited from the input box. The driver
imports new VM disks as VDI. Packaging requires standalone VDI disks attached
only to the source VM and a VM without connected optical media or shared
folders.

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
