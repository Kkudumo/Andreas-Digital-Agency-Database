// Word (.docx) <-> the document editor (TipTap / ProseMirror). Pure functions, no browser needed.
// Import uses mammoth (Word -> clean HTML); export builds a real .docx from the editor's JSON.
// Kept: paragraphs, headings 1-3, bold / italic / underline / strikethrough / code, links, bullet and numbered lists (nested), block quotes, tables, line breaks,
// horizontal rules. Not kept (and said so in the interface): page layout and headers / footers, images, text boxes, comments and tracked changes, fonts and colours.
import mammoth from 'mammoth';
import { Document, Packer, Paragraph, TextRun, HeadingLevel, ExternalHyperlink, Table, TableRow, TableCell, WidthType, BorderStyle, LevelFormat, AlignmentType } from 'docx';

type PM = { type: string; attrs?: Record<string, any>; content?: PM[]; text?: string; marks?: { type: string; attrs?: Record<string, any> }[] };

export async function docxToHtml(buf: ArrayBuffer | Uint8Array): Promise<{ html: string; notes: string[] }> {
  // mammoth's browser build reads an ArrayBuffer; its Node build reads a Buffer
  const ab = buf instanceof Uint8Array ? buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength) : buf;
  const input: any = typeof window === 'undefined' ? { buffer: Buffer.from(ab as ArrayBuffer) } : { arrayBuffer: ab };
  const r = await mammoth.convertToHtml(input, {
    styleMap: ["p[style-name='Title'] => h1:fresh", "p[style-name='Subtitle'] => h2:fresh", "p[style-name='Quote'] => blockquote > p:fresh", 'u => u'],
    ignoreEmptyParagraphs: false,
  });
  const notes = [...new Set(r.messages.filter((m) => m.type === 'warning').map((m) => m.message))].slice(0, 5);
  return { html: r.value || '<p></p>', notes };
}

const HEADINGS = [HeadingLevel.HEADING_1, HeadingLevel.HEADING_2, HeadingLevel.HEADING_3, HeadingLevel.HEADING_4, HeadingLevel.HEADING_5, HeadingLevel.HEADING_6];

function runs(nodes: PM[] = []): (TextRun | ExternalHyperlink)[] {
  const out: (TextRun | ExternalHyperlink)[] = [];
  for (const n of nodes) {
    if (n.type === 'hardBreak') { out.push(new TextRun({ break: 1 })); continue; }
    if (n.type !== 'text' || n.text === undefined) continue;
    const m = new Set((n.marks ?? []).map((x) => x.type));
    const run = new TextRun({ text: n.text, bold: m.has('bold'), italics: m.has('italic'), underline: m.has('underline') ? {} : undefined, strike: m.has('strike'), font: m.has('code') ? 'Courier New' : undefined });
    const link = (n.marks ?? []).find((x) => x.type === 'link');
    out.push(link?.attrs?.href ? new ExternalHyperlink({ link: String(link.attrs.href), children: [new TextRun({ text: n.text, style: 'Hyperlink', bold: m.has('bold'), italics: m.has('italic'), underline: {} })] }) : run);
  }
  return out;
}

function block(n: PM, ctx: { list?: { ref: string; level: number }; quote?: boolean } = {}): (Paragraph | Table)[] {
  switch (n.type) {
    case 'paragraph': return [new Paragraph({ children: runs(n.content), numbering: ctx.list ? { reference: ctx.list.ref, level: Math.min(ctx.list.level, 8) } : undefined, indent: ctx.quote ? { left: 720 } : undefined, alignment: alignOf(n) })];
    case 'heading': return [new Paragraph({ children: runs(n.content), heading: HEADINGS[Math.min(Math.max((n.attrs?.level ?? 1) - 1, 0), 5)], alignment: alignOf(n) })];
    case 'codeBlock': return String(n.content?.map((c) => c.text).join('') ?? '').split('\n').map((line) => new Paragraph({ children: [new TextRun({ text: line, font: 'Courier New' })] }));
    case 'blockquote': return (n.content ?? []).flatMap((c) => block(c, { ...ctx, quote: true }));
    case 'horizontalRule': return [new Paragraph({ border: { bottom: { style: BorderStyle.SINGLE, size: 6, color: '999999', space: 1 } }, children: [] })];
    case 'bulletList':
    case 'orderedList': {
      const ref = n.type === 'bulletList' ? 'bullets' : 'numbers'; const level = ctx.list ? ctx.list.level + 1 : 0;
      return (n.content ?? []).flatMap((li) => (li.content ?? []).flatMap((c) => (c.type === 'bulletList' || c.type === 'orderedList') ? block(c, { list: { ref, level } }) : block(c, { ...ctx, list: { ref, level } })));
    }
    case 'table': return [new Table({ width: { size: 100, type: WidthType.PERCENTAGE }, rows: (n.content ?? []).map((row) => new TableRow({ children: (row.content ?? []).map((cell) => new TableCell({ children: ((cell.content ?? []).flatMap((c) => block(c)) as Paragraph[]).length ? ((cell.content ?? []).flatMap((c) => block(c)) as Paragraph[]) : [new Paragraph('')], shading: cell.type === 'tableHeader' ? { fill: 'EEEEEE' } : undefined })) })) })];
    default: return (n.content ?? []).flatMap((c) => block(c, ctx));
  }
}
const alignOf = (n: PM) => (n.attrs?.textAlign === 'center' ? AlignmentType.CENTER : n.attrs?.textAlign === 'right' ? AlignmentType.RIGHT : n.attrs?.textAlign === 'justify' ? AlignmentType.JUSTIFIED : undefined);

export async function jsonToDocx(doc: PM): Promise<ArrayBuffer> {
  const children = (doc.content ?? []).flatMap((n) => block(n));
  const levels = (fmt: any, text: (i: number) => string) => Array.from({ length: 9 }, (_, i) => ({ level: i, format: fmt, text: text(i), alignment: AlignmentType.LEFT, style: { paragraph: { indent: { left: 720 * (i + 1), hanging: 360 } } } }));
  const d = new Document({
    numbering: { config: [{ reference: 'bullets', levels: levels(LevelFormat.BULLET, () => '•') }, { reference: 'numbers', levels: levels(LevelFormat.DECIMAL, (i) => `%${i + 1}.`) }] },
    sections: [{ children: children.length ? children : [new Paragraph('')] }],
  });
  const blob = await Packer.toBlob(d);
  return blob.arrayBuffer();
}
