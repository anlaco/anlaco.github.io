// Service worker que añade las cabeceras COOP/COEP a todas las respuestas.
//
// SharedArrayBuffer (que el ejecutor usa para esperar la respuesta del
// teclado) solo existe en páginas "cross-origin isolated", y eso exige
// dos cabeceras HTTP que ni GitHub Pages ni `python -m http.server`
// mandan. Este service worker las inyecta por el camino: la página se
// registra, recarga una vez, y a partir de ahí todo pasa por aquí.
//
// COEP require-corp obliga a que lo de otros dominios (el CDN de
// Pyodide) declare Cross-Origin-Resource-Policy — jsdelivr lo hace.

self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (evento) => evento.waitUntil(self.clients.claim()));

self.addEventListener("fetch", (evento) => {
  evento.respondWith(
    (async () => {
      const respuesta = await fetch(evento.request);
      // Las respuestas opacas (status 0) no se pueden reconstruir.
      if (respuesta.status === 0) return respuesta;
      const cabeceras = new Headers(respuesta.headers);
      cabeceras.set("Cross-Origin-Opener-Policy", "same-origin");
      cabeceras.set("Cross-Origin-Embedder-Policy", "require-corp");
      return new Response(respuesta.body, {
        status: respuesta.status,
        statusText: respuesta.statusText,
        headers: cabeceras,
      });
    })()
  );
});
