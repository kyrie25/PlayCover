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
3. Launch the game from PlayCover or its named app entry in
   `~/Applications/PlayCover/`, including through Spotlight.

The option is available for every game and defaults to off, including when reading
settings saved before this feature existed. Compatibility remains game-dependent.
Enabling it disables PlayChain and PlayChain debugging because the runtime supplies
a native per-game keychain. The normal Finder alias is replaced by a small app
launcher that returns to PlayCover for preparation, so Finder/Spotlight launches
use the same settings and runtime. Disabling the option restores the normal alias.

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
7. Replaces the prepared game inside `apps.noindex`. On migration, unregisters and
   removes only the old generated copy carrying PlayCover's feature marker. This
   prevents an internal bundle-ID-named copy from appearing in app search.
8. Copies the embedded runtime into a per-game `.noindex` directory, giving the
   copy the game's directory name, `CFBundleName`, `CFBundleDisplayName`, and an
   ICNS resource derived from the rounded icon. The bundle identifier in its
   `Info.plist` is lowercased for Games' case-sensitive artwork lookup. The original
   signed identifier, entitlements, and requirements are preserved to
   retain the runtime's sandbox and native-keychain identity. The copy is signed
   with the embedded runtime's certificate and verified before launch.
   It unregisters the generic embedded template and registers the named copy
   with LaunchServices so Game Mode's bundle-ID lookup resolves the game metadata.
9. Releases the preparation lock and starts the personalized Catalyst executable
   with `--launch-app <bundle-id>.app` and
   `--keychain-slot <slot>`. Inherited `DYLD_*`, `MTL_*`, and `METAL_*` environment
   overrides are filtered out. Output goes to a per-game log and nonzero exits are
   reported through PlayCover's existing error UI.

The runtime acquires its own guest lock for the process lifetime. Its personalized
bundle is refreshed from the embedded version on each launch; the installed
PlayCover bundle is not modified. Updating only the running process's name or Dock
image is insufficient for Dock labels, Force Quit icons, and Game Mode artwork,
which also resolve the application bundle's identity.

Games' artwork lookup can return a placeholder for a mixed-case runtime identifier
even when LaunchServices resolves the same identifier and the icon renders through
the native application's normalized lookup. Lowercasing only the personalized
bundle's metadata fixes that lookup; preserving the code-signing identifier keeps
the original container and keychain access intact.

`GameLauncher.m` is a small native forwarding executable. Its indexed app bundle
has a distinct `io.playcover.launcher.<game-id>` identifier and a proper name/icon.
It opens `playcoverapp://app?action=open&bundleid=<game-id>` specifically with the
host PlayCover app and exits. The URL handler looks up an installed library game
and invokes its normal launch method, including when PlayCover starts cold. It
does not execute the converted guest bundle directly.

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
`playCoverResizable` from the game's synchronized settings, plus the display name
shown in PlayCover's library. A runtime-only overlay observes UIKit key-window
and native window/launch notifications:

- It removes scene size restrictions so the window can be expanded and enter
  full screen. For fixed-resolution modes, it retains the configured guest
  viewport and calculates a uniform scale to fit the native view. Catalyst
  repeatedly restores its compatibility viewport and requires a positive
  explicit scene scale, so the overlay adapts the native scene-size and scale
  setters within the isolated process. It sets the window's content aspect ratio
  and supplies an aspect-fitted full-screen content size through its delegate.
  This preserves the game's proportions and lets macOS center the smaller
  full-screen window when the display has a different aspect ratio.
- For PlayCover's Resizable mode (`resolution == 6`), it leaves scaling and aspect
  ratio to PlayTools, including the existing optional aspect-ratio setting.
- It updates `NSApplication.applicationIconImage` with the guest game's icon,
  instead of leaving the shared runtime's generic icon in the Dock.
- It supplies PlayCover's library display name to LaunchServices before AppKit
  registers its Dock tile, and refreshes it on native window lifecycle events.
  Guest bundle display/name values remain fallbacks.

Native callbacks run on the next main-queue turn because UIKit's key-window
notification precedes native window creation. Only content views exposing the
native scene interface are adjusted; temporary full-screen transition windows
are skipped. Treating those overlays as guest windows previously caused an
unknown-key exception during full-screen entry.

