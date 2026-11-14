// Shared by every page: the theme button (auto / light / dark, remembered between visits).

(function () {
	var root = document.documentElement;
	var KEY = "tobywand-theme";
	var NAMES = { auto: "◐ Auto", light: "☀ Light", dark: "☾ Dark" };
	var ORDER = ["auto", "light", "dark"];

	function read() {
		try { return localStorage.getItem(KEY) || "auto"; } catch (e) { return "auto"; }
	}
	function apply(mode) {
		if (mode === "auto") root.removeAttribute("data-theme");
		else root.setAttribute("data-theme", mode);
		var btn = document.querySelector(".theme-toggle");
		if (btn) {
			btn.textContent = NAMES[mode];
			btn.setAttribute("aria-label", "Theme: " + mode + " (click to change)");
		}
	}

	// Runs in <head>, so the saved theme is set before the page is drawn
	var mode = read();
	apply(mode);

	document.addEventListener("DOMContentLoaded", function () {
		apply(mode);
		var btn = document.querySelector(".theme-toggle");
		if (!btn) return;
		btn.addEventListener("click", function () {
			mode = ORDER[(ORDER.indexOf(mode) + 1) % ORDER.length];
			try { localStorage.setItem(KEY, mode); } catch (e) { /* private window */ }
			apply(mode);
		});
	});
})();
