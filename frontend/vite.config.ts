import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    fs: {
      // allow importing the generated deployments/31337.json from the repo root
      allow: ["..", "."],
    },
  },
});
