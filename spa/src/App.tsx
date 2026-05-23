import { useState } from "react";
import { useMsal, useIsAuthenticated, AuthenticatedTemplate, UnauthenticatedTemplate } from "@azure/msal-react";
import { InteractionRequiredAuthError } from "@azure/msal-browser";
import { loginRequest, apiTokenRequest } from "./authConfig";

interface ChatMessage {
  role: "user" | "assistant" | "error";
  content: string;
}

/**
 * The chat UI.
 *
 * Architecture:
 *   1. User clicks "Sign in" -> MSAL popup -> Entra login -> account in cache
 *   2. User types a message + Send:
 *      a. acquireTokenSilent for the n8n-api scope
 *      b. POST /webhook/chat with Authorization: Bearer <token>
 *      c. n8n workflow validates the JWT, fetches an AOAI token via its
 *         workload identity, calls AOAI, returns the assistant message
 *   3. Append the response to the message list
 *
 * No tokens in localStorage; MSAL uses sessionStorage by default.
 */
export function App() {
  const { instance, accounts } = useMsal();
  const isAuthenticated = useIsAuthenticated();
  const [messages, setMessages] = useState<ChatMessage[]>([]);
  const [input, setInput] = useState("");
  const [busy, setBusy] = useState(false);

  const account = accounts[0];
  const displayName = account?.name ?? account?.username ?? "user";

  async function getApiToken(): Promise<string> {
    if (!account) throw new Error("not signed in");
    try {
      const result = await instance.acquireTokenSilent({
        ...apiTokenRequest,
        account,
      });
      return result.accessToken;
    } catch (err) {
      // Cache miss / token expired -> fall back to interactive popup.
      if (err instanceof InteractionRequiredAuthError) {
        const result = await instance.acquireTokenPopup(apiTokenRequest);
        return result.accessToken;
      }
      throw err;
    }
  }

  async function send() {
    const text = input.trim();
    if (!text || busy) return;
    setInput("");
    setMessages((m) => [...m, { role: "user", content: text }]);
    setBusy(true);
    try {
      const token = await getApiToken();
      const res = await fetch("/webhook/chat", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${token}`,
        },
        body: JSON.stringify({ message: text }),
      });
      if (!res.ok) {
        const errText = await res.text();
        setMessages((m) => [...m, { role: "error", content: `HTTP ${res.status}: ${errText.slice(0, 200)}` }]);
        return;
      }
      const data = await res.json();
      const reply = data?.reply ?? data?.message ?? JSON.stringify(data);
      setMessages((m) => [...m, { role: "assistant", content: reply }]);
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      setMessages((m) => [...m, { role: "error", content: msg }]);
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="app">
      <header>
        <h1>DSO Lab — Chat</h1>
        <AuthenticatedTemplate>
          <div className="user">
            <span>{displayName}</span>
            <button onClick={() => instance.logoutPopup({ account })}>Sign out</button>
          </div>
        </AuthenticatedTemplate>
      </header>

      <UnauthenticatedTemplate>
        <div className="login-card">
          <p>Sign in with your Microsoft Entra account to start chatting.</p>
          <button onClick={() => instance.loginPopup(loginRequest)}>Sign in with Microsoft</button>
        </div>
      </UnauthenticatedTemplate>

      <AuthenticatedTemplate>
        <div className="messages" role="log" aria-live="polite">
          {messages.length === 0 && <p className="hint">Say hi 👋</p>}
          {messages.map((m, i) => (
            <div key={i} className={`msg ${m.role}`}>
              <span className="role">{m.role}</span>
              <span className="content">{m.content}</span>
            </div>
          ))}
        </div>
        <form
          className="composer"
          onSubmit={(e) => {
            e.preventDefault();
            void send();
          }}
        >
          <input
            value={input}
            onChange={(e) => setInput(e.target.value)}
            placeholder={busy ? "Thinking…" : "Type a message"}
            disabled={busy}
            autoFocus
          />
          <button type="submit" disabled={busy || !input.trim()}>
            Send
          </button>
        </form>
      </AuthenticatedTemplate>

      <footer>
        Routed via NGINX → oauth2-proxy → n8n → Azure OpenAI (gpt-4o, AUE).
        Workload identity for AOAI auth. No API keys.
      </footer>
    </div>
  );
}
