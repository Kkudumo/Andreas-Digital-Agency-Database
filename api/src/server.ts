import http from 'node:http';
import { handle } from './app.js';

// Long-running server for hosts that keep a process alive. On Vercel, api/[...route].js serves the same handler.
http.createServer(handle).listen(Number(process.env.PORT ?? 8080), () => console.log('ADA public API listening'));
