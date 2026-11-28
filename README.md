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

To prepare a private smoke box on an Apple silicon Mac, install Windows 11 Pro
from the [Microsoft Arm64 ISO](https://www.microsoft.com/en-us/software-download/windows11arm64)
in a Windows 11 Arm VM with one NAT adapter. Use a dedicated local
administrator with a unique password. From elevated Windows PowerShell,
enable the WinRM listener with `Enable-PSRemoting -Force -SkipNetworkProfileCheck`.
Keep the source on NAT without port forwards. Use the example's default
`negotiate` transport and leave WinRM Basic authentication and unencrypted
messages disabled. Detach the ISO and shut Windows down before exporting.

Export into a new private directory and archive the OVF and its accompanying
files. Keep the resulting box local because its disk contains the test account.

```sh
VBoxManage export W11-ARM-SMOKE --output box.ovf
printf '%s\n' '{"provider":"virtualbox"}' > metadata.json
tar -czf windows-arm64.box -- metadata.json box.ovf *.vmdk
```

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
  Keep `transport.no_ssl_peer_verification: false` explicit in your Kitchen
  configuration to verify the server certificate.
- `KITCHEN_WINRM_PORT` optionally supplies a non-default guest listener port.
- `VBOXMANAGE` optionally selects the VirtualBox executable.

```sh
bundle install
cd examples/windows
bundle exec kitchen test --destroy always
```

To check recovery, export a disposable copy of the smoke box with the WinRM
service disabled (`Set-Service WinRM -StartupType Disabled` in elevated
PowerShell). Run `bundle exec kitchen create` with the normal credentials and
wait for readiness to fail. Open the imported clone in the VirtualBox console
and run the following in elevated PowerShell.

```powershell
Set-Service WinRM -StartupType Manual
Start-Service WinRM
winrm enumerate winrm/config/listener
```

Check that the expected listener is present, then rerun
`bundle exec kitchen create` to reconnect to the same VM. Run
`bundle exec kitchen converge`, `bundle exec kitchen verify` and
`bundle exec kitchen destroy`. To test cleanup after a listener outage, run
`bundle exec kitchen destroy` immediately after the failed create. Destroy
the VM before changing the configured transport or guest listener port.

## Networking

By default, Kitchen uses a random loopback TCP port to reach the guest over SSH.
Private networks require the SSH transport.
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

## Shared folders

Use `driver.synced_folders` to mount host directories in a Linux
guest. Each entry gives the host directory and the absolute guest mount path.
Relative host paths resolve from the Kitchen project directory. Shares are
writable by default. Set `readonly: true` on any share that should allow only reads.
Set `create: true` to create a missing host directory and `disabled: true` to
skip a share. Use `%{instance_name}` in a host path for per-instance directories.
Use a dedicated directory for writable shares to keep Kitchen's state outside
the guest's write access.

```yaml
driver:
  name: virtualbox
  synced_folders:
    - ["./fixtures", "/mnt/fixtures", { readonly: true }]
    - ["./results", "/mnt/results"]
```

Install VirtualBox Guest Additions with automount support in the guest. Use
root or the permissions provided by the guest's `vboxsf` group to access
the mounts. Run `kitchen destroy` and `kitchen create` to apply share changes
to an existing instance. Destroy removes the VM and preserves the shared
host directories and their contents.

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
Restore refuses a snapshot that would reintroduce or change a shared folder
using a Kitchen-generated name. Older snapshots can contain mappings that
Kitchen no longer records as owned.

The restore command leaves the VM off and invalidates Kitchen's saved SSH
endpoint. Run `kitchen create INSTANCE` to refresh the forwarding rule and SSH
credentials and reapply the configured shared folders before using
`kitchen exec` or `kitchen login`. If restore is interrupted, retry it while the
guest is powered off, or run `kitchen create` to reconnect to the guest in its
current state. Avoid concurrent lifecycle commands for the same instance. `kitchen destroy` removes the managed VM and
its snapshots.

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
