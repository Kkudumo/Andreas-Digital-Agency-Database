// Round-trip test of the Word converter: editor JSON -> real .docx -> HTML again; the structure and the text must survive. Pure Node.
// Run: node --experimental-strip-types scripts/test-office-docx.mjs
import { docxToHtml, jsonToDocx } from '../web/lib/office/docx.ts';
let failed = 0; const ok = (n, c, d = '') => { console.log(`  ${c ? 'ok  ' : 'FAIL'}  ${n}${c ? '' : ' ' + d}`); if (!c) failed++; };
const t = (text, ...marks) => ({ type: 'text', text, ...(marks.length ? { marks: marks.map((m) => (typeof m === 'string' ? { type: m } : m)) } : {}) });
const doc = { type: 'doc', content: [
  { type: 'heading', attrs: { level: 1 }, content: [t('Website agreement')] },
  { type: 'paragraph', content: [t('This agreement is between '), t('Andreas Digital Agency', 'bold'), t(' and '), t('Acme Holdings', 'italic', 'underline'), t('. See '), t('our site', { type: 'link', attrs: { href: 'https://andreasdigitalagency.com' } }), t('.')] },
  { type: 'heading', attrs: { level: 2 }, content: [t('Scope')] },
  { type: 'bulletList', content: [
    { type: 'listItem', content: [{ type: 'paragraph', content: [t('Security company website')] }] },
    { type: 'listItem', content: [{ type: 'paragraph', content: [t('Mini market website')] }, { type: 'bulletList', content: [{ type: 'listItem', content: [{ type: 'paragraph', content: [t('Online ordering')] }] }] }] },
  ] },
  { type: 'orderedList', content: [{ type: 'listItem', content: [{ type: 'paragraph', content: [t('Deposit N$5,000')] }] }, { type: 'listItem', content: [{ type: 'paragraph', content: [t('Balance on delivery', 'strike')] }] }] },
  { type: 'blockquote', content: [{ type: 'paragraph', content: [t('Payment within 30 days.')] }] },
  { type: 'table', content: [
    { type: 'tableRow', content: [{ type: 'tableHeader', content: [{ type: 'paragraph', content: [t('Item')] }] }, { type: 'tableHeader', content: [{ type: 'paragraph', content: [t('Price')] }] }] },
    { type: 'tableRow', content: [{ type: 'tableCell', content: [{ type: 'paragraph', content: [t('Security website')] }] }, { type: 'tableCell', content: [{ type: 'paragraph', content: [t('N$3,000')] }] }] },
  ] },
  { type: 'paragraph', content: [t('line one'), { type: 'hardBreak' }, t('line two')] },
] };
const bytes = await jsonToDocx(doc);
ok('produces a real .docx (zip signature)', new Uint8Array(bytes)[0] === 0x50 && new Uint8Array(bytes)[1] === 0x4b && bytes.byteLength > 2000);
const { html } = await docxToHtml(new Uint8Array(bytes));
ok('heading levels', /<h1>Website agreement<\/h1>/.test(html) && /<h2>Scope<\/h2>/.test(html), html.slice(0, 200));
ok('bold, italic, underline, strike', /<strong>Andreas Digital Agency<\/strong>/.test(html) && /<em>/.test(html) && /<u>|<em><u>|<u><em>/.test(html) && /<s>Balance on delivery<\/s>/.test(html), html);
ok('hyperlink', /<a href="https:\/\/andreasdigitalagency.com\/?">(<u>)?our site(<\/u>)?<\/a>/.test(html), html);
ok('bullet list with a nested item', /<ul><li>Security company website<\/li><li>Mini market website<ul><li>Online ordering<\/li><\/ul><\/li><\/ul>/.test(html), html);
ok('numbered list', /<ol><li>Deposit N\$5,000<\/li><li>/.test(html), html);
ok('table with its cells', /<table>/.test(html) && /Security website<\/p><\/td>|Security website<\/td>/.test(html) && /N\$3,000/.test(html), html);
ok('line break', /line one<br \/>line two/.test(html), html);
ok('a corrupt file is rejected', await docxToHtml(new Uint8Array([1, 2, 3, 4])).then(() => false, () => true));
console.log(failed ? `\n${failed} FAILED` : '\nall passed'); process.exit(failed ? 1 : 0);
