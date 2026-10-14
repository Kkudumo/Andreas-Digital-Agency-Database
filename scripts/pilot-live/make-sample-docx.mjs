// Writes a small real .docx (used by the documents journey as "a Word file someone already has"). Run: node --experimental-strip-types make-sample-docx.mjs <out>
import { jsonToDocx } from '../../web/lib/office/docx.ts';
import fs from 'node:fs';
const t = (text) => ({ type: 'text', text });
const b = await jsonToDocx({ type: 'doc', content: [{ type: 'heading', attrs: { level: 1 }, content: [t('Meeting notes')] }, { type: 'paragraph', content: [t('We agreed the scope.')] }, { type: 'heading', attrs: { level: 2 }, content: [t('Action list')] }, { type: 'bulletList', content: [{ type: 'listItem', content: [{ type: 'paragraph', content: [t('Send quote')] }] }] }] });
fs.writeFileSync(process.argv[2], Buffer.from(b));
