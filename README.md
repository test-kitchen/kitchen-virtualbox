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

## Restore a snapshot

Create the instance with `kitchen create` and use its `virtualbox_uuid` from
`.kitchen/INSTANCE.yml` as `VM_UUID` below. Write a marker in the guest, then
shut the guest down cleanly before taking the snapshot.

```sh
bundle exec kitchen exec INSTANCE -c 'echo baseline > ~/snapshot-marker'
```

```sh
VBoxManage snapshot VM_UUID take baseline
VBoxManage snapshot VM_UUID list --machinereadable
VBoxManage startvm VM_UUID --type headless
```

Once SSH is ready, change the marker and shut the guest down cleanly again.

```sh
bundle exec kitchen exec INSTANCE -c 'echo changed > ~/snapshot-marker'
```

Use the listed snapshot UUID as `SNAPSHOT_UUID` to restore the guest disk.

```sh
bundle exec kitchen-virtualbox-restore INSTANCE SNAPSHOT_UUID
bundle exec kitchen create INSTANCE
```

Once SSH is ready, verify that the guest contains the original marker.

```sh
bundle exec kitchen exec INSTANCE -c 'grep -qx baseline ~/snapshot-marker'
```

Run the restore command from the Kitchen project and supply the exact Kitchen
instance name and VirtualBox snapshot UUID. The command checks which VM Kitchen
owns and requires both the VM and the snapshot to be powered off. An unknown
snapshot UUID leaves the VM and Kitchen state untouched. Restore rolls back
guest disks and VM settings, including SSH forwarding, to the chosen snapshot.

The restore command leaves the VM off and invalidates Kitchen's saved SSH
endpoint. Run `kitchen create INSTANCE` to refresh the forwarding rule and SSH
credentials before using `kitchen exec` or `kitchen login`. If restore is
interrupted, retry it while the guest is powered off, or run `kitchen create`
to reconnect to the guest in its current state. Avoid concurrent lifecycle
commands for the same instance. `kitchen destroy` removes the managed VM and
its snapshots.

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