The icon is resolved through PlayCover's existing icon cache/extractor. The host
renders it onto a transparent 1024×1024 canvas with an inset rounded mask and a
subtle shadow, then stores it as `.playcover-icon.tiff` in the prepared bundle.
The overlay uses Objective-C runtime calls for AppKit access from Catalyst.
Native scene scaling and LaunchServices naming use private platform interfaces;
selectors and symbols are checked before use, and future macOS releases may
require adaptation. PlayTools screen and input hooks are not modified.

PlayTools installation now copies the bundled framework into a sibling staging
directory before replacing the user framework. Game launch waits for that task
before plugin preparation. This avoids launching against a partially copied
framework, and an interrupted copy leaves the previous framework available.

When Discord Activity is enabled for an isolated game, the PlayCover host
connects to the running Discord client's local socket. The Catalyst sandbox
cannot connect to that socket directly. The host waits for Discord to acknowledge
the handshake, then publishes the configured activity with the game's PID. The
connection closes when the game exits. Start Discord before launching the game.

## Storage and keychain isolation

| Item | Location |
| --- | --- |
| Embedded executable | `PlayCover.app/Contents/Resources/Runtime-Catalyst.app` |
| Indexed game launcher | `~/Applications/PlayCover/<game-name>.app` |
| Prepared game copy | `~/Library/Containers/<runtime-bundle-id>/Data/apps.noindex/<game-id>.app` |
| Personalized runtime | `~/Library/Containers/io.playcover.PlayCover/IsolatedRuntime/<game-id>.noindex/<game-name>.app` |
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
   upstream entry point changes and needs review. Redirect guest bundle lookup to
   `apps.noindex` in this generated source, with a separate anchor check.
3. Generate Catalyst-compatible entitlements, removing `homekit`,
   `increased-memory-limit`, and `inter-app-audio` capabilities. Add home-relative
   read/write access to `/Library/Containers/io.playcover.PlayCover/` and read-only
   access to `/Library/Frameworks/PlayTools.framework/`.
4. Build the arm64 Catalyst runtime in a clean environment, forwarding only basic
   shell/user variables. This prevents the parent Xcode build's package/resource
   settings from leaking into the nested build.
5. Copy the runtime into PlayCover's resources and verify its deep/strict signature.
6. Compile the native `GameLauncher` forwarding executable into PlayCover's
   resources for generating indexed game entries.

The existing framework/Sparkle signing phase now uses
`EXPANDED_CODE_SIGN_IDENTITY` so it passes the selected signing identity directly
to `codesign`. No personal identity, team identifier, certificate, provisioning
profile, or development account is committed by this adaptation.

### Automatic profile renewal

On each isolated launch, PlayCover checks the embedded Catalyst profile before
preparing the game. A valid profile works offline. Once it expires, PlayCover
checks the shared profile cache and, if necessary, runs a small bundled Xcode
project with automatic provisioning for the runtime's original team and bundle
identifier. Xcode needs a configured development account and may need internet
access. A failed renewal reports the Xcode error and can be retried by launching
again.

PlayCover checks the replacement profile's expiry, team, application identifier,
platform, and signing certificate, then caches it atomically in
`IsolatedRuntime/Provisioning.noindex`. Concurrent launches share a renewal
lock. Each personalized runtime receives the selected profile before signing.
The installed PlayCover bundle stays sealed throughout renewal.

### Building from source

