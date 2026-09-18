(() => {
  const image = new Image();
  image.alt = "";
  image.width = 1;
  image.height = 1;
  image.style.cssText = "position:absolute;width:1px;height:1px;opacity:0;pointer-events:none";

  requestAnimationFrame(() => {
    requestAnimationFrame(() => {
      const visibility = encodeURIComponent(document.visibilityState);
      const focus = document.hasFocus() ? "1" : "0";
      image.src =
        "http://127.0.0.1:__KELD_BENCH_PORT__/run/__KELD_BENCH_NONCE__/paint.gif" +
        "?nonce=__KELD_BENCH_NONCE__&phase=double-raf&visibility=" +
        visibility +
        "&focus=" +
        focus;
      document.body.appendChild(image);
    });
  });
})();
