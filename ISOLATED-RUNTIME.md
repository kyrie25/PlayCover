# Isolated runtime integration

This adaptation embeds [iOSAppRunner's `feat/launcher` runtime](https://github.com/ohaiibuzzle/iOSAppRunner/tree/feat/launcher)
inside PlayCover, allowing games to run in a separate Mac Catalyst process while
retaining PlayTools graphics, device, keymapping, and input compatibility features.
It was motivated by [Blue Archive compatibility issue #1231](https://github.com/PlayCover/PlayCover/issues/1231).

The integration is based on PlayCover `develop` commit
`24bbed786fe1d5acfb0ffc2e619e126bdc09f22b`. The iOSAppRunner submodule is pinned to
`6931452d1880653dc706236fefba054e7e008a78`, including its nested litehook dependency.
The existing PlayTools dependency remains `v4.0.0-prerelease`; this adaptation does
not patch PlayTools or the upstream runtime checkout.

## Usage

1. Install a decrypted game through PlayCover with PlayTools injection enabled.
2. Open the game's **Settings → Bypasses** and enable **Use isolated runtime**.
3. Launch the game from PlayCover.

The option is available for every game and defaults to off, including when reading
settings saved before this feature existed. Compatibility remains game-dependent.
Enabling it disables PlayChain and PlayChain debugging because the runtime supplies
a native per-game keychain. The normal Finder alias is removed so it cannot bypass
the runtime; disabling the option recreates the alias.

The isolated runtime uses separate game data. Existing PlayCover data and PlayChain
accounts are not migrated. Disabling the option returns to the normal launch path
and its existing data. PlayCover's **Clear PlayChain** and **Clear App Data** commands
still address normal PlayCover storage, not isolated-runtime storage.

## How launching works

`PlayApp.launch()` synchronizes settings and installs the current PlayTools plugin
before choosing the isolated path. Games with the option disabled retain the
existing launch path. A `defer` resets the launch-in-progress state after both
normal and isolated launches, including early returns and errors.

For an isolated launch, `IsolatedRuntime.launch()`:

1. Validates the game bundle identifier, checks PlayTools injection, and rejects
   PlayChain-enabled configurations.
2. Reads the embedded runtime's bundle identifier and executable dynamically,
   rather than assuming a particular provisioning team or runtime container name.
3. Allocates or reuses the game's native keychain slot, then checks the upstream
   per-game `.guest.lock` to avoid replacing a running game's prepared bundle.
4. Copies the installed game into a temporary `<UUID>.noindex` staging directory
   inside the runtime container. Preparation runs outside the UI thread.
5. Converts the copied executable into a loadable library with the upstream
   `Host/Dylibifier.m`, restores executable permissions, and adds the integration's
   feature settings and game icon.
6. Seals the prepared bundle with a local ad-hoc signature after modifying it, then
   removes `com.apple.quarantine` only from this generated copy, matching existing
   PlayCover IPA-installation behavior. Global macOS security settings are unchanged.
7. Replaces the prepared game copy, marks the runtime's apps directory as excluded
   from Spotlight indexing, and releases the preparation lock. The runtime acquires
   its own guest lock for the process lifetime.
8. Starts the embedded Catalyst executable with `--launch-app <bundle-id>.app` and
   `--keychain-slot <slot>`. Inherited `DYLD_*`, `MTL_*`, and `METAL_*` environment
   overrides are filtered out. Output goes to a per-game log and nonzero exits are
   reported through PlayCover's existing error UI.

The original installed game is not replaced by the converted copy. Game data is
stored separately from the prepared bundle, so refreshing the copy on subsequent
launches preserves runtime downloads and saves.

The pinned upstream runtime supplies guest bundle/process identity handling,
loading and dyld compatibility hooks, guest home/group-container handling, and
native keychain hooks. These are upstream runtime behavior, not newly implemented
PlayCover patches. Only the Catalyst runtime is embedded; the standalone launcher
and its iOS-runtime launch mode are not added to PlayCover.

## Preserving PlayTools behavior

The prepared copy contains a generated `RunnerFeatures.plist` with the runner's
`resolution`, `deviceSpoof`, and `scene` hooks disabled. This avoids competing with
PlayTools' corresponding hooks. The runtime receives sandbox exceptions for
PlayCover settings/keymaps and the user-installed PlayTools framework, allowing
PlayTools to continue reading the game's existing configuration.

The same feature file supplies `playCoverWidth`, `playCoverHeight`, and
`playCoverResizable` from the game's synchronized settings. A small runtime-only
overlay observes `UIWindowDidBecomeKeyNotification`:

- For fixed-resolution modes, it sets the Catalyst scene's minimum and maximum
  size to the configured viewport. This prevents the native window from growing
  beyond the fixed guest surface and exposing blank right/bottom margins.
- For PlayCover's Resizable mode (`resolution == 6`), it leaves sizing to PlayTools,
  including the existing optional aspect-ratio setting.
- It updates `NSApplication.applicationIconImage` with the guest game's icon,
  instead of leaving the shared runtime's generic icon in the Dock.

The icon is resolved through PlayCover's existing icon cache/extractor. The host
renders it onto a transparent 1024×1024 canvas with an inset rounded mask and a
subtle shadow, then stores it as `.playcover-icon.tiff` in the prepared bundle.
The overlay uses Objective-C runtime calls for AppKit access from Catalyst.
PlayTools screen and input hooks are not modified.

## Storage and keychain isolation

| Item | Location |
| --- | --- |
| Embedded executable | `PlayCover.app/Contents/Resources/Runtime-Catalyst.app` |
| Prepared game copy | `~/Library/Containers/<runtime-bundle-id>/Data/apps/<game-id>.app` |
| Persistent guest data | `~/Library/Containers/<runtime-bundle-id>/Data/<game-id>` |
| Native-keychain slot registry | `~/Library/Application Support/BaseiOSApp/keychain_slots.plist` |
| Runtime log | `~/Library/Containers/io.playcover.PlayCover/IsolatedRuntime/<game-id>-runtime.log` |

`RuntimeKeychainSlots` shares the standalone runner's registry format and exclusive
lock-file protocol. Existing assignments are retained, including assignments made
by the standalone launcher. New games consume the upstream free list or the next
numbered slot, from 1 through 127. Existing slot 0 assignments are understood but
are not assigned to new games.

The allocator rejects malformed registries, duplicate assignments, invalid slot
values, free-list collisions, and exhaustion. Writes are atomic. Lock acquisition
has a timeout and stale-lock handling. A corrupt registry is not silently reset:
reusing another game's native-keychain slot could expose or overwrite its items.
Do not delete the registry as a game reset; its keychain items would still exist.

## Build integration

The Xcode project compiles the host bridge, slot allocator, and upstream dylibifier
into PlayCover. A **Build Isolated Runtime** phase invokes
[`Scripts/build-isolated-runtime.sh`](Scripts/build-isolated-runtime.sh) to:

1. Copy the pinned runtime into an intermediate build directory, excluding Git
   metadata, without modifying the submodule.
2. Add `PlayCoverRuntime.h` and invoke its initializer immediately after the guest
   main-bundle substitution. An explicit anchor check fails the build if the
   upstream entry point changes and needs review.
3. Generate Catalyst-compatible entitlements, removing `homekit`,
   `increased-memory-limit`, and `inter-app-audio` capabilities. Add home-relative
   read/write access to `/Library/Containers/io.playcover.PlayCover/` and read-only
   access to `/Library/Frameworks/PlayTools.framework/`.
4. Build the arm64 Catalyst runtime in a clean environment, forwarding only basic
   shell/user variables. This prevents the parent Xcode build's package/resource
   settings from leaking into the nested build.
5. Copy the runtime into PlayCover's resources and verify its deep/strict signature.

The existing framework/Sparkle signing phase now uses
`EXPANDED_CODE_SIGN_IDENTITY` so it passes the selected signing identity directly
to `codesign`. No personal identity, team identifier, certificate, provisioning
profile, or development account is committed by this adaptation.

### Building from source

Requires Apple Silicon, Xcode with Mac Catalyst support, Carthage, SwiftLint, and
provisioning for the runtime's native-keychain access groups. Configure signing for
your own team. The host and embedded runtime must be provisioned consistently;
the nested build uses automatic provisioning with `DEVELOPMENT_TEAM`.

```sh
git submodule update --init --recursive
carthage bootstrap --use-xcframeworks
FASTLANE=1 xcodebuild -project PlayCover.xcodeproj -scheme PlayCover \
  -configuration Nightly -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build.noindex/DerivedData \
  -clonedSourcePackagesDirPath build.noindex/SourcePackages \
  DEVELOPMENT_TEAM=YOUR_TEAM CODE_SIGN_IDENTITY=YOUR_DEVELOPMENT_IDENTITY \
  CODE_SIGN_STYLE=Manual PROVISIONING_PROFILE_SPECIFIER='' \
  ENABLE_HARDENED_RUNTIME=YES build
```

Product: `build.noindex/DerivedData/Build/Products/Nightly/PlayCover.app`.
PlayCover expects installation at `/Applications/PlayCover.app` and installs its
bundled PlayTools at startup. `build.noindex/` is ignored by Git and keeps generated
apps out of Spotlight. Signing and distribution requirements still apply to any
build you distribute.

## Changed files

| File | Adaptation |
| --- | --- |
| `.gitmodules`, `Dependencies/iOSAppRunner` | Pin the upstream launcher/runtime as a recursive submodule. |
| `.gitignore` | Ignore `build.noindex/`. |
| `PlayCover.xcodeproj/project.pbxproj` | Compile the bridge/allocator/dylibifier, build/embed the runtime, and use the selected signing identity. |
| `PlayCover/Model/AppSettings.swift` | Persist the default-off `useIsolatedRuntime` flag with backward-compatible decoding. |
| `PlayCover/Model/PlayApp.swift` | Route opt-in launches after normal settings/plugin preparation and reliably clear launch state. |
| `PlayCover/Views/AppSettingsView.swift` | Add the all-games toggle, explain separate storage, coordinate PlayChain and aliases. |
| `PlayCover/Utils/Extensions/PlayAppExtensions.swift` | Skip normal Finder aliases for isolated games. |
| `PlayCover/IsolatedRuntime/IsolatedRuntime.swift` | Prepare and launch guest copies, generate Dock icons, manage logs and launch errors. |
| `PlayCover/IsolatedRuntime/RuntimeKeychainSlots.swift` | Preserve and allocate distinct native-keychain slots safely. |
| `PlayCover/IsolatedRuntime/PlayCoverRuntime.h` | Apply the runtime-only viewport and Dock icon fixes. |
| `Scripts/build-isolated-runtime.sh` | Generate the integration overlay and entitlements, build and embed Catalyst. |
| `Tests/RuntimeKeychainSlotsTests.swift` | Exercise allocation, persistence, invalid data, exhaustion, and concurrency. |
| `README.md`, `ISOLATED-RUNTIME.md` | Link and document this fork's adaptation. |

## Verification and limits

The integrated build was exercised with Blue Archive Global **1.96.474931**. The
tester confirmed that it passed user verification and that the corrected Dock icon
matched the rounded, inset style of a normally launched PlayCover game. Later
launch checks retained downloaded resources, reached the title/resource-download
screen without the earlier Gatekeeper warning, and filled the configured fixed
viewport without blank right/bottom strips.

A successful build, SwiftLint, diff checks, deep/strict signatures, and preservation
of the original installed executable were checked. The slot allocator tests cover
stable/distinct assignments, upstream registry reuse, free-list consumption,
exhaustion, duplicate/colliding slots, corrupt-registry preservation, and 16
concurrent allocations.

```sh
mkdir -p build.noindex/tests
swiftc PlayCover/IsolatedRuntime/RuntimeKeychainSlots.swift \
  Tests/RuntimeKeychainSlotsTests.swift -o build.noindex/tests/runtime-slots
build.noindex/tests/runtime-slots
swiftlint lint PlayCover/IsolatedRuntime Tests/RuntimeKeychainSlotsTests.swift --quiet
bash -n Scripts/build-isolated-runtime.sh
git diff --check
codesign --verify --deep --strict /Applications/PlayCover.app
```

Full gameplay, other games' compatibility, and every resolution/aspect-ratio mode
have not been verified. Automated clicks that do not move the physical cursor are
not a reliable input test: PlayTools' mouse-to-touch handling reads the physical
cursor position. Test game interactions with a physical mouse.

Only source, documentation, and tests are included. Game binaries, game data,
account material, local logs, built apps, and provisioning assets are excluded.
The upstream projects retain their attribution and licenses.
