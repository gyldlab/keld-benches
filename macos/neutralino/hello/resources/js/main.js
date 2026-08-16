Neutralino.init();

Neutralino.events.on("windowClose", () => {
  Neutralino.app.exit();
});

let confirmWindowFocus;
const windowFocusObserved = new Promise((resolve) => {
  confirmWindowFocus = resolve;
});
Neutralino.events.on("windowFocus", () => {
  confirmWindowFocus();
});

Neutralino.events.on("ready", async () => {
  const benchmarkURL = await Neutralino.os.getEnv("KELD_BENCH_URL");
  if (benchmarkURL) {
    await Neutralino.window.focus();
    await windowFocusObserved;
    window.location.replace(benchmarkURL);
    return;
  }
  Neutralino.filesystem
    .writeFile("/tmp/keld-benches-neutralino-painted", "painted")
    .catch(() => {});
});
