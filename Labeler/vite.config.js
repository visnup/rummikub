import labeler from "./server.js";

// On the local network too, so the phone can push captures.
export default {
  plugins: [labeler()],
  server: { port: 8765, strictPort: true, host: true, allowedHosts: ["box.localdomain"] },
};
