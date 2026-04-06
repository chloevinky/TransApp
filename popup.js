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
    showStatus(enabledEl.checked ? 'Translation ON' : 'Translation OFF', enabledEl.checked);
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
      showStatus('API key is required', false);
      return;
    }

    chrome.storage.local.set(settings, () => {
      showStatus('Settings saved!', true);
    });
  });

  function showStatus(msg, success) {
    statusEl.textContent = msg;
    statusEl.className = 'status' + (success ? ' active' : '');
    setTimeout(() => { statusEl.textContent = ''; }, 2500);
  }
});
