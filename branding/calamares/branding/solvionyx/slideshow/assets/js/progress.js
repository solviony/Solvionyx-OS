(function () {
  // This is designed to work in multiple environments:
  // - Calamares slideshow that posts progress events
  // - Plain browser preview (no progress events) => it shows "Preparing…"

  function setProgress(pct, key) {
    const bar = document.querySelector(".bar > i");
    const status = document.querySelector(".status");
    if (bar && typeof pct === "number") bar.style.width = Math.max(2, Math.min(100, pct)) + "%";

    const dict = (window.__I18N__ || {});
    if (status) {
      status.textContent = dict[key] || dict["progress_preparing"] || "Preparing installation…";
    }
  }

  // Default
  window.SolvionyxProgress = { setProgress };

  // Calamares can dispatch events differently depending on slideshow implementation.
  // We support common patterns:
  // 1) window.postMessage({type:'calamares', ...})
  // 2) Custom events: document.dispatchEvent(new CustomEvent('calamares-progress', {detail:{...}}))
  window.addEventListener("message", (ev) => {
    const data = ev.data || {};
    // Flexible parsing
    const pct = data.percent ?? data.percentage ?? data.progress;
    const stage = (data.stage || data.step || data.message || "").toString().toLowerCase();

    let key = "progress_preparing";
    if (stage.includes("partition")) key = "progress_partitioning";
    else if (stage.includes("copy")) key = "progress_copying";
    else if (stage.includes("config")) key = "progress_configuring";
    else if (stage.includes("bootloader") || stage.includes("grub")) key = "progress_installing_bootloader";
    else if (stage.includes("final")) key = "progress_finalizing";
    else if (stage.includes("done") || stage.includes("complete")) key = "progress_done";

    if (typeof pct === "number") setProgress(pct, key);
  });

  document.addEventListener("calamares-progress", (ev) => {
    const d = (ev.detail || {});
    const pct = d.percent ?? d.percentage ?? d.progress;
    const key = d.key || "progress_preparing";
    setProgress(typeof pct === "number" ? pct : 10, key);
  });
})();
