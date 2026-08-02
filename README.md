# quill

Quill is a fully local meeting recorder and transcriber. It records the local
microphone and computer playback as separate tracks, transcribes them on the
device, and writes a timestamped `me` / `them` transcript. Recordings and
transcripts never leave the machine.

## Platforms

| Platform | Status | Documentation |
|---|---|---|
| macOS 15+ | Working implementation | [macOS](macos/README.md) |
| Windows 11 | Capture probe planned | [Windows](windows/README.md) |
| Linux | Capture probe proposed | [Linux](linux/README.md) |

The platform implementations are native and independent. They share Quill's
product behavior, session layout, transcript contract, and test fixtures rather
than application source code. See [Architecture](docs/architecture.md).

## macOS quick start

```sh
./scripts/build-macos
sudo ./scripts/install-macos
quill install --launch-at-login  # optional
```

See the [macOS documentation](macos/README.md) for permissions, configuration,
usage, and troubleshooting.

## Repository

```text
macos/       Swift and native macOS implementation
windows/     Native Windows implementation boundary
linux/       Native Linux implementation boundary
docs/        Durable architecture and decision records
.plan/       Roadmap and active implementation plans
scripts/     Stable repository-level build and installation commands
```

Named for the feather. Sibling of
[parrot](https://github.com/digimata/parrot).
