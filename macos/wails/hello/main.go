package main

import (
	"embed"
	"log"
	"os"

	"github.com/wailsapp/wails/v3/pkg/application"
)

//go:embed all:frontend/dist
var assets embed.FS

func main() {
	url := os.Getenv("KELD_BENCH_URL")
	if url == "" {
		url = "/"
	}

	app := application.New(application.Options{
		Name:        "Wails Hello",
		Description: "keld-benches macOS hello-window fixture (Wails v3)",
		Assets: application.AssetOptions{
			Handler: application.AssetFileServerFS(assets),
		},
		Mac: application.MacOptions{
			ApplicationShouldTerminateAfterLastWindowClosed: true,
		},
	})

	app.Window.NewWithOptions(application.WebviewWindowOptions{
		Title:            "Wails Hello",
		Width:            960,
		Height:           640,
		BackgroundColour: application.NewRGB(11, 15, 20),
		URL:              url,
	})

	if err := app.Run(); err != nil {
		log.Fatal(err)
	}
}
