const defaults = {
  enabled: false,
  sourceLang: 'Spanish',
  apiKey: '',
  model: 'claude-sonnet-4-6'
};

document.addEventListener('DOMContentLoaded', () => {
  const enabledEl = document.getElementById('enabled');
  const sourceLangEl = document.getElementById('sourceLang');
  const apiKeyEl = document.getElementById('apiKey');
  const modelEl = document.getElementById('model');
  const saveBtn = document.getElementById('saveBtn');
  const testBtn = document.getElementById('testBtn');
  const statusEl = document.getElementById('status');

  // Load saved settings
  chrome.storage.local.get(defaults, (data) => {
    enabledEl.checked = data.enabled;
    sourceLangEl.value = data.sourceLang;
    apiKeyEl.value = data.apiKey;
    modelEl.value = data.model || defaults.model;
  });

  // Toggle fires immediately
  enabledEl.addEventListener('change', () => {
    chrome.storage.local.set({ enabled: enabledEl.checked });
    showStatus(enabledEl.checked ? 'Translation ON' : 'Translation OFF', 'active');
  });

  // Save all settings
  saveBtn.addEventListener('click', () => {
    const settings = {
      enabled: enabledEl.checked,
      sourceLang: sourceLangEl.value,
      apiKey: apiKeyEl.value.trim(),
      model: modelEl.value.trim() || defaults.model
    };

    if (!settings.apiKey) {
      showStatus('API key is required', 'error');
      return;
    }

    chrome.storage.local.set(settings, () => {
      showStatus('Settings saved!', 'active');
    });
  });

  // Test API connection
  testBtn.addEventListener('click', () => {
    const apiKey = apiKeyEl.value.trim();
    const model = modelEl.value.trim() || defaults.model;

    if (!apiKey) {
      showStatus('Enter an API key first', 'error');
      return;
    }

    showStatus('Testing...', '');
    testBtn.disabled = true;

    chrome.runtime.sendMessage(
      {
        type: 'translate',
        text: 'Hola, esto es una prueba.',
        sourceLang: 'Spanish',
        apiKey: apiKey,
        model: model
      },
      (response) => {
        testBtn.disabled = false;
        if (chrome.runtime.lastError) {
          showStatus('Error: ' + chrome.runtime.lastError.message, 'error');
          return;
        }
        if (!response) {
          showStatus('No response from background script', 'error');
          return;
        }
        if (response.error) {
          showStatus('API Error: ' + response.error.substring(0, 80), 'error');
          return;
        }
        showStatus('API works! Got: "' + response.translated + '"', 'active');
      }
    );
  });

  function showStatus(msg, type) {
    statusEl.textContent = msg;
    statusEl.className = 'status' + (type ? ' ' + type : '');
    if (type !== 'error') {
      setTimeout(() => { statusEl.textContent = ''; }, 4000);
    }
  }
});
