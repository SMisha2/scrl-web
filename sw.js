const CACHE_NAME = "scrl-world-backgrounds-v2";
const CACHE_PREFIX = "scrl-world-backgrounds-";
const BACKGROUND_FILES = new Set(["night.png", "day.png"]);

self.addEventListener("install", event => {
  event.waitUntil((async () => {
    const cache = await caches.open(CACHE_NAME);
    const urls = [...BACKGROUND_FILES].map(name =>
      new URL("assets/backgrounds/" + name, self.registration.scope).href
    );
    await Promise.all(urls.map(async url => {
      try {
        const response = await fetch(url, { cache: "reload" });
        if (response.ok) await cache.put(url, response);
      } catch (_) {
        // Keep installing even when the user is temporarily offline.
      }
    }));
    await self.skipWaiting();
  })());
});

self.addEventListener("activate", event => {
  event.waitUntil((async () => {
    const names = await caches.keys();
    await Promise.all(names
      .filter(name => name.startsWith(CACHE_PREFIX) && name !== CACHE_NAME)
      .map(name => caches.delete(name)));
    await self.clients.claim();
  })());
});

self.addEventListener("fetch", event => {
  const request = event.request;
  if (request.method !== "GET") return;
  const url = new URL(request.url);
  if (url.origin !== self.location.origin) return;
  const filename = url.pathname.split("/").pop();
  if (!BACKGROUND_FILES.has(filename) || !url.pathname.includes("/assets/backgrounds/")) return;

  event.respondWith((async () => {
    const cache = await caches.open(CACHE_NAME);
    const cached = await cache.match(request, { ignoreSearch: true });
    if (cached) return cached;

    const response = await fetch(request);
    if (response.ok) await cache.put(request, response.clone());
    return response;
  })());
});
