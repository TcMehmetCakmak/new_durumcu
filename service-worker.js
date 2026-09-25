const CACHE_NAME = "durumcu-pwa-v4-live-3day";
const APP_SHELL = [
  "./index.html",
  "./admin.html",
  "./supabase-config.js",
  "./manifest.json",
  "./icon-192.png",
  "./icon-512.png"
];

self.addEventListener("install", event => {
  event.waitUntil(caches.open(CACHE_NAME).then(cache => cache.addAll(APP_SHELL)));
  self.skipWaiting();
});

self.addEventListener("activate", event => {
  event.waitUntil(
    caches.keys().then(keys => Promise.all(
      keys.filter(k => k !== CACHE_NAME).map(k => caches.delete(k))
    ))
  );
  self.clients.claim();
});

self.addEventListener("fetch", event => {
  if (event.request.method !== "GET") return;

  const url = new URL(event.request.url);

  // Supabase ve CDN istekleri hiçbir zaman Service Worker cache'ine alınmaz.
  if (url.origin !== self.location.origin) return;

  const path = url.pathname.toLowerCase();
  const networkFirst =
    event.request.mode === "navigate" ||
    path.endsWith("/index.html") ||
    path.endsWith("/admin.html") ||
    path.endsWith("/supabase-config.js");

  if (networkFirst) {
    event.respondWith(
      fetch(event.request, { cache: "no-store" })
        .then(response => {
          if (response.ok) {
            const copy = response.clone();
            caches.open(CACHE_NAME).then(cache => cache.put(event.request, copy));
          }
          return response;
        })
        .catch(() => caches.match(event.request).then(r => r || caches.match("./index.html")))
    );
    return;
  }

  event.respondWith(
    caches.match(event.request).then(cached => cached || fetch(event.request).then(response => {
      if (response.ok) {
        const copy = response.clone();
        caches.open(CACHE_NAME).then(cache => cache.put(event.request, copy));
      }
      return response;
    }))
  );
});
