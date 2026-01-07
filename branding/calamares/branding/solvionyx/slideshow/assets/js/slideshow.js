(async function () {
  const { locale, dict } = await window.SolvionyxI18n.loadLocale();
  window.__I18N__ = dict;

  window.SolvionyxI18n.applyI18n(dict);

  // Show locale in the UI (optional)
  const pill = document.querySelector(".pill b");
  if (pill) pill.textContent = locale.toUpperCase();

  // Baseline progress (for preview / no events)
  if (window.SolvionyxProgress) {
    window.SolvionyxProgress.setProgress(12, "progress_preparing");
  }
})();
