const keywayMedia = new WeakMap();
let nextMediaIndex = 1;

function mediaIdFor(element) {
  const existing = keywayMedia.get(element);
  if (existing) return existing;

  const id = `media-${nextMediaIndex}`;
  nextMediaIndex += 1;
  keywayMedia.set(element, id);
  return id;
}

function mediaElements() {
  return Array.from(document.querySelectorAll("video,audio"));
}

function isUsableMedia(element) {
  return !element.ended && element.readyState > 0 && (Number.isFinite(element.duration) ? element.duration > 0 : true);
}

function publishElement(element) {
  if (!isUsableMedia(element)) {
    chrome.runtime.sendMessage({ type: "keywayMediaGone", mediaId: mediaIdFor(element) });
    return;
  }

  chrome.runtime.sendMessage({
    type: "keywayMediaState",
    mediaId: mediaIdFor(element),
    title: navigator.mediaSession?.metadata?.title || document.title || "",
    artist: navigator.mediaSession?.metadata?.artist || "",
    playing: !element.paused && !element.ended,
    muted: element.muted,
    volume: element.volume,
    duration: element.duration,
    elapsedTime: element.currentTime,
  });
}

function publishAll() {
  for (const element of mediaElements()) publishElement(element);
}

function commandTarget(mediaId) {
  return mediaElements().find(element => mediaIdFor(element) === mediaId);
}

function applyCommand(message) {
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

  return Promise.resolve({ ok: false, unsupported: true, message: `${message.command} is unsupported for this Chromium media element.` });
}

function observeElement(element) {
  if (element.dataset.keywayObserved === "true") return;
  element.dataset.keywayObserved = "true";
  for (const eventName of ["play", "pause", "volumechange", "durationchange", "timeupdate", "loadedmetadata", "ended"]) {
    element.addEventListener(eventName, () => publishElement(element), { passive: true });
  }
  publishElement(element);
}

const observer = new MutationObserver(() => {
  for (const element of mediaElements()) observeElement(element);
});

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message.type !== "keywayCommand") return false;
  applyCommand(message).then(response => {
    publishAll();
    sendResponse(response);
  });
  return true;
});

observer.observe(document.documentElement, { childList: true, subtree: true });
setInterval(publishAll, 1000);
publishAll();
