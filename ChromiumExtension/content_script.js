if (!globalThis.__keywayMediaBridgeInstalled) {
globalThis.__keywayMediaBridgeInstalled = true;

const documentID = crypto.randomUUID
  ? crypto.randomUUID()
  : `${Date.now()}-${Math.random().toString(36).slice(2)}`;
const keywayMedia = new WeakMap();
let nextMediaIndex = 1;
let bridgeActive = true;
let publishTimer = null;
const baseSupportedCommands = ["play", "pause", "playPause", "mute", "volumeDelta"];
const trackControlSelectors = {
  next: [
    '[data-testid="control-button-skip-forward"]',
    '[aria-label="Next"]',
    '[aria-label="Next track"]',
    '[title="Next"]',
    '[title="Next track"]',
    ".ytp-next-button",
  ],
  previous: [
    '[data-testid="control-button-skip-back"]',
    '[aria-label="Previous"]',
    '[aria-label="Previous track"]',
    '[title="Previous"]',
    '[title="Previous track"]',
    ".ytp-prev-button",
  ],
};

function mediaIdFor(element) {
  const existing = keywayMedia.get(element);
  if (existing) return existing;

  const id = `media-${nextMediaIndex}`;
  nextMediaIndex += 1;
  keywayMedia.set(element, id);
  return id;
}

function mediaElements() {
  const elements = [];
  const visit = root => {
    for (const element of root.querySelectorAll("video,audio")) {
      elements.push(element);
    }
    for (const element of root.querySelectorAll("*")) {
      if (element.shadowRoot) visit(element.shadowRoot);
    }
  };

  visit(document);
  return elements;
}

function isClickable(element) {
  if (!element || element.disabled || element.getAttribute("aria-disabled") === "true") return false;
  const rect = element.getBoundingClientRect();
  return rect.width > 0 && rect.height > 0;
}

function trackControl(command) {
  const selectors = trackControlSelectors[command] || [];
  for (const selector of selectors) {
    const element = querySelectorDeep(selector);
    if (isClickable(element)) return element;
  }
  return null;
}

function querySelectorDeep(selector) {
  const roots = [document];
  while (roots.length) {
    const root = roots.shift();
    const match = root.querySelector(selector);
    if (match) return match;
    for (const element of root.querySelectorAll("*")) {
      if (element.shadowRoot) roots.push(element.shadowRoot);
    }
  }
  return null;
}

function supportedCommands() {
  const commands = baseSupportedCommands.slice();
  if (trackControl("next")) commands.push("next");
  if (trackControl("previous")) commands.push("previous");
  return commands;
}

function isUsableMedia(element) {
  return !element.ended && Boolean(element.currentSrc || element.src || element.querySelector("source"));
}

function runtimeAvailable() {
  return bridgeActive
    && typeof chrome !== "undefined"
    && Boolean(chrome.runtime?.id)
    && typeof chrome.runtime.sendMessage === "function"
    && typeof chrome.runtime.onMessage?.addListener === "function";
}

function retireBridge() {
  bridgeActive = false;
  observer.disconnect();
  if (publishTimer !== null) {
    clearInterval(publishTimer);
    publishTimer = null;
  }
}

function sendRuntimeMessage(message) {
  if (!runtimeAvailable()) {
    retireBridge();
    return false;
  }

  try {
    chrome.runtime.sendMessage(message);
    return true;
  } catch {
    retireBridge();
    return false;
  }
}

function publishElement(element) {
  if (!isUsableMedia(element)) {
    sendRuntimeMessage({
      type: "keywayMediaGone",
      documentID,
      mediaId: mediaIdFor(element),
      pageTitle: document.title || "",
      url: location.href || "",
    });
    return;
  }

  const metadata = navigator.mediaSession?.metadata;
  const hasMediaSessionMetadata = Boolean(metadata && (metadata.title || metadata.artist || metadata.album));
  sendRuntimeMessage({
    type: "keywayMediaState",
    documentID,
    mediaId: mediaIdFor(element),
    title: metadata?.title || element.getAttribute("title") || element.getAttribute("aria-label") || document.title || "",
    artist: metadata?.artist || "",
    album: metadata?.album || "",
    pageTitle: document.title || "",
    url: location.href || "",
    playing: !element.paused && !element.ended,
    muted: element.muted,
    volume: element.volume,
    duration: element.duration,
    elapsedTime: element.currentTime,
    hasMediaSessionMetadata,
    supportedCommands: supportedCommands(),
  });
}

function publishAll() {
  for (const element of mediaElements()) publishElement(element);
}

function commandTarget(mediaId) {
  return mediaElements().find(element => mediaIdFor(element) === mediaId);
}

function applyCommand(message) {
  if (message.documentID !== documentID) {
    return Promise.resolve({ ok: false, message: "Media document is no longer available." });
  }

  const element = commandTarget(message.mediaId);
  if (!element) {
    return Promise.resolve({ ok: false, message: "Media element is no longer available." });
  }

  if (message.command === "play") {
    return element.play().then(() => ({ ok: true, message: "playing" }));
  }

  if (message.command === "pause") {
    element.pause();
    return Promise.resolve({ ok: true, message: "paused" });
  }

  if (message.command === "playPause") {
    if (element.paused || element.ended) {
      return element.play().then(() => ({ ok: true, message: "playing" }));
    }
    element.pause();
    return Promise.resolve({ ok: true, message: "paused" });
  }

  if (message.command === "mute") {
    element.muted = !element.muted;
    return Promise.resolve({ ok: true, message: element.muted ? "muted" : "unmuted" });
  }

  if (message.command === "volumeDelta") {
    element.volume = Math.max(0, Math.min(1, element.volume + message.volumeDelta));
    return Promise.resolve({ ok: true, message: `volume ${Math.round(element.volume * 100)}` });
  }

  if (message.command === "next" || message.command === "previous") {
    const control = trackControl(message.command);
    if (!control) {
      return Promise.resolve({ ok: false, unsupported: true, message: `${message.command} is unsupported for this Chromium page.` });
    }
    control.click();
    return Promise.resolve({ ok: true, message: message.command });
  }

  return Promise.resolve({ ok: false, unsupported: true, message: `${message.command} is unsupported for this Chromium media element.` });
}

function observeElement(element) {
  if (element.dataset.keywayObserved === "true") return;
  element.dataset.keywayObserved = "true";
  for (const eventName of ["play", "pause", "volumechange", "durationchange", "timeupdate", "loadedmetadata", "emptied", "abort", "ended"]) {
    element.addEventListener(eventName, () => publishElement(element), { passive: true });
  }
  publishElement(element);
}

const observer = new MutationObserver(() => {
  for (const element of mediaElements()) observeElement(element);
});

if (!runtimeAvailable()) {
  retireBridge();
} else {
  chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
    if (message.type === "keywayProbeMedia") {
      publishAll();
      sendResponse({ ok: true });
      return false;
    }

    if (message.type !== "keywayCommand") return false;
    applyCommand(message).then(response => {
      publishAll();
      sendResponse(response);
    }).catch(() => {
      publishAll();
      sendResponse({
        ok: false,
        message: "Chromium media command failed.",
      });
    });
    return true;
  });

  observer.observe(document.documentElement, { childList: true, subtree: true });
  publishTimer = setInterval(publishAll, 1000);
  publishAll();
}
}
