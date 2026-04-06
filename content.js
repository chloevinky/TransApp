// WhatsApp Web Translator — Content Script
// Observes chat messages and translates them via the background service worker.

(function () {
  'use strict';

  const ATTR_ORIGINAL = 'data-wa-original';
  const ATTR_STATE = 'data-wa-state'; // 'pending' | 'done'
  const CLASS_TRANSLATED = 'wa-translator-translated';
  const CLASS_PENDING = 'wa-translator-pending';

  // In-memory cache: original text -> translated text
  const cache = new Map();

  let settings = {
    enabled: false,
    sourceLang: 'Spanish',
    apiKey: '',
    model: 'claude-sonnet-4-6'
  };

  // ---- Settings ----

  function loadSettings() {
    chrome.storage.local.get(settings, (data) => {
      const wasEnabled = settings.enabled;
      Object.assign(settings, data);
      if (settings.enabled && !wasEnabled) {
        translateVisible();
      } else if (!settings.enabled && wasEnabled) {
        revertAll();
      }
    });
  }

  chrome.storage.onChanged.addListener((changes) => {
    for (const key of Object.keys(changes)) {
      settings[key] = changes[key].newValue;
    }
    if (changes.enabled) {
      if (settings.enabled) {
        translateVisible();
      } else {
        revertAll();
      }
    }
  });

  loadSettings();

  // ---- DOM helpers ----

  // WhatsApp renders message text inside spans with specific selectors.
  // The main text content lives in spans inside message bubbles.
  function getMessageSpans() {
    // Primary selector: copyable text spans within message bubbles
    return document.querySelectorAll(
      'div.message-in span.selectable-text span, div.message-out span.selectable-text span'
    );
  }

  // ---- Translation ----

  function translateSpan(span) {
    // Skip if already handled or empty
    if (span.getAttribute(ATTR_STATE)) return;
    const text = span.innerText.trim();
    if (!text || text.length < 2) return;

    // Check cache first
    if (cache.has(text)) {
      applyTranslation(span, text, cache.get(text));
      return;
    }

    // Mark as pending
    span.setAttribute(ATTR_STATE, 'pending');
    span.setAttribute(ATTR_ORIGINAL, text);
    span.classList.add(CLASS_PENDING);

    chrome.runtime.sendMessage(
      {
        type: 'translate',
        text: text,
        sourceLang: settings.sourceLang,
        apiKey: settings.apiKey,
        model: settings.model
      },
      (response) => {
        span.classList.remove(CLASS_PENDING);

        if (chrome.runtime.lastError || !response || response.error) {
          // Failed — clean up state so it can retry later
          span.removeAttribute(ATTR_STATE);
          span.removeAttribute(ATTR_ORIGINAL);
          console.warn('[WA Translator]', response?.error || chrome.runtime.lastError?.message);
          return;
        }

        cache.set(text, response.translated);
        // Only apply if still enabled (user may have toggled off while waiting)
        if (settings.enabled) {
          applyTranslation(span, text, response.translated);
        } else {
          span.removeAttribute(ATTR_STATE);
          span.removeAttribute(ATTR_ORIGINAL);
        }
      }
    );
  }

  function applyTranslation(span, original, translated) {
    if (!span.getAttribute(ATTR_ORIGINAL)) {
      span.setAttribute(ATTR_ORIGINAL, original);
    }
    span.setAttribute(ATTR_STATE, 'done');
    span.classList.add(CLASS_TRANSLATED);
    // Only replace if different
    if (translated !== original) {
      span.innerText = translated;
    }
  }

  function revertSpan(span) {
    const original = span.getAttribute(ATTR_ORIGINAL);
    if (original !== null) {
      span.innerText = original;
    }
    span.removeAttribute(ATTR_STATE);
    span.removeAttribute(ATTR_ORIGINAL);
    span.classList.remove(CLASS_TRANSLATED, CLASS_PENDING);
  }

  function translateVisible() {
    if (!settings.enabled || !settings.apiKey) return;
    const spans = getMessageSpans();
    spans.forEach((span) => translateSpan(span));
  }

  function revertAll() {
    const translated = document.querySelectorAll(`[${ATTR_STATE}]`);
    translated.forEach((span) => revertSpan(span));
  }

  // ---- MutationObserver ----
  // WhatsApp dynamically loads messages; we watch for new ones.

  const observer = new MutationObserver((mutations) => {
    if (!settings.enabled || !settings.apiKey) return;

    let hasNewNodes = false;
    for (const mutation of mutations) {
      if (mutation.addedNodes.length > 0) {
        hasNewNodes = true;
        break;
      }
    }

    if (hasNewNodes) {
      // Debounce slightly to batch rapid DOM changes
      clearTimeout(observer._timer);
      observer._timer = setTimeout(translateVisible, 150);
    }
  });

  observer.observe(document.body, { childList: true, subtree: true });

  // Also run on initial load after a brief delay for WhatsApp to render
  setTimeout(translateVisible, 2000);
})();
