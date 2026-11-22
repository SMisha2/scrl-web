const CACHE_NAME = "scrl-world-backgrounds-v6";
const CACHE_PREFIX = "scrl-world-backgrounds-";
// WebP versions are about 90% smaller than the PNG fallbacks, which matters
// for school networks and mobile traffic. Older browsers keep the PNG path.
const BACKGROUND_FILES = new Set(["night.webp", "day.webp"]);

function getBackgroundUrl(filename) {
  return new URL("assets/backgrounds/" + filename, self.registration.scope).href;
}

self.addEventListener("install", event => {
  event.waitUntil((async () => {
    const cache = await caches.open(CACHE_NAME);
    const urls = [...BACKGROUND_FILES].map(getBackgroundUrl);

    // The worker only activates after both real background images are saved.
    // If the connection drops, the previous worker/cache remains in service.
    await Promise.all(urls.map(async url => {
      const response = await fetch(url);
      if (!response.ok) {
        throw new Error("Не удалось загрузить фон: " + url + " (" + response.status + ")");
      }
      await cache.put(url, response.clone());
    }));

    await self.skipWaiting();
  })());
});

self.addEventListener("activate", event => {
  event.waitUntil((async () => {
    const cache = await caches.open(CACHE_NAME);
    const urls = [...BACKGROUND_FILES].map(getBackgroundUrl);
    const saved = await Promise.all(urls.map(url => cache.match(url)));

    // Never remove the previous working cache until the new one is complete.
    if (saved.every(Boolean)) {
      const names = await caches.keys();
      await Promise.all(names
        .filter(name => name.startsWith(CACHE_PREFIX) && name !== CACHE_NAME)
        .map(name => caches.delete(name)));
    }

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
    const cacheUrl = getBackgroundUrl(filename);
    const cached = await cache.match(cacheUrl, { ignoreSearch: true });
    if (cached) return cached;

    const response = await fetch(request);
    if (response.ok) await cache.put(cacheUrl, response.clone());
    return response;
  })());
});
