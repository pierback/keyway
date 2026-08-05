if (globalThis.__keywayMediaBridgeRevision !== 2) {
globalThis.__keywayMediaBridgeRevision = 2;

const documentID = crypto.getRandomValues(new Uint32Array(4)).join("-");
const keywayMedia = new WeakMap();
const observedMedia = new WeakSet();
let nextMediaIndex = 1;
let bridgeActive = true;
let publishTimer = null;
const baseSupportedCommands = ["play", "pause", "playPause", "mute", "volumeDelta"];
const playbackControlSelectors = {
  play: [
    'button[aria-label="Play" i]',
    'button[aria-label="Playbar: Play button" i]',
    '[role="button"][aria-label="Play" i]',
    'button[aria-label="Abspielen" i]',
    '[role="button"][aria-label="Abspielen" i]',
    'button[aria-label*="play video" i]',
    '[role="button"][aria-label*="play video" i]',
    'button[aria-label*="start playback" i]',
    '[role="button"][aria-label*="start playback" i]',
    'button[title="Play" i]',
    'button[title="Abspielen" i]',
    'button[title*="play video" i]',
    'button[title*="start playback" i]',
    '[data-testid="play" i]',
    '[data-testid*="play-button" i]',
    '[data-testid*="play_button" i]',
    ".vjs-play-control",
    ".jw-icon-playback",
    ".shaka-play-button",
    ".bmpui-ui-playbacktogglebutton",
  ],
  pause: [
    'button[aria-label="Pause" i]',
    'button[aria-label="Playbar: Pause button" i]',
    '[role="button"][aria-label="Pause" i]',
    'button[aria-label="Pausieren" i]',
    '[role="button"][aria-label="Pausieren" i]',
    'button[aria-label*="pause video" i]',
    '[role="button"][aria-label*="pause video" i]',
    'button[aria-label*="pause playback" i]',
    '[role="button"][aria-label*="pause playback" i]',
    'button[title="Pause" i]',
    'button[title="Pausieren" i]',
    'button[title*="pause video" i]',
    'button[title*="pause playback" i]',
    '[data-testid="pause" i]',
    '[data-testid*="pause-button" i]',
    '[data-testid*="pause_button" i]',
    ".vjs-play-control",
    ".jw-icon-playback",
    ".shaka-play-button",
    ".bmpui-ui-playbacktogglebutton",
  ],
  playPause: [
    '[aria-label*="play/pause" i]',
    '[aria-label*="play pause" i]',
    '[aria-label*="play-pause" i]',
    '[aria-label*="wiedergabe stoppen" i]',
    '[aria-label*="wiedergabe starten" i]',
    '[title*="play/pause" i]',
    '[title*="play pause" i]',
    '[title*="play-pause" i]',
    '[title*="wiedergabe stoppen" i]',
    '[title*="wiedergabe starten" i]',
    '[data-testid*="play-pause" i]',
    '[data-testid*="play_pause" i]',
    '[data-testid*="playpause" i]',
  ],
};
const trackControlSelectors = {
  next: [
    'button[aria-label="Playbar: Next Song button" i]',
    '[data-testid="control-button-skip-forward"]',
    '[aria-label="Next"]',
    '[aria-label="Next track"]',
    '[title="Next"]',
    '[title="Next track"]',
    ".ytp-next-button",
  ],
  previous: [
    'button[aria-label="Playbar: Previous Song button" i]',
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

function scanPage() {
  const mediaElements = [];
  const roots = [];
  const visit = root => {
    roots.push(root);
    for (const element of root.querySelectorAll("video,audio")) {
      mediaElements.push(element);
    }
    for (const element of root.querySelectorAll("*")) {
      if (element.shadowRoot) visit(element.shadowRoot);
    }
  };

  visit(document);
  return { mediaElements, roots };
}

function querySelectorInRoots(roots, selector) {
  for (const root of roots) {
    if (typeof root.matches === "function" && root.matches(selector)) return root;
    const match = typeof root.querySelector === "function" ? root.querySelector(selector) : null;
    if (match) return match;
  }
  return null;
}

function isClickable(element) {
  if (!element || element.disabled || element.getAttribute("aria-disabled") === "true") return false;
  const rect = element.getBoundingClientRect();
  return rect.width > 0 && rect.height > 0;
}

function trackControl(command, roots) {
  const selectors = trackControlSelectors[command] || [];
  for (const selector of selectors) {
    const element = querySelectorInRoots(roots, selector);
    if (isClickable(element)) return element;
  }
  return null;
}

function playbackControl(command, element, page) {
  const commands = command === "playPause"
    ? (element.paused || element.ended ? ["play", "playPause"] : ["pause", "playPause"])
    : [command];
  let scope = element;
  while (scope) {
    for (const name of commands) {
      for (const selector of playbackControlSelectors[name] || []) {
        const control = querySelectorDeep(scope, selector);
        if (isClickable(control)) return control;
      }
    }
    const root = typeof scope.getRootNode === "function" ? scope.getRootNode() : null;
    scope = scope.parentElement || root?.host || null;
  }
  if (page.mediaElements.length !== 1) {
    return null;
  }
  for (const name of commands) {
    for (const selector of playbackControlSelectors[name] || []) {
      const control = querySelectorInRoots(page.roots, selector);
      if (isClickable(control)) return control;
    }
  }
  return null;
}

function querySelectorDeep(root, selector) {
  const roots = [root];
  while (roots.length) {
    const current = roots.shift();
    if (typeof current.matches === "function" && current.matches(selector)) return current;
    const match = typeof current.querySelector === "function" ? current.querySelector(selector) : null;
    if (match) return match;
    if (typeof current.querySelectorAll !== "function") continue;
    for (const element of current.querySelectorAll("*")) {
      if (element.shadowRoot) roots.push(element.shadowRoot);
    }
  }
  return null;
}

function supportedCommands(roots) {
  const commands = baseSupportedCommands.slice();
  if (trackControl("next", roots)) commands.push("next");
  if (trackControl("previous", roots)) commands.push("previous");
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

function retireIfExtensionContextInvalidated(error) {
  if (error?.message === "Extension context invalidated.") {
    retireBridge();
    return true;
  }
  return false;
}

function runBridgeTask(action) {
  if (!bridgeActive) return undefined;
  try {
    return action();
  } catch (error) {
    if (retireIfExtensionContextInvalidated(error)) return undefined;
    throw error;
  }
}

function retireBridge() {
  if (!bridgeActive) return;
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
    chrome.runtime.sendMessage(message, () => {
      retireIfExtensionContextInvalidated(chrome.runtime.lastError);
    });
    return true;
  } catch {
    retireBridge();
    return false;
  }
}

function publishElement(element, commands = null) {
  runBridgeTask(() => {
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
    const hasPlaybackActivity = hasMediaSessionMetadata
      || (!element.paused && !element.ended)
      || (Number.isFinite(element.currentTime) && element.currentTime > 0);
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
      volume: element.volume,
      duration: element.duration,
      elapsedTime: element.currentTime,
      hasMediaSessionMetadata,
      hasPlaybackActivity,
      supportedCommands: commands || supportedCommands(scanPage().roots),
    });
  });
}

function publishAll(page = null) {
  runBridgeTask(() => {
    const snapshot = page || scanPage();
    const commands = supportedCommands(snapshot.roots);
    for (const element of snapshot.mediaElements) publishElement(element, commands);
  });
}

function applyCommand(message) {
  if (message.documentID !== documentID) {
    return Promise.resolve({ ok: false, message: "Media document is no longer available." });
  }

  const page = runBridgeTask(scanPage);
  const element = page?.mediaElements.find(element => mediaIdFor(element) === message.mediaId);
  if (!element) {
    return Promise.resolve({ ok: false, message: "Media element is no longer available." });
  }

  if (message.command === "play") {
    if (!element.paused && !element.ended) {
      return Promise.resolve({ ok: true, message: "already playing" });
    }
    const control = playbackControl(message.command, element, page);
    if (control) {
      control.click();
      return Promise.resolve({ ok: true, message: "playing" });
    }
    return element.play().then(() => ({ ok: true, message: "playing" }));
  }

  if (message.command === "pause") {
    if (element.paused || element.ended) {
      return Promise.resolve({ ok: true, message: "already paused" });
    }
    const control = playbackControl(message.command, element, page);
    if (control) {
      control.click();
      return Promise.resolve({ ok: true, message: "paused" });
    }
    element.pause();
    return Promise.resolve({ ok: true, message: "paused" });
  }

  if (message.command === "playPause") {
    const control = playbackControl(message.command, element, page);
    if (control) {
      const wasPaused = element.paused || element.ended;
      control.click();
      return Promise.resolve({ ok: true, message: wasPaused ? "playing" : "paused" });
    }
    if (element.paused || element.ended) {
      return element.play().then(() => ({ ok: true, message: "playing" }));
    }
    element.pause();
    return Promise.resolve({ ok: true, message: "paused" });
  }

  if (message.command === "volumeDelta") {
    element.volume = Math.max(0, Math.min(1, element.volume + message.volumeDelta));
    return Promise.resolve({ ok: true, message: `volume ${Math.round(element.volume * 100)}` });
  }

  if (message.command === "next" || message.command === "previous") {
    const control = trackControl(message.command, page.roots);
    if (!control) {
      return Promise.resolve({ ok: false, unsupported: true, message: `${message.command} is unsupported for this Chromium page.` });
    }
    control.click();
    return Promise.resolve({ ok: true, message: message.command });
  }

  return Promise.resolve({ ok: false, unsupported: true, message: `${message.command} is unsupported for this Chromium media element.` });
}

function observeElement(element, commands = null) {
  if (observedMedia.has(element)) return;
  observedMedia.add(element);
  for (const eventName of ["play", "pause", "volumechange", "durationchange", "timeupdate", "loadedmetadata", "emptied", "abort", "ended"]) {
    element.addEventListener(eventName, () => publishElement(element), { passive: true });
  }
  publishElement(element, commands);
}

const observer = new MutationObserver(() => {
  runBridgeTask(() => {
    const page = scanPage();
    const commands = supportedCommands(page.roots);
    for (const element of page.mediaElements) observeElement(element, commands);
  });
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
    }).catch(error => {
      retireIfExtensionContextInvalidated(error);
      publishAll();
      sendResponse({
        ok: false,
        message: "Chromium media command failed.",
      });
    });
    return true;
  });

  observer.observe(document.documentElement, { childList: true, subtree: true });
  publishTimer = setInterval(() => {
    if (bridgeActive) publishAll();
  }, 1000);
  publishAll();
}
}
