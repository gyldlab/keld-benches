package main

import (
	"embed"
	"log"

	"github.com/wailsapp/wails/v3/pkg/application"
)

//go:embed all:frontend/dist
var assets embed.FS

// Minimal Wails v3 hello window — Windows (WebView2).
//
// Deliberately stripped from the `wails3 init -t vanilla` template so this arm
// matches the other keld-benches fixtures (M-01, same UI contract):
//   - no GreetService / Services: nothing else binds a Go object into the page
//   - no time-emitting goroutine: the template ticks an event every second,
//     which would charge this arm CPU and RSS no other arm pays
//   - no MacOptions / MacWindow: Windows quits on last-window-close by
//     convention, and the translucent-titlebar backdrop is macOS-only chrome
//   - 960x640 and #0b0f14, identical to the Keld / Tauri / Electron fixtures
func main() {
	app := application.New(application.Options{
		Name:        "Wails Hello",
		Description: "keld-benches Windows hello-window fixture (Wails v3)",
		Assets: application.AssetOptions{
			Handler: application.AssetFileServerFS(assets),
		},
	})

	app.Window.NewWithOptions(application.WebviewWindowOptions{
		Title:            "Wails Hello",
		Width:            960,
		Height:           640,
		BackgroundColour: application.NewRGB(11, 15, 20),
		URL:              "/",
	})

	if err := app.Run(); err != nil {
		log.Fatal(err)
	}
}
