# kitchen-virtualbox

Run Test Kitchen against disposable Linux and Windows VirtualBox guests. This
driver uses VirtualBox 7.2's `VBoxManage`, Test Kitchen's box library and
Kitchen's SSH or WinRM transport.

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
also be used directly. The archive should contain one appliance.

For Linux, the driver boots the imported VM headless and forwards its SSH port to a
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

## Windows over WinRM

Use a trusted Windows VirtualBox `.box` with one enabled network adapter,
an enabled WinRM listener and firewall rule, and a test account that can run
PowerShell remoting. The box must boot headless on the host architecture.
For example, use Windows Server 2022 x86-64 on a supported x86-64 host, or
Windows 11 Arm64 on an Apple silicon Mac. See Oracle's
[host and guest combinations](https://docs.oracle.com/en/virtualization/virtualbox/7.2/user/Introduction.html).

Set `transport.name: winrm` and supply the image's credentials through
Kitchen configuration. The driver uses NAT on the first adapter and replaces
its imported port forwards with a WinRM forward bound to `127.0.0.1`. Kitchen
chooses the guest port from the transport configuration (5985 for the default
HTTP listener, 5986 for SSL, or `transport.port` for a custom listener).
The image supplies authentication and listener settings.

The Windows smoke suite writes and checks a marker file over WinRM. Set these
environment variables and run it from the driver checkout.

- `KITCHEN_VIRTUALBOX_WINDOWS_BOX` is the absolute path to the Windows box.
- `KITCHEN_WINRM_USERNAME` and `KITCHEN_WINRM_PASSWORD` are the image credentials.
- `KITCHEN_WINRM_TRANSPORT` optionally selects `ssl`. Use a certificate trusted
  by Ruby on the host and valid for the loopback IP address `127.0.0.1`.
- `KITCHEN_WINRM_PORT` optionally supplies a non-default guest listener port.
- `VBOXMANAGE` optionally selects the VirtualBox executable.

```sh
bundle install
cd examples/windows
bundle exec kitchen test --destroy always
```

To check recovery, first run `bundle exec kitchen create` with an incorrect
test credential. Restore the correct credential and rerun `kitchen create`
to reconnect to the same VM. Then run `kitchen converge`, `kitchen verify`
and `kitchen destroy` through Bundler. You can also run `kitchen destroy`
immediately after a failed create to remove the VM. If the listener port or
transport itself changes, destroy the VM before recreating it.

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
