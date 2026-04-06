// WhatsApp Web Translator — Content Script
// Observes chat messages and translates them via the background service worker.

(function () {
  'use strict';

  const LOG_PREFIX = '[WA Translator]';
  const ATTR_ORIGINAL = 'data-wa-original';
  const ATTR_STATE = 'data-wa-state'; // 'pending' | 'done'
  const CLASS_TRANSLATED = 'wa-translator-translated';
  const CLASS_PENDING = 'wa-translator-pending';

  // In-memory cache: original text -> translated text
  const cache = new Map();

  // Rate limiting: max concurrent API calls
  const MAX_CONCURRENT = 3;
  let activeRequests = 0;
  const pendingQueue = [];

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
      console.log(LOG_PREFIX, 'Settings loaded:', { ...settings, apiKey: settings.apiKey ? '***set***' : '(empty)' });
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
    console.log(LOG_PREFIX, 'Settings changed:', Object.keys(changes).join(', '));
    if (changes.enabled) {
      if (settings.enabled) {
        console.log(LOG_PREFIX, 'Translation enabled — scanning messages');
        translateVisible();
      } else {
        console.log(LOG_PREFIX, 'Translation disabled — reverting messages');
        revertAll();
      }
    }
  });

  loadSettings();

  // ---- DOM helpers ----

  // Get the translatable text elements from message bubbles.
  // WhatsApp frequently changes class names, so we use multiple strategies
  // anchored on the most stable attributes.
  function getMessageElements() {
    const results = [];
    const seen = new WeakSet();

    // Primary strategy: [data-pre-plain-text] is a stable attribute on
    // the copyable-text div wrapping each message's text content.
    // Find the first span[dir] inside each — that's the text container.
    const copyables = document.querySelectorAll(
      'div.message-in [data-pre-plain-text], div.message-out [data-pre-plain-text]'
    );

    for (const container of copyables) {
      const textSpan = container.querySelector('span[dir]');
      if (textSpan && !seen.has(textSpan)) {
        seen.add(textSpan);
        results.push(textSpan);
      }
    }

    if (results.length > 0) return results;

    // Fallback: copyable-text class without data-pre-plain-text
    const fallback = document.querySelectorAll(
      'div.message-in div.copyable-text span[dir], div.message-out div.copyable-text span[dir]'
    );

    for (const span of fallback) {
      // Only take the first span[dir] per copyable-text parent
      const parent = span.closest('div.copyable-text');
      if (parent && !seen.has(parent)) {
        seen.add(parent);
        results.push(span);
      }
    }

    return results;
  }

  // Extract the visible text from a span while preserving structure info.
  // Uses textContent to avoid layout thrashing from innerText.
  function getTextContent(span) {
    return span.textContent.trim();
  }

  // Replace text nodes inside a span without destroying child elements (emoji, links, etc).
  // Walks the DOM tree and replaces text node contents.
  function replaceTextContent(span, newText) {
    const textNodes = [];
    const walker = document.createTreeWalker(span, NodeFilter.SHOW_TEXT, null, false);
    let node;
    while ((node = walker.nextNode())) {
      if (node.textContent.trim()) {
        textNodes.push(node);
      }
    }

    if (textNodes.length === 0) {
      // Fallback: no text nodes found, set directly
      span.textContent = newText;
      return;
    }

    if (textNodes.length === 1) {
      // Single text node — simple replacement
      textNodes[0].textContent = newText;
      return;
    }

    // Multiple text nodes: put all translated text in the first node,
    // clear the rest. This handles cases where text is split across
    // formatting spans (bold, italic, etc).
    textNodes[0].textContent = newText;
    for (let i = 1; i < textNodes.length; i++) {
      textNodes[i].textContent = '';
    }
  }

  // ---- Queue / Rate Limiting ----

  function enqueueTranslation(span, text) {
    if (activeRequests < MAX_CONCURRENT) {
      executeTranslation(span, text);
    } else {
      pendingQueue.push({ span, text });
    }
  }

  function drainQueue() {
    while (activeRequests < MAX_CONCURRENT && pendingQueue.length > 0) {
      const { span, text } = pendingQueue.shift();
      // Check the span is still in the DOM and still pending
      if (span.isConnected && span.getAttribute(ATTR_STATE) === 'pending') {
        executeTranslation(span, text);
      }
    }
  }

  function executeTranslation(span, text) {
    activeRequests++;

    chrome.runtime.sendMessage(
      {
        type: 'translate',
        text: text,
        sourceLang: settings.sourceLang,
        apiKey: settings.apiKey,
        model: settings.model
      },
      (response) => {
        activeRequests--;
        span.classList.remove(CLASS_PENDING);

        if (chrome.runtime.lastError) {
          console.warn(LOG_PREFIX, 'Runtime error:', chrome.runtime.lastError.message);
          span.removeAttribute(ATTR_STATE);
          span.removeAttribute(ATTR_ORIGINAL);
          drainQueue();
          return;
        }

        if (!response || response.error) {
          console.warn(LOG_PREFIX, 'API error:', response?.error || 'no response');
          span.removeAttribute(ATTR_STATE);
          span.removeAttribute(ATTR_ORIGINAL);
          drainQueue();
          return;
        }

        console.log(LOG_PREFIX, 'Translated:', text.substring(0, 40), '->', response.translated.substring(0, 40));
        cache.set(text, response.translated);

        // Only apply if still enabled
        if (settings.enabled && span.isConnected) {
          applyTranslation(span, text, response.translated);
        } else {
          span.removeAttribute(ATTR_STATE);
          span.removeAttribute(ATTR_ORIGINAL);
        }

        drainQueue();
      }
    );
  }

  // ---- Translation ----

  function translateSpan(span) {
    // Skip if already handled
    if (span.getAttribute(ATTR_STATE)) return;

    const text = getTextContent(span);
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

    enqueueTranslation(span, text);
  }

  function applyTranslation(span, original, translated) {
    if (!span.getAttribute(ATTR_ORIGINAL)) {
      span.setAttribute(ATTR_ORIGINAL, original);
    }
    span.setAttribute(ATTR_STATE, 'done');
    span.classList.add(CLASS_TRANSLATED);
    // Only replace if different
    if (translated !== original) {
      replaceTextContent(span, translated);
    }
  }

  function revertSpan(span) {
    const original = span.getAttribute(ATTR_ORIGINAL);
    if (original !== null) {
      replaceTextContent(span, original);
    }
    span.removeAttribute(ATTR_STATE);
    span.removeAttribute(ATTR_ORIGINAL);
    span.classList.remove(CLASS_TRANSLATED, CLASS_PENDING);
  }

  function translateVisible() {
    if (!settings.enabled || !settings.apiKey) {
      console.log(LOG_PREFIX, 'Skipping: enabled =', settings.enabled, ', apiKey =', settings.apiKey ? 'set' : 'empty');
      return;
    }
    const elements = getMessageElements();
    console.log(LOG_PREFIX, 'Found', elements.length, 'message elements');
    elements.forEach((el) => translateSpan(el));
  }

  function revertAll() {
    const translated = document.querySelectorAll('[' + ATTR_STATE + ']');
    console.log(LOG_PREFIX, 'Reverting', translated.length, 'messages');
    translated.forEach((span) => revertSpan(span));
    // Clear pending queue
    pendingQueue.length = 0;
  }

  // ---- MutationObserver ----
  // WhatsApp dynamically loads messages; we watch for new ones.

  let debounceTimer = null;

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
      clearTimeout(debounceTimer);
      debounceTimer = setTimeout(translateVisible, 200);
    }
  });

  // Start observing. We watch body initially; WhatsApp may not have
  // rendered the chat panel yet.
  observer.observe(document.body, { childList: true, subtree: true });

  // Run on initial load after WhatsApp renders
  setTimeout(translateVisible, 3000);
  // Second attempt in case WhatsApp was slow to load
  setTimeout(translateVisible, 6000);

  console.log(LOG_PREFIX, 'Content script loaded and observing');
})();
