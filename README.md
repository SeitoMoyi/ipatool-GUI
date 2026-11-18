# ipatool GUI

A native macOS frontend for [ipatool](https://github.com/majd/ipatool). Search Apple's public catalog by app name, storefront, and platform. Sign in through Terminal to browse and download versions using the official ipatool CLI.

## Build and open

Use macOS 14 or later and Swift 6 from Xcode 16 or its Command Line Tools.

```sh
git clone https://github.com/SeitoMoyi/ipatool-GUI.git
cd ipatool-GUI
./build-app.sh
open .build/ipatool.app
```

The build produces a local, ad-hoc signed app for the build Mac's architecture.

## Backend installation

The first launch downloads the latest stable release from the upstream [ipatool releases](https://github.com/majd/ipatool/releases). The installer selects the matching Intel or Apple silicon asset, checks it against the release's SHA-256 file, and installs the binary at `~/Library/Application Support/ipatool-desktop/bin/ipatool`. Subsequent launches reuse that binary. Search works while installation runs. If the download fails, click **Retry Install** in the app.

The Swift app uses the public App Store catalog for regional search. It invokes the CLI for Apple Account sign-in, version history, and package downloads. It uses the CLI's existing Apple Account session and supports released CLI commands. On releases that list build IDs without marking the latest one, the menu shows **Latest available** and the builds returned by ipatool separately.

### Version history on ipatool 2.8.1

Version history can fail with `available storefronts request failed` when the CLI tries to resolve the account's storefront. The [upstream storefront fix](https://github.com/majd/ipatool/commit/3b02b4c55576562f2a55284cda9db9a4411d3067) is newer than v2.8.1. A CLI built from that commit can be placed at the backend path above to use the fix.

## License

MIT. See [LICENSE](LICENSE).
