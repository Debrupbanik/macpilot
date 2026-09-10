# MacPilot

A native macOS dashboard for CPU, memory, storage, window management, and cleanup workflows, with a Linux terminal edition.

## Current status

MacPilot is an early preview. CPU, memory, and disk usage are live. The window-management surface currently explains the required Accessibility permission, and the cleanup flow is review-first. GPU utilization is shown as unavailable because macOS does not provide a supported public API for generic GPU utilization.

## Requirements

- macOS 14 Sonoma or later
- Xcode 16 or later for local app bundling
- Apple Silicon or Intel Mac

## Run from source

```sh
git clone https://github.com/YOUR-USERNAME/macpilot.git
cd macpilot
swift run
```

### Linux

Linux builds provide a terminal dashboard with CPU load, memory, and root-disk usage:

```sh
swift run MacPilot
```

The Linux edition reads standard `/proc` metrics and works without third-party packages. Window arrangement remains desktop-session-specific: use your Wayland compositor's tiling features, or install `wmctrl` for an X11 workflow.

The repository builds as a Swift Package. Open the package in Xcode to run it as a normal macOS app and configure signing.

## Download a release

Download the latest `MacPilot.zip` from the repository's **Releases** page, unzip it, and move `MacPilot.app` to Applications. Because the app is not currently notarized, macOS may require Control-clicking the app and choosing **Open** the first time.

## Permissions

Window control will require **System Settings > Privacy & Security > Accessibility**. MacPilot will not remove files without a future review and confirmation step.

## License

MIT. See [LICENSE](LICENSE).
