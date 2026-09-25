const CACHE_NAME = "durumcu-pwa-v6-fixed";
const STATIC_ASSETS = [
  "./manifest.json",
  "./icon-192.png",
  "./icon-512.png"
];

self.addEventListener("install", event => {
  event.waitUntil(
    caches.open(CACHE_NAME).then(cache =>
      Promise.all(STATIC_ASSETS.map(url => cache.add(url).catch(() => null)))
    )
  );
  self.skipWaiting();
});

self.addEventListener("activate", event => {
  event.waitUntil(
    caches.keys().then(keys => Promise.all(
      keys.filter(key => key !== CACHE_NAME).map(key => caches.delete(key))
    ))
  );
  self.clients.claim();
});

self.addEventListener("fetch", event => {
  if (event.request.method !== "GET") return;
  const url = new URL(event.request.url);

  // Supabase/CDN gibi harici istekleri service worker yönetmesin.
  if (url.origin !== self.location.origin) return;

  const path = url.pathname.toLowerCase();
  const isDynamic =
    event.request.mode === "navigate" ||
    path.endsWith("/index.html") ||
    path.endsWith("/admin.html") ||
    path.endsWith("/supabase-config.js");

  if (isDynamic) {
    event.respondWith(
      fetch(event.request, { cache: "no-store" })
        .then(response => {
          if (response.ok && event.request.mode === "navigate") {
            caches.open(CACHE_NAME).then(cache => cache.put(event.request, response.clone()));
          }
          return response;
        })
        .catch(async () => {
          const cached = await caches.match(event.request);
          if (cached) return cached;
          if (event.request.mode === "navigate") {
            return (await caches.match("./index.html")) || Response.error();
          }
          return Response.error();
        })
    );
    return;
  }

  event.respondWith(
    caches.match(event.request).then(cached =>
      cached || fetch(event.request).then(response => {
        if (response.ok) caches.open(CACHE_NAME).then(cache => cache.put(event.request, response.clone()));
        return response;
      })
    )
  );
});
