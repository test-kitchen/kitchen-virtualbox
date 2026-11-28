# Kitchen VirtualBox glossary

## Language

- **Source image**. A VirtualBox appliance in a box archive. The 1.0 plan also includes cloning a registered source VM.
- **Instance**. A Kitchen suite and platform pairing with its own disposable VM and lifecycle state. Multiple instances can use the same **Source image**.
- **Owned resource**. A resource created for one **Instance** and tracked for its cleanup, such as its imported VM or per-instance SSH key. The 1.0 plan also includes blank test disks.
- **Lifecycle**. The Kitchen actions `create`, `converge`, `setup`, `verify` and `destroy`. An instance's saved state lets a later action recover work from a partial run.
- **Verified box**. A catalog archive pinned by name and version, selected for the provider and host architecture, whose size and SHA-256 match the catalog before import.

## Coding and review standards

- Use Test Kitchen's public commands and driver configuration. Keep VirtualBox operations in this driver and preserve existing configuration and defaults when new options are absent.
- Reuse Kitchen's box catalog, cache verification and lease handling. Require explicit action for downloads or updates that change the selected image.
- Track owned resources as they are created so retry or destroy can recover after partial failure. Limit teardown to resources owned by the instance, preserve source images and user-owned resources, and release the instance's cache lease after successful teardown.
- Keep tests in this driver repository. Exercise the normal Kitchen command or configuration entry point and assert observable outcomes. Stub hypervisor and network calls for repeatable failure coverage.
- Require green CI and evidence from a disposable VirtualBox VM before merging changes to VM creation or teardown. Reuse the repo-local Cinc, Puppet and Ansible Apache smoke suites where they prove the affected behaviour.
- Review each PR against repository standards and its ticket. Flag high-risk changes for explicit maintainer review. Enable squash auto-merge for reviewed, green, readily reversible changes when authorised, with required approvals and checks still in force.

See the [Driver 1.0 feature spec](https://github.com/test-kitchen/kitchen-virtualbox/issues/6).
