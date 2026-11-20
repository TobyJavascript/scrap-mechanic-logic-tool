// Shared by every page: the theme button (auto / light / dark, remembered between visits),
// the home page slideshow, feature showcase and version badge, and the docs table of contents highlight.

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

	// Home: cross-fade the hero backgrounds. Each image loads only when it's next,
	// and the slideshow pauses while the tab is hidden.
	function heroSlides() {
		var band = document.querySelector(".hero-band");
		var slides = document.querySelectorAll(".hero-bg .slide");
		if (!band || !slides.length) return;
		var SHOW_MS = 7000;
		var current = 0, timer = null, dots = [];

		function load(i) {
			var s = slides[i];
			if (s.dataset.loaded) return;
			s.style.backgroundImage = "url(" + s.dataset.src + ")";
			if (s.dataset.pos) s.style.backgroundPosition = s.dataset.pos;
			s.dataset.loaded = "1";
		}
		function show(i) {
			current = (i + slides.length) % slides.length;
			load(current);
			load((current + 1) % slides.length); // fetch the next one early
			slides.forEach(function (s, k) { s.classList.toggle("on", k === current); });
			dots.forEach(function (d, k) { d.setAttribute("aria-current", String(k === current)); });
		}
		function start() {
			clearInterval(timer);
			if (slides.length > 1 && !document.hidden) {
				timer = setInterval(function () { show(current + 1); }, SHOW_MS);
			}
		}

		if (slides.length > 1) {
			var bar = document.createElement("div");
			bar.className = "hero-dots";
			slides.forEach(function (s, k) {
				var b = document.createElement("button");
				b.type = "button";
				b.setAttribute("aria-label", "Background " + (k + 1));
				b.addEventListener("click", function () { show(k); start(); });
				bar.appendChild(b);
				dots.push(b);
			});
			band.appendChild(bar);
		}
		show(0);
		start();
		document.addEventListener("visibilitychange", start);
	}

	// Home: the feature showcase. Turns the list of <article class="feature"> into
	// one panel with tabs, arrows, arrow keys and swipe.
	function featureShowcase() {
		var box = document.querySelector(".showcase");
		if (!box) return;
		var panel = box.querySelector(".show-panel");
		var tabs = box.querySelector(".show-tabs");
		var items = Array.prototype.slice.call(panel.querySelectorAll(".feature"));
		if (!items.length) return;
		var current = 0;
		var tabButtons = [];

		items.forEach(function (f, i) {
			var text = document.createElement("div");
			text.className = "feature-text";
			while (f.firstChild) text.appendChild(f.firstChild);
			var shot = document.createElement("div");
			shot.className = "feature-shot";
			if (f.dataset.img) {
				var img = document.createElement("img");
				img.alt = f.dataset.name || "";
				img.dataset.src = f.dataset.img;
				img.addEventListener("error", function () { // file not there yet
					shot.textContent = "Screenshot coming soon";
					shot.classList.add("empty");
				});
				shot.appendChild(img);
			} else {
				shot.classList.add("empty");
				shot.textContent = "Screenshot coming soon";
			}
			f.appendChild(text);
			f.appendChild(shot);
			f.id = "feature-" + i;
			f.setAttribute("role", "tabpanel");

			var b = document.createElement("button");
			b.type = "button";
			b.setAttribute("role", "tab");
			b.setAttribute("aria-controls", f.id);
			b.textContent = f.dataset.name || ("Feature " + (i + 1));
			b.addEventListener("click", function () { show(i); });
			tabs.appendChild(b);
			tabButtons.push(b);
		});

		var nav = document.createElement("div");
		nav.className = "show-nav";
		nav.innerHTML = '<button type="button" aria-label="Previous feature">&#8249;</button>' +
			'<button type="button" aria-label="Next feature">&#8250;</button>' +
			'<span class="show-count" aria-live="polite"></span>';
		var navButtons = nav.querySelectorAll("button");
		var count = nav.querySelector(".show-count");
		navButtons[0].addEventListener("click", function () { show(current - 1); });
		navButtons[1].addEventListener("click", function () { show(current + 1); });
		panel.appendChild(nav);

		function loadImg(i) {
			var img = items[i].querySelector("img[data-src]");
			if (img) { img.src = img.dataset.src; img.removeAttribute("data-src"); }
		}
		function show(i) {
			current = (i + items.length) % items.length;
			loadImg(current);
			loadImg((current + 1) % items.length);
			items.forEach(function (f, k) { f.classList.toggle("on", k === current); });
			tabButtons.forEach(function (b, k) {
				b.setAttribute("aria-selected", String(k === current));
				b.tabIndex = k === current ? 0 : -1;
			});
			count.textContent = (current + 1) + " / " + items.length;
		}

		box.addEventListener("keydown", function (e) {
			if (e.key === "ArrowLeft") { show(current - 1); e.preventDefault(); }
			else if (e.key === "ArrowRight") { show(current + 1); e.preventDefault(); }
		});
		var startX = null;
		panel.addEventListener("touchstart", function (e) { startX = e.touches[0].clientX; }, { passive: true });
		panel.addEventListener("touchend", function (e) {
			if (startX === null) return;
			var dx = e.changedTouches[0].clientX - startX;
			startX = null;
			if (Math.abs(dx) > 50) show(current + (dx < 0 ? 1 : -1));
		});

		show(0);
	}

	// Home: show the current version in the hero badge: the latest GitHub release,
	// or the newest vX.Y.Z tag before there is one. Asks GitHub's API once per visit;
	// if that fails the badge keeps its text from the HTML.
	function showVersion() {
		var badge = document.getElementById("version");
		if (!badge || !window.fetch) return;
		var REPO = "TobyJavascript/scrap-mechanic-logic-tool";
		var CACHE = "tobywand-version";

		function show(tag) {
			var a = document.createElement("a");
			a.className = "status";
			a.id = "version";
			a.href = "https://github.com/" + REPO + "/releases/tag/" + encodeURIComponent(tag);
			// 1.0 and up is a release; 0.x tags are still in development
			var major = /^v?(\d+)\./.exec(tag);
			a.textContent = major && +major[1] >= 1 ? "Latest release \u00B7 " + tag : "In development \u00B7 " + tag;
			badge.replaceWith(a);
		}
		function newest(tags) {
			var best = null, bestNums = null;
			tags.forEach(function (t) {
				var m = /^v?(\d+)\.(\d+)\.(\d+)$/.exec(t.name);
				if (!m) return;
				var nums = [+m[1], +m[2], +m[3]];
				for (var i = 0; bestNums && i < 3 && nums[i] === bestNums[i]; i++);
				if (!bestNums || (i < 3 && nums[i] > bestNums[i])) { best = t.name; bestNums = nums; }
			});
			return best;
		}

		try {
			var cached = sessionStorage.getItem(CACHE);
			if (cached) { show(cached); return; }
		} catch (e) { /* storage blocked */ }
		var API = "https://api.github.com/repos/" + REPO;
		// The latest GitHub release is one small answer. Until the first release
		// exists (404), fall back to picking the newest from the tag list.
		fetch(API + "/releases/latest")
			.then(function (r) {
				if (r.ok) return r.json().then(function (rel) { return rel.tag_name; });
				if (r.status !== 404) return null;
				return fetch(API + "/tags?per_page=100")
					.then(function (r2) { return r2.ok ? r2.json() : []; })
					.then(function (tags) { return Array.isArray(tags) && newest(tags); });
			})
			.then(function (tag) {
				if (!tag) return;
				try { sessionStorage.setItem(CACHE, tag); } catch (e) { /* storage blocked */ }
				show(tag);
			})
			.catch(function () { /* offline or rate limited: keep the HTML text */ });
	}

	// Runs in <head>, so the saved theme is set before the page is drawn
	root.classList.add("js"); // home page: styles for the slideshow and showcase
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

		heroSlides();
		showVersion();
		featureShowcase();

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
