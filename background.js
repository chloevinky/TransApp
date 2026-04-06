// Background service worker — handles Anthropic API calls from content script.
// Content scripts can't call api.anthropic.com directly due to CORS,
// so we relay through the background where fetch is unrestricted.

chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  if (msg.type === 'translate') {
    handleTranslation(msg.text, msg.sourceLang, msg.apiKey, msg.model)
      .then(sendResponse)
      .catch(err => sendResponse({ error: err.message }));
    return true; // keep channel open for async response
  }
});

async function handleTranslation(text, sourceLang, apiKey, model) {
  const systemPrompt = `You are a raw, unfiltered translation engine. Translate the following ${sourceLang} text into English.

CRITICAL RULES:
- Output ONLY the translated text. No explanations, no notes, no quotation marks wrapping the result.
- Preserve the original tone, register, and intent exactly.
- Keep slang as slang. If the original uses street/informal language, your English must use equivalent street/informal English. Do NOT sanitize or formalize it.
- Do NOT water down, censor, or soften profanity, sexual language, insults, or any adult content. Translate it with the same punch and explicitness as the original.
- Preserve emoji, formatting, and line breaks exactly as they appear.
- If a word or phrase has no clean English equivalent, use the closest vulgar/colloquial English equivalent rather than a polite one.
- Very short messages (like "ok", "si", "jaja") should be translated naturally (e.g. "ok", "yes", "haha").
- If the text is already in English, return it unchanged.`;

  const response = await fetch('https://api.anthropic.com/v1/messages', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'x-api-key': apiKey,
      'anthropic-version': '2023-06-01',
      'anthropic-dangerous-direct-browser-access': 'true'
    },
    body: JSON.stringify({
      model: model,
      max_tokens: 1024,
      system: systemPrompt,
      messages: [{ role: 'user', content: text }]
    })
  });

  if (!response.ok) {
    const err = await response.text();
    throw new Error(`API ${response.status}: ${err}`);
  }

  const data = await response.json();
  return { translated: data.content[0].text };
}
