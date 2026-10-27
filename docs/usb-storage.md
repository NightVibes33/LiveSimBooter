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
1. Choose a **folder** on attached USB drive with Apple's Files document picker.
2. Save a security-scoped bookmark. Reopen the app to resolve it and check real access.
3. **Store prepared simulator on USB**: copy the staged App Group `RuntimeRoot` and optional
   `SimulatorData` to `LiveSimBooter-USB-23A343/`, with staging and no overwrite.
4. **Restore simulator from USB**: copy `RuntimeRoot` back to the App Group, without
   overwriting an existing installation. A previously provisioned app is still required.

An IPA cannot contain or transfer the Apple runtime by itself. Prepare/cache/sign the
`23A343` simulator runtime according to `docs/agent-setup.md` before storing it.
Keep the app foregrounded during transfers and safely eject USB after completion.

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
