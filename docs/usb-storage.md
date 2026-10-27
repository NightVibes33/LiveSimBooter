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

## Original Apple iOS 26 simulator download to user-owned USB

The app now has a **separate full-size archive downloader**:
**Settings → USB Runtime Storage → Download original iOS 26 simulator archive**.

- GitHub contains only `runtime-downloads/ios26-23A343-arm64.json`: a pinned
  **Apple CDN HTTPS URL**, 23A343 ARM64 build metadata, exact byte count,
  and SHA-256. The original Apple archive is **not** placed in Git, Releases,
  Actions artifacts, LFS, or any project mirror.
- The byte count was obtained from the Apple CDN's live HTTP Content-Range:
  `7985954816` bytes. GitHub's source-check workflow verifies 206 responses
  and downloads no more than 1 KiB of Apple material. The whole-file checksum
  is pinned but **not verified by that 1 KiB source probe**; the app checks
  the full digest after download.
- `Host/AppleRuntimeDownloader.m` fetches the original **unmodified** archive
  directly from Apple in **8 MiB HTTP Range requests**. Each response must
  match the exact requested Content-Range; an unbounded 200 response is
  rejected. Bytes are written directly to the user-selected security-scoped
  USB folder, without staging an 8GB duplicate in iPhone storage. A
  `.partial` file is kept across restarts for byte-offset resumption.
  On complete download, streaming SHA-256 and byte length must match before
  the archive is atomically renamed to `iOS-26.0-23A343-arm64.aar`.
- 23A343 is Apple's simulator runtime **archive**, in AppleArchive AEA format.
  It is **NOT** a prepared `RuntimeRoot` directory. iOS 26 simulator
  archives contain an encrypted Apple archive/cryptex disk image and
  extracting them is not the same as signing or launching guest Mach-O.
  The app has **not** implemented the decrypt/extract/cryptex-mount/re-sign
  process, and does **not** attempt to run the raw `.aar`.

### Simulator-inside-simulator validation

`.github/workflows/diagnose-nested-simulator.yml` performs independent
checks for the Apple CDN, an iOS simulator host-target build, and an attempted
outer CoreSimulator boot/LiveSimBooter host launch. The existing host originally
linked two symbols available on physical iOS only
(`IOSurfaceRemoteServer` and `proc_signal_with_audittoken`). The outer
simulator target explicitly returns `ENOTSUP` for these services rather
than substituting fake success. A running outer simulator or visible
LiveSimBooter UI does **not** mean the **inner** iOS 26 guest booted. The test
intentionally does not publish a green nested-guest status until evidence
of `launchd_sim`, guest services, and SpringBoard is captured.

## Offline validation evidence (2026-10-27)

GitHub Actions run [40593158533](https://github.com/NightVibes33/LiveSimBooter/actions/runs/40593158533)
provisioned Apple's authentic 26.0/23A343 runtime on an Xcode-27 runner and built the relocated simulator cache with `Tools/setup-ios26-cache.py`. The builder's JSON and a separately computed `--check-cache` report matched:

- **1,353 cached arm64 images**
- **2,052,472,832 bytes** generated (about 2.05 GB)
- **base `0x110000000`**
- **SHA-256 `789d50d01b5081dc31f71f0e97a190bde7e07e11484e6dea1d83c2c7610b6ae4`**
- `Tools/patch-ios26-cache-base.py`, `Tools/patch-ios26-platform.py` and
  `Tools/patch-ios26-launchd-identity.py` also completed successfully against the genuine original files.

This is **unsigned-cache layout verification**, not iPhone acceptance.
The developer-specific CMS signing certificate is not installed in a public
CI runner, and the generated unsigned Apple runtime/cache/executables are
not uploaded to public artifacts. A SideStore-resigned host cannot
automatically confer its entitlement or certificate upon externally
downloaded guest executable files. Missing pieces before one-click boot:
valid CMS guest signing, a prepared and verifiable `RuntimeRoot` installer
for the user-owned USB filesystem, security-scope access by LiveProcess,
kernel signature registration and `PROT_EXEC` mapping of *guest* binaries,
plus actual launchd_sim/SpringBoard boot evidence.

Settings → USB Runtime Storage → **Diagnose USB executable mapping**
now performs a safe host-only on-device check: copy the signed host
Mach-O to a temporary USB file, register its existing signature with
`F_ADDFILESIGS_RETURN`, attempt a non-executing executable-page
mapping, and erase the temporary file. **Even a success in this check
does not prove LiveProcess's separate sandbox and signature validation**.

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
