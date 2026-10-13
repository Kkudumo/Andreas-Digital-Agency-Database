// Vercel's catch-all file only matches one path segment, so /api/public/<name> and
// /api/public/<name>/<id> get their own entry points. All of them run the same handler.
export { handle as default } from '../../dist/app.js';
