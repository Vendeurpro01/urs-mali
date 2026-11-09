// URS Mali : sert uniquement à afficher les notifications du téléphone (aucune mise en cache).
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", e => e.waitUntil(self.clients.claim()));
self.addEventListener("notificationclick", e => {
  e.notification.close();
  const tag = String(e.notification.tag || "").replace(/\D/g, "");
  e.waitUntil(self.clients.matchAll({ type: "window", includeUncontrolled: true }).then(cs => {
    for (const c of cs) { c.postMessage({ notif: tag }); return c.focus(); }
    return self.clients.openWindow("/?notif=" + tag);
  }));
});
