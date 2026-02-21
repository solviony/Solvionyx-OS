(function () {
  const DEFAULT_LOCALE = "en";

  function normalizeLocale(input) {
    if (!input) return DEFAULT_LOCALE;
    const s = String(input).toLowerCase().replace("_", "-");
    // Accept "en", "en-us", "es", "fr", etc.
    const base = s.split("-")[0];
    return base || DEFAULT_LOCALE;
  }

  async function fetchJson(path) {
    const res = await fetch(path, { cache: "no-store" });
    if (!res.ok) throw new Error("i18n fetch failed: " + path);
    return res.json();
  }

  async function loadLocale() {
    // Calamares often sets LANG/LC_ALL in environment; in slideshow context we may not see it.
    // We fall back to browser language if present.
    const hint =
      (window.CALAMARES_LOCALE || "") ||
      (navigator.language || "") ||
      (navigator.languages && navigator.languages[0]) ||
      DEFAULT_LOCALE;

    const locale = normalizeLocale(hint);

    // Try exact base locale file, else fallback to English.
    try {
      const dict = await fetchJson(`../assets/i18n/${locale}.json`);
      return { locale, dict };
    } catch (e) {
      const dict = await fetchJson(`../assets/i18n/${DEFAULT_LOCALE}.json`);
      return { locale: DEFAULT_LOCALE, dict };
    }
  }

  function applyI18n(dict) {
    document.querySelectorAll("[data-i18n]").forEach((el) => {
      const key = el.getAttribute("data-i18n");
      if (!key) return;
      const val = dict[key];
      if (typeof val === "string") el.textContent = val;
    });
  }

  window.SolvionyxI18n = {
    loadLocale,
    applyI18n,
  };
})();
