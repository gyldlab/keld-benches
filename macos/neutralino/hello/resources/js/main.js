Neutralino.init();

Neutralino.events.on("windowClose", () => {
  Neutralino.app.exit();
});

Neutralino.events.on("ready", () => {
  Neutralino.filesystem
    .writeFile("/tmp/keld-benches-neutralino-painted", "painted")
    .catch(() => {});
});
