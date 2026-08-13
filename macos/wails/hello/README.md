# Wails v3 hello — macOS

Official `wails3 init -t vanilla` (Wails **v3.0.0-beta.8**), slimmed to one
960×640 window + local HTML (system WKWebView). **Release weigh is
`wails3 package`** (`go build -tags production -ldflags="-w -s"`), not `wails3 dev`.

Go **1.26.5** was installed with Homebrew on this Mac (`wails3` was not
preinstalled).

## Requires

- Go 1.25+ (`go install github.com/wailsapp/wails/v3/cmd/wails3@latest`)
- Node.js (Vite frontend build)
- Xcode / CLT

## Build (Release)

```bash
export PATH="$(go env GOPATH)/bin:$PATH"
cd macos/wails/hello
wails3 package
```

Artifact (gitignored `bin/`): `bin/wails-hello.app`.

## Weigh

See [`../../../MEASUREMENTS.md`](../../../MEASUREMENTS.md) (2026-08-14).
RSS is the main `wails-hello` process; WebKit XPCs are extra.
