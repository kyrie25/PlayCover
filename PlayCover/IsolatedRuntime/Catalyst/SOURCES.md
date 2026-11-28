# Source and licenses

The Catalyst runtime and the host's Mach-O conversion routine derive from
[iOSAppRunner at 6931452](https://github.com/ohaiibuzzle/iOSAppRunner/tree/6931452d1880653dc706236fefba054e7e008a78).
The upstream project includes code from LiveContainer and Jake James's dylibify.
The upstream GPLv3 license is in `LICENSE`. Original source notices are retained.

The keychain adapter uses
[litehook at 8025e0c](https://github.com/LiveContainer/litehook/tree/8025e0c8ebdf5cdd1d2a4f45025813234bf9dc55).
Its MIT license is in `litehook/LICENSE`. Its dyld format headers carry their
own Apple license notices.

PlayCover builds the Catalyst target and the host-side Dylibifier. The runtime
retains upstream guest bundle, dyld, executable-path, cryptid, group-container,
and keychain compatibility hooks while leaving window sizing, input, and device
settings to PlayTools. It includes the PlayCover sandbox exceptions and uses
the existing runtime bundle ID and keychain access groups.
