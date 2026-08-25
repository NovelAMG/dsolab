const messagesEl = document.querySelector('#messages');
const form = document.querySelector('#chatForm');
const promptEl = document.querySelector('#prompt');
const systemPromptEl = document.querySelector('#systemPrompt');
const sendBtn = document.querySelector('#sendBtn');
const clearBtn = document.querySelector('#clearBtn');
const statusEl = document.querySelector('#status');

let conversation = [];

function addMessage(role, content) {
  conversation.push({ role, content });
  renderMessages();
}

function renderMessages() {
  messagesEl.innerHTML = '';
  for (const message of conversation.filter((item) => item.role !== 'system')) {
    const article = document.createElement('article');
    article.className = `message ${message.role}`;

    const role = document.createElement('span');
    role.className = 'role';
    role.textContent = message.role;

    const content = document.createElement('div');
    content.textContent = message.content;

    article.append(role, content);
    messagesEl.append(article);
  }
  messagesEl.scrollTop = messagesEl.scrollHeight;
}

async function checkHealth() {
  try {
    const response = await fetch('/api/health');
    const health = await response.json();
    statusEl.textContent = health.endpoint_configured && health.deployment_configured
      ? `Service ready (${health.auth_mode})`
      : 'Service missing Foundry/Azure OpenAI environment config';
  } catch {
    statusEl.textContent = 'Service health check failed';
  }
}

async function sendPrompt(prompt) {
  const system = systemPromptEl.value.trim();
  const payload = {
    messages: [
      ...(system ? [{ role: 'system', content: system }] : []),
      ...conversation,
      { role: 'user', content: prompt },
    ],
  };

  const response = await fetch('/api/chat', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload),
  });

  if (!response.ok) {
    const error = await response.json().catch(() => ({ detail: response.statusText }));
    throw new Error(error.detail || 'Request failed');
  }

  return response.json();
}

form.addEventListener('submit', async (event) => {
  event.preventDefault();
  const prompt = promptEl.value.trim();
  if (!prompt) return;

  promptEl.value = '';
  addMessage('user', prompt);
  sendBtn.disabled = true;

  try {
    const result = await sendPrompt(prompt);
    addMessage('assistant', result.reply);
  } catch (error) {
    addMessage('assistant', `Request failed: ${error.message}`);
  } finally {
    sendBtn.disabled = false;
    promptEl.focus();
  }
});

clearBtn.addEventListener('click', () => {
  conversation = [];
  renderMessages();
  promptEl.focus();
});

checkHealth();
