/**
 * MSAL configuration.
 *
 * Values are injected at build time via Vite env vars (VITE_*). The
 * Dockerfile sets them from build args; locally you can put them in a
 * .env.local file (gitignored).
 *
 * Required env vars (set via Dockerfile ARG or .env):
 *   VITE_SPA_CLIENT_ID    — Entra app reg ID for the SPA
 *   VITE_TENANT_ID        — Your tenant ID
 *   VITE_N8N_API_SCOPE    — Full scope URI, e.g. api://9d3936a5-.../access_as_user
 *   VITE_REDIRECT_URI     — Where Entra redirects after login (must match app reg)
 *
 * We DON'T put any secrets here — this is a public client (SPA with PKCE).
 */
import { Configuration, PopupRequest } from "@azure/msal-browser";

const tenantId = import.meta.env.VITE_TENANT_ID as string;
const clientId = import.meta.env.VITE_SPA_CLIENT_ID as string;
const redirectUri = import.meta.env.VITE_REDIRECT_URI as string;
export const n8nApiScope = import.meta.env.VITE_N8N_API_SCOPE as string;

if (!tenantId || !clientId || !redirectUri || !n8nApiScope) {
  // Surface a clear error rather than the silent failures MSAL gives.
  // eslint-disable-next-line no-console
  console.error("MSAL config missing. Required VITE_* env vars:", {
    VITE_TENANT_ID: tenantId,
    VITE_SPA_CLIENT_ID: clientId,
    VITE_REDIRECT_URI: redirectUri,
    VITE_N8N_API_SCOPE: n8nApiScope,
  });
}

export const msalConfig: Configuration = {
  auth: {
    clientId,
    authority: `https://login.microsoftonline.com/${tenantId}`,
    redirectUri,
    postLogoutRedirectUri: redirectUri,
    navigateToLoginRequestUrl: false,
  },
  cache: {
    cacheLocation: "sessionStorage",
    storeAuthStateInCookie: false,
  },
};

// Scope we request when the user clicks "Sign in". Just openid/profile here;
// we acquire the n8n-api scope on demand via acquireTokenSilent below.
export const loginRequest: PopupRequest = {
  scopes: ["openid", "profile", "User.Read"],
};

// Scope we acquire silently before calling the n8n webhook.
export const apiTokenRequest = {
  scopes: [n8nApiScope],
};
