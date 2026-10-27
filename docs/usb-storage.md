# USB runtime storage — verified boundary and migration plan

## Why this project differs from GTAiOS

The user-maintained `NightVibes33/GTA-V-IOS` branch `ios-usb-port` uses:
- `ios/Sources/Storage/USBStorageManager.swift` — Files folder picker, security-scoped bookmarks,
  held open access, coordinated reads, selection/reconnect checks.
- `ios/Sources/Storage/AssetHTTPServer.swift` — range-serving large external archives
  directly to the engine with no full asset copy.
- `native/USBRangeCache.rs` — bounded 256 KiB archive blocks / 128 MiB RAM / 1024 MiB
  disk cache, checksums and retry logic.

This is an appropriate pattern for **asset reads**. It does not grant executable-mapping
permissions to all processes. The GTAiOS branch documents USB resource loading, while
its native port remains under development. Do not infer full GTA gameplay from those source
checks alone.

## Current support

Settings → USB Runtime Storage:
1. Choose a **USB folder** in Apple's Files picker. iOS signs the current
   host with a recognized App Group; this only confirms storage access, not
   extension provisioning or a bootable runtime.
2. Select **Import prepared simulator from Files** to choose an existing,
   fully prepared `RuntimeRoot` folder, its parent, or the normal USB
   package. The app copies it **straight from the selected Files folder to USB**,
   not through its own App Group. The import requires at minimum nonempty
   `usr/lib/dyld_sim`, `sbin/launchd_sim`,
   `usr/lib/libLiveSimSpawn.dylib`, and the 23A343 signed
   `System/Library/Caches/com.apple.dyld/dyld_sim_shared_cache_arm64`.
   This is a structural check, **not a signature or compatibility validation**.
3. **Store existing iPhone simulator on USB** is a *backup* action. It requires
   a prepared `RuntimeRoot` already installed in the App Group. On fresh
   installs that have only an IPA, the correct error is “No prepared simulator
   is installed in the App Group”; use **Import** instead.
4. **Check USB simulator contents** reports missing prepared files. **Restore
   USB simulator to iPhone** copies it to the App Group before attempting a
   guest boot, never replacing an existing local runtime.

The app cannot prepare or sign Apple's original stock `.simruntime` entirely
on the iPhone just by selecting its folder. First use the repository's pinned
`docs/agent-setup.md` staging, patching, provisioning and signing workflow
with legitimately obtained Apple inputs; then import that prepared output
into USB storage.

**Example of the actual error fixed in this UX:** the host App Group
`group.com.kdt.LiveSimBooter.39A8Q3T3TR` is accessible after SideStore
resigning, but the host has no local `RuntimeRoot`. That proves the signing
problem is no longer the immediate blocker. It does not prove that the
`LiveProcess` extension has the same profile or that the simulator will boot.

An IPA cannot contain or transfer the Apple runtime by itself. Prepare/cache/sign the
`23A343` simulator runtime according to `docs/agent-setup.md` before storing it.
Keep the app foregrounded during transfers and safely eject USB after completion.

## GitHub-hosted compressed helper cache (no Mac needed for these files)

This repository now publishes **only original project-written guest helper tools**
to the ordinary Git branch [`runtime-cache-23A343`](https://github.com/NightVibes33/LiveSimBooter/tree/runtime-cache-23A343)
and exposes its [`manifest.json`](https://raw.githubusercontent.com/NightVibes33/LiveSimBooter/runtime-cache-23A343/manifest.json).
No GitHub Releases are used. Six known helper paths are allowlisted in both
the publisher and downloader; Apple simulator binaries, `dyld_sim`,
`launchd_sim`, and dyld shared caches are **not** included.

The publisher `.github/workflows/publish-helper-cache.yml` builds the
`Guest/` helpers on an Xcode runner, gzip-compresses each independently,
splits gzip streams into <=4 MiB Git objects, verifies SHA-256 of every
part and each decompressed output, then pushes only the generated cache to
a dedicated branch. There is no full Git clone on iPhone.

In the app: **Settings → USB Runtime Storage → Choose USB folder →
Download LiveSimBooter helpers to USB**. `Host/RuntimeCacheInstaller.m`
fetches the HTTPS manifest and validated chunks serially with an ephemeral
URLSession (no persistent device HTTP cache), decompresses each gzip file
with bounded buffers to a USB staging directory, verifies uncompressed size
and SHA-256, deletes consumed compressed chunks, and publishes the complete
`LiveSimBooter-Helpers-23A343/` package without overwriting existing data.
Incomplete files retain their verified chunks for resume; old incomplete
output files are validated before reuse. A missing or unauthorized manifest
fails explicitly. The final cache is **not automatically executed**.

The installed helper package is **not** a prepared simulator runtime; it
does not address the missing 15–20 GB of Apple-proprietary simulator files.
Simply compressing, splitting, or moving Apple's binaries to Git does not
grant distribution rights or executable trust. A legally sourced, signed
guest runtime and separate loader validation remain prerequisites for boot.
Current manifest size is about 106 KB compressed / 505 KB uncompressed.

## Direct USB execution — not yet validated

The host broker currently resolves a real App Group path in `Host/Broker.m`,
then `LiveProcess/main.c` opens and maps `RuntimeRoot/usr/lib/dyld_sim` and the
guest Mach-O executable in an **independent app-extension process**.
`LiveSimBooter/DyldSimLoader.cpp` registers each image's signature with
`F_ADDFILESIGS_RETURN` and maps executable segments using `mmap(PROT_EXEC)`.
A host-owned security-scoped URL is *not* evidence that the extension can traverse the
same URL or that the USB filesystem accepts signed executable mappings.

Direct execution must have actual device validation in this order:
1. Confirm the chosen USB folder is a valid **filesystem** URL and the bookmark restores.
2. Verify the extension receives its **own valid filesystem grant**, not just a host path
   string or a trust assumption.
3. Run a separate-process **signed-Mach-O file-signature-registration and executable-page
   mapping probe** from the selected USB filesystem. Record exact errno and filesystem.
4. Only if 2–3 pass, allow the broker to pass a canonical external RuntimeRoot and
   keep the scope alive for *all* guests and services.
5. Check kernel code-signing enforcement, child process lifecycle, app suspension, USB
   detachment, reconnection, stale bookmark renewal, and resource integrity.
6. If executable pages cannot map, stage the minimal signed executable/cache subset
   locally while serving nonexecutable runtime resources and optional mutable guest data
   externally through coordinated reads. This requires explicit path translation and
   permission-aware file-access routing; simple symlinks do not suffice.

Do not label a successful build, file read or document-picker selection as a successful
USB boot. Do not delete a known-working runtime during testing.

## Space expectations

USB storage can hold the full ~15 GB prepared image and guest data. **Store/restore mode
does not reduce on-device usage while running**: the full local App Group RuntimeRoot
remains required. A streaming asset mode could reduce that after its loader and
multi-process access path are verified. No specific local-space savings are claimed.
