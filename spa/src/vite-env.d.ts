/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly VITE_SPA_CLIENT_ID: string;
  readonly VITE_TENANT_ID: string;
  readonly VITE_N8N_API_SCOPE: string;
  readonly VITE_REDIRECT_URI: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
