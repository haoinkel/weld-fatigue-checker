/* Service Worker：离线缓存，使 PWA 可“添加到主屏幕”后离线使用 */
const CACHE = "wf-checker-v4";
const ASSETS = [
  "./",
  "./index.html",
  "./styles.css",
  "./manifest.webmanifest",
  "./sw.js",
  "./js/knowledge.js",
  "./js/packs.js",
  "./js/standard_registry.js",
  "./js/engine.js",
  "./js/design_rules.js",
  "./js/app.js",
  "./js/three_viewer.js",
  "./vendor/three.module.js",
  "./vendor/occt-import-js.js",
  "./vendor/loaders/OBJLoader.js",
  "./vendor/loaders/STLLoader.js",
  "./vendor/loaders/GLTFLoader.js",
  "./vendor/loaders/OrbitControls.js",
  "./vendor/utils/BufferGeometryUtils.js",
  "./icons/icon-192.png",
  "./icons/icon-512.png",
  "./samples/gb50017-2017.pack.json"
];

self.addEventListener("install", (e) => {
  e.waitUntil(caches.open(CACHE).then((c) => c.addAll(ASSETS)).then(() => self.skipWaiting()));
});

self.addEventListener("activate", (e) => {
  e.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k)))
    ).then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", (e) => {
  if (e.request.method !== "GET") return;
  e.respondWith(
    caches.match(e.request).then((hit) =>
      hit || fetch(e.request).then((res) => {
        const copy = res.clone();
        caches.open(CACHE).then((c) => c.put(e.request, copy)).catch(() => {});
        return res;
      }).catch(() => hit)
    )
  );
});
