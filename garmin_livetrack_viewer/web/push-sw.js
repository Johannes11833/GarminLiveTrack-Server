self.addEventListener('install', () => {
  // Activate immediately so push subscriptions can be created without
  // waiting for a reload (an older worker may still control the tab).
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(self.clients.claim());
});

self.addEventListener('push', (event) => {
  let payload = {};
  try {
    payload = event.data ? event.data.json() : {};
  } catch (error) {
    payload = { body: event.data ? event.data.text() : '' };
  }
  const title = payload.title || 'Garmin LiveTrack';
  const options = {
    body: payload.body || '',
    icon: 'icons/icon-192.png',
    badge: 'icons/icon-192.png',
    tag: payload.tag || 'livetrack',
    data: {
      sessionId: payload.sessionId || '',
      sessionToken: payload.sessionToken || '',
    },
  };
  event.waitUntil(self.registration.showNotification(title, options));
});

// Query parameters that identify the session and must be replaced when the
// notification deep-links into an already-open app window. Everything else
// (notably the push-registration ?token=) is left alone.
const SESSION_PARAMS = ['id', 'sessionToken'];

function targetUrl(data) {
  const url = new URL(self.registration.scope);
  if (data.sessionId) url.searchParams.set('id', String(data.sessionId));
  if (data.sessionToken) {
    url.searchParams.set('sessionToken', String(data.sessionToken));
  }
  return url;
}

function isAppWindow(client, pathname) {
  if (client.frameType !== 'top-level') return false;
  try {
    return new URL(client.url).pathname === pathname;
  } catch (_) {
    return false;
  }
}

async function findAppWindow(pathname) {
  try {
    // No `includeUncontrolled`: WindowClient.navigate() rejects for clients
    // not controlled by this worker (e.g. a tab that was already open when
    // the worker was installed). Such a rejection used to abort the whole
    // click handler, so nothing opened at all.
    const windows = await clients.matchAll({ type: 'window' });
    return (
      windows.find((client) => client.focused && isAppWindow(client, pathname)) ||
      windows.find((client) => isAppWindow(client, pathname)) ||
      null
    );
  } catch (_) {
    return null;
  }
}

function withCurrentParams(originalUrl, target) {
  const url = new URL(target.href);
  try {
    const current = new URL(originalUrl);
    for (const [key, value] of current.searchParams) {
      if (!SESSION_PARAMS.includes(key) && !url.searchParams.has(key)) {
        url.searchParams.set(key, value);
      }
    }
    if (current.hash) url.hash = current.hash;
  } catch (_) {}
  return url.href;
}

// Reuses and focuses an existing app window. Returns false when the window
// could not be navigated or focused, so the caller can fall back to
// openWindow().
async function focusAppWindow(client, target) {
  if (!client) return false;
  try {
    const navigated = await client.navigate(withCurrentParams(client.url, target));
    if (!navigated) return false;
    const focused = await navigated.focus();
    // On Android, focus() can resolve even though the WebAPK stayed in the
    // background; `focused` tells us whether the app actually came forward.
    return Boolean(focused) && focused.focused !== false;
  } catch (_) {
    return false;
  }
}

async function openAppWindow(target) {
  try {
    return Boolean(await clients.openWindow(target.href));
  } catch (_) {
    return false;
  }
}

// A client can report `focused: true` while its window is actually in the
// background (Android WebAPKs are particularly inconsistent here). Treat an
// explicitly hidden window as backgrounded; older implementations that do not
// expose visibilityState fall back to `focused` alone.
function isVisible(client) {
  return Boolean(client && client.focused && client.visibilityState !== 'hidden');
}

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const data = event.notification.data || {};
  const target = targetUrl(data);

  event.waitUntil((async () => {
    const client = await findAppWindow(target.pathname);
    const isAndroid = /Android/i.test(navigator.userAgent);

    // Android's WebAPK window management is unreliable for backgrounded
    // apps: WindowClient.focus()/navigate() can silently do nothing (and
    // some Android 15 builds crash the browser inside focus()). In that
    // state openWindow() is the only reliable way to launch/foreground the
    // installed app, so prefer it there unless the window is already
    // visible. On other platforms reuse the window to avoid a new tab for
    // every notification.
    if (!isAndroid || isVisible(client)) {
      if (await focusAppWindow(client, target)) return;
    }
    if (await openAppWindow(target)) return;
    if (await focusAppWindow(client, target)) return;

    // Last resort. Never let the event promise reject: a rejected
    // notificationclick event performs no default action at all.
    if (client) {
      try {
        await client.focus();
      } catch (_) {}
    }
  })());
});
