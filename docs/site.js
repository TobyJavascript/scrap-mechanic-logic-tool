// Shared by every page: the theme button (auto / light / dark, remembered between visits)
// and, on the docs page, the table of contents highlight.

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
		if (btn) {
			btn.addEventListener("click", function () {
				mode = ORDER[(ORDER.indexOf(mode) + 1) % ORDER.length];
				try { localStorage.setItem(KEY, mode); } catch (e) { /* private window */ }
				apply(mode);
			});
		}

		// Docs: highlight the section being read
		var links = document.querySelectorAll(".toc a[href^='#']");
		if (!links.length || !("IntersectionObserver" in window)) return;
		var byId = {};
		links.forEach(function (a) { byId[a.getAttribute("href").slice(1)] = a; });
		var seen = new Set();
		var obs = new IntersectionObserver(function (entries) {
			entries.forEach(function (e) {
				if (e.isIntersecting) seen.add(e.target.id); else seen.delete(e.target.id);
			});
			var first = null;
			document.querySelectorAll(".doc [id]").forEach(function (el) {
				if (!first && seen.has(el.id) && byId[el.id]) first = el.id;
			});
			if (!first) return;
			links.forEach(function (a) { a.classList.toggle("on", a === byId[first]); });
		}, { rootMargin: "-70px 0px -60% 0px" });
		Object.keys(byId).forEach(function (id) {
			var el = document.getElementById(id);
			if (el) obs.observe(el);
		});
	});
})();
