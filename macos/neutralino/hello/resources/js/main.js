Neutralino.init();

Neutralino.events.on("windowClose", () => {
  Neutralino.app.exit();
});

Neutralino.events.on("ready", async () => {
  const benchmarkURL = await Neutralino.os.getEnv("KELD_BENCH_URL");
  if (benchmarkURL) {
    await Neutralino.window.focus();
    window.location.replace(benchmarkURL);
    return;
  }
  Neutralino.filesystem
    .writeFile("/tmp/keld-benches-neutralino-painted", "painted")
    .catch(() => {});
});
