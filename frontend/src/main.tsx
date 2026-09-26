import React from "react";
import ReactDOM from "react-dom/client";

import App from "./App";
import "./styles.css";
import { WalletProvider } from "./wallet";

ReactDOM.createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <WalletProvider>
      <App />
    </WalletProvider>
  </React.StrictMode>,
);
