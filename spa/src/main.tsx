import React from "react";
import ReactDOM from "react-dom/client";
import { PublicClientApplication, EventType } from "@azure/msal-browser";
import { MsalProvider } from "@azure/msal-react";
import { App } from "./App";
import { msalConfig } from "./authConfig";
import "./styles.css";

// Create the MSAL instance once and bootstrap it before render. This is
// required by MSAL v3 — without `await initialize()`, login flows may race.
const pca = new PublicClientApplication(msalConfig);

// Pick the first signed-in account as active so msal-react's hooks work.
pca.addEventCallback((event) => {
  if (event.eventType === EventType.LOGIN_SUCCESS && event.payload && "account" in event.payload) {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    pca.setActiveAccount((event.payload as any).account);
  }
});

void pca.initialize().then(() => {
  // If we already have an account from a previous session, mark it active.
  const accounts = pca.getAllAccounts();
  if (accounts.length > 0 && !pca.getActiveAccount()) {
    pca.setActiveAccount(accounts[0]);
  }

  ReactDOM.createRoot(document.getElementById("root")!).render(
    <React.StrictMode>
      <MsalProvider instance={pca}>
        <App />
      </MsalProvider>
    </React.StrictMode>,
  );
});
