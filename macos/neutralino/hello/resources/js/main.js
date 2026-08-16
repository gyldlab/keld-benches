Neutralino.init();

Neutralino.events.on("windowClose", () => {
  Neutralino.app.exit();
});

Neutralino.events.on("ready", async () => {
  try {
    const benchmarkURL = await Neutralino.os.getEnv("KELD_BENCH_URL");
    if (benchmarkURL) {
      window.location.replace(benchmarkURL);
      return;
    }
  } catch (_) {}
  Neutralino.filesystem
    .writeFile("/tmp/keld-benches-neutralino-painted", "painted")
    .catch(() => {});
});
