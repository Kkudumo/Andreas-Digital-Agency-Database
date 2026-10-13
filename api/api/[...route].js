// Vercel function: every request to /api/... (and /health, via vercel.json) is served by the same handler
// as the long-running server. The handler is compiled from src/ by `npm run build` before deployment.
export { handle as default } from '../dist/app.js';
