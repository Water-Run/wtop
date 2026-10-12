# wtop 0.2.0

This version expands process inspection, hardware relationships and Linux
service diagnostics. The release targets Linux x86_64 and aarch64 with PUC
Lua 5.5. macOS and Windows remain development builds; XP has not been run on
a real XP machine.

- Process and thread details include configurable columns, file descriptors,
  namespace and NUMA information, and navigation between processes, sockets
  and cgroups.
- The shared hardware tree connects PCI/USB devices, disks, partitions,
  network interfaces, CPU frequency policies, NUMA nodes and sensors. Firmware
  and memory inventories retain explicit sources and missing-data states.
- On-demand Linux inspection covers systemd units, recent journal messages,
  login sessions and sshd configuration and log summaries.
- Layout and workspace editing, graph zoom, Braille charts, structured search,
  continuous JSON snapshots and Markdown hardware reports are available.
- Delivery includes versioned source rocks and complete bin archives containing
  onedir and onefile programs, licences, checksums, SBOM and the measured ELF
  baseline. Downloaded archives pass the same CLI and terminal checks.

For a bin archive, verify its adjacent `.sha256` file, unpack it and run
`wtop/wtop` or `wtop-onefile`. The onefile program extracts its payload at
startup. Both forms use the target system's libc; the archive's
`BASELINE.release.txt` records its requirement.

For a source rock, use LuaRocks 3.13 or newer with Lua 5.5 and matching
development headers, a C17 compiler and make:

```bash
luarocks --lua-version=5.5 install wtop-0.2.0-1.src.rock
```

The release includes signed Sigstore provenance bundles. With GitHub CLI,
verify a downloaded archive or source rock against the repository and release
workflow:

```bash
gh attestation verify <artifact> --repo Water-Run/wtop \
  --signer-workflow Water-Run/wtop/.github/workflows/release.yml
```

GPU vendor coverage, old operating systems and minimum-hardware performance
budgets still need broader real-machine validation. See
[the validation matrix](CROSS_PLATFORM.md) for the scope of existing evidence.