Requires Apple Silicon, Xcode with Mac Catalyst support, Carthage, SwiftLint, and
provisioning for the runtime's native-keychain access groups. Configure signing for
your own team. The host and embedded runtime must be provisioned consistently;
the nested build uses automatic provisioning with `DEVELOPMENT_TEAM`.
The same development certificate's private key must remain available locally for
signing the personalized runtime copies. Forwarding launchers use local ad-hoc
signatures and do not carry the runtime's restricted entitlements.

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
| `PlayCover/Model/PlayApp.swift` | Wait for PlayTools installation, route opt-in launches after settings/plugin preparation, and reliably clear launch state. |
| `PlayCover/Utils/PlayTools.swift` | Stage framework installation before replacement and expose completion to game launch. |
| `PlayCover/Views/AppSettingsView.swift` | Add the all-games toggle, explain separate storage, coordinate PlayChain and launcher/alias replacement. |
| `PlayCover/Utils/Extensions/PlayAppExtensions.swift` | Generate indexed forwarding launchers for isolated games. |
| `PlayCover/Info.plist`, `PlayCover/Utils/URLHandler.swift` | Register the launch URL scheme and route installed-game requests through PlayCover. |
| `PlayCover/IsolatedRuntime/IsolatedRuntime.swift` | Prepare guests and personalized runtimes, generate launcher/icon resources, manage logs and launch errors. |
| `PlayCover/IsolatedRuntime/IsolatedDiscordActivity.swift` | Publish the isolated game's Discord activity through the host's existing socket access. |
| `PlayCover/IsolatedRuntime/GameLauncher.m` | Forward Finder/Spotlight launches to the host without an extra Dock tile. |
| `PlayCover/IsolatedRuntime/RuntimeKeychainSlots.swift` | Preserve and allocate distinct native-keychain slots safely. |
| `PlayCover/IsolatedRuntime/PlayCoverRuntime.h` | Apply runtime-only aspect-preserving scaling, Dock name, and icon fixes. |
| `Scripts/build-isolated-runtime.sh` | Generate the integration overlay and entitlements, build and embed Catalyst. |
| `Tests/RuntimeKeychainSlotsTests.swift` | Exercise allocation, persistence, invalid data, exhaustion, and concurrency. |
| `README.md`, `ISOLATED-RUNTIME.md` | Link and document this fork's adaptation. |

## Verification and limits

With Discord desktop open, the installed PlayCover build launched Blue Archive
through its named launcher and received Discord's activity acknowledgement.
Quitting Blue Archive closed the host's Discord connection.

The integrated build was exercised with Blue Archive Global **1.96.474931**. The
tester confirmed that it passed user verification and that the corrected Dock icon
matched the rounded, inset style of a normally launched PlayCover game. Later
launch checks retained downloaded resources, reached the title/resource-download
screen without the earlier Gatekeeper warning, and filled the configured fixed
viewport without blank right/bottom strips. Follow-up checks reached the title
screen after repairing an incomplete framework installation and entered full
screen with the configured guest aspect ratio and uniform scaling. The tester
confirmed that full-screen exit/re-entry works and that game names/icons are
correct. A subsequent named launcher was indexed as **Blue Archive**, opened
PlayCover and the game from a cold start, and reached the title screen. The old
bundle-ID-named guest copy and its stale registration were removed. The tester
confirmed the indexed app-list/Spotlight entry and the name/icon in Dock and Force
Quit. A follow-up screenshot showed Game Mode still resolving the generic embedded
runtime. Its LaunchServices application-record lookup was reproduced and corrected
to resolve the named copy by unregistering the embedded template; the installed
follow-up retained that result after a fresh game launch. Overlay appearance is
confirmed for the title. Restarting the overlay did not fix its remaining icon
placeholder. A case-sensitive IconServices lookup reproduced the placeholder for
the mixed-case runtime ID and rendered the game icon for its lowercase equivalent.
A runtime with normalized bundle metadata and its original signed identity retained
the existing downloads/keychain slot and reached the title screen; the tester
confirmed both the Games overlay title and icon were correct.
The final installed build passed a cold-start launcher check, retained the original
sandbox path, and rendered the correct icon through the normalized identifier.
Its signed identifier, provisioning profile, and all entitlements matched the
embedded runtime, and its deep/strict signature passed.

A successful build, SwiftLint, diff checks, deep/strict signatures, and preservation
of the original installed executable were checked. Launch-function complexity
warnings remain in SwiftLint. The slot allocator tests cover
stable/distinct assignments, upstream registry reuse, free-list consumption,
exhaustion, duplicate/colliding slots, corrupt-registry preservation, and 16
concurrent allocations.

```sh
mkdir -p build.noindex/tests
swiftc PlayCover/IsolatedRuntime/RuntimeKeychainSlots.swift \
  Tests/RuntimeKeychainSlotsTests.swift -o build.noindex/tests/runtime-slots
build.noindex/tests/runtime-slots
# Integration test: supply a current signed template, an expired profile for
# that same runtime, and the packaged RuntimeProvisioning/renew.sh.
swiftc PlayCover/IsolatedRuntime/RuntimeProvisioning.swift \
  Tests/RuntimeProvisioningTests.swift PlayCover/Utils/Shell.swift \
  PlayCover/Utils/Extensions/URLExtensions.swift PlayCover/ViewModel/Log.swift \
  -o build.noindex/tests/runtime-provisioning
build.noindex/tests/runtime-provisioning "$runtime" "$expired_profile" "$helper"
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
