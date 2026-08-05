export class DocumentAuthorityRegistry {
  constructor() {
    this.generation = 0;
    this.authorityByFrame = new Map();
    this.retiredBrowserDocumentIDs = new Set();
  }

  frameKey(tabId, frameId) {
    return `${tabId}:${frameId}`;
  }

  authority(tabId, frameId) {
    const authority = this.authorityByFrame.get(this.frameKey(tabId, frameId));
    return authority ? { ...authority } : null;
  }

  establish(tabId, frameId, browserDocumentID) {
    this.generation += 1;
    const authority = {
      tabId,
      frameId,
      browserDocumentID,
      contentDocumentID: null,
      generation: this.generation,
    };
    this.authorityByFrame.set(this.frameKey(tabId, frameId), authority);
    return { ...authority };
  }

  activateCommitted(tabId, frameId, browserDocumentID) {
    this.retiredBrowserDocumentIDs.delete(browserDocumentID);
    return this.establish(tabId, frameId, browserDocumentID);
  }

  reactivateRetired(tabId, frameId, browserDocumentID) {
    if (this.authorityByFrame.has(this.frameKey(tabId, frameId))) return null;
    if (!this.retiredBrowserDocumentIDs.delete(browserDocumentID)) return null;
    return this.establish(tabId, frameId, browserDocumentID);
  }

  retire(authority) {
    const key = this.frameKey(authority.tabId, authority.frameId);
    const current = this.authorityByFrame.get(key);
    if (!current || current.generation !== authority.generation) return false;
    this.retiredBrowserDocumentIDs.add(current.browserDocumentID);
    this.authorityByFrame.delete(key);
    return true;
  }

  retireTab(tabId) {
    for (const authority of Array.from(this.authorityByFrame.values())) {
      if (authority.tabId === tabId) this.retire(authority);
    }
  }

  capture(sender, contentDocumentID) {
    const tabId = sender.tab?.id;
    const frameId = sender.frameId;
    const browserDocumentID = sender.documentId;
    if (!Number.isInteger(tabId)
        || !Number.isInteger(frameId)
        || typeof browserDocumentID !== "string"
        || !browserDocumentID
        || typeof contentDocumentID !== "string"
        || !contentDocumentID
        || this.retiredBrowserDocumentIDs.has(browserDocumentID)) {
      return null;
    }

    const key = this.frameKey(tabId, frameId);
    const authority = this.authorityByFrame.get(key)
      || this.establish(tabId, frameId, browserDocumentID);
    const current = this.authorityByFrame.get(key) || authority;
    if (current.browserDocumentID !== browserDocumentID) return null;
    if (current.contentDocumentID && current.contentDocumentID !== contentDocumentID) return null;
    current.contentDocumentID = contentDocumentID;
    return { ...current };
  }

  current(sender, contentDocumentID) {
    const tabId = sender.tab?.id;
    const frameId = sender.frameId;
    if (!Number.isInteger(tabId) || !Number.isInteger(frameId)) return null;
    const authority = this.authorityByFrame.get(this.frameKey(tabId, frameId));
    if (!authority
        || authority.browserDocumentID !== sender.documentId
        || authority.contentDocumentID !== contentDocumentID) {
      return null;
    }
    return { ...authority };
  }

  isCurrent(authority) {
    const current = this.authorityByFrame.get(this.frameKey(authority.tabId, authority.frameId));
    return Boolean(
      current
      && current.generation === authority.generation
      && current.browserDocumentID === authority.browserDocumentID
      && current.contentDocumentID === authority.contentDocumentID
    );
  }
}
