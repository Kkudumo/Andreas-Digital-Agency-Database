// Excel (.xlsx) <-> the spreadsheet editor's data (Univer). Pure functions, no browser needed.
// Kept: values, formulas (with their last result), number / date formats, bold / italic / underline / strike, font, size and colour, fill, alignment and wrap,
// borders, merged cells, column widths, row heights, frozen panes, several sheets, sheet names. Not kept (and said so in the interface): charts, images, pivot
// tables, conditional formatting, data validation, macros and theme-coloured styling.
import ExcelJS from 'exceljs';

type Dict<T = any> = Record<string, T>;
export type UniverWorkbook = { id: string; name: string; appVersion: string; locale: string; styles: Dict; sheetOrder: string[]; sheets: Dict };

const BORDER_TO_UNIVER: Dict<number> = { thin: 1, hair: 2, dotted: 3, dashed: 4, dashDot: 5, dashDotDot: 6, double: 7, medium: 8, mediumDashed: 9, mediumDashDot: 10, mediumDashDotDot: 11, slantDashDot: 12, thick: 13 };
const BORDER_FROM_UNIVER: Dict<string> = Object.fromEntries(Object.entries(BORDER_TO_UNIVER).map(([k, v]) => [String(v), k]));
const H_TO_UNIVER: Dict<number> = { left: 1, center: 2, right: 3, justify: 4, fill: 1, centerContinuous: 2, distributed: 4 };
const H_FROM_UNIVER: Dict<string> = { '1': 'left', '2': 'center', '3': 'right', '4': 'justify', '5': 'justify' };
const V_TO_UNIVER: Dict<number> = { top: 1, middle: 2, bottom: 3, distributed: 2, justify: 2 };
const V_FROM_UNIVER: Dict<string> = { '1': 'top', '2': 'middle', '3': 'bottom' };

const toRgb = (argb?: string): string | undefined => (argb && /^[0-9a-f]{8}$/i.test(argb) ? '#' + argb.slice(2).toLowerCase() : argb && /^[0-9a-f]{6}$/i.test(argb) ? '#' + argb.toLowerCase() : undefined);
const toArgb = (rgb?: string | null): string | undefined => (rgb && /^#[0-9a-f]{6}$/i.test(rgb) ? 'FF' + rgb.slice(1).toUpperCase() : undefined);
const colPx = (chars?: number) => Math.round((chars ?? 8.43) * 7 + 5);
const pxToChars = (px: number) => Math.max(1, (px - 5) / 7);
const serialOfDate = (d: Date) => d.getTime() / 86400000 + 25569;
const dateOfSerial = (n: number) => new Date(Math.round((n - 25569) * 86400000));
const DATE_FMT = /[dmyhs]/i;

function styleOf(cell: ExcelJS.Cell, isDate: boolean): Dict | undefined {
  const s: Dict = {};
  const f = cell.font;
  if (f) {
    if (f.name) s.ff = f.name;
    if (f.size) s.fs = f.size;
    if (f.bold) s.bl = 1;
    if (f.italic) s.it = 1;
    if (f.underline) s.ul = { s: 1 };
    if (f.strike) s.st = { s: 1 };
    const c = toRgb(f.color?.argb); if (c) s.cl = { rgb: c };
  }
  const fill: any = cell.fill;
  if (fill && fill.type === 'pattern' && fill.pattern === 'solid') { const c = toRgb(fill.fgColor?.argb); if (c) s.bg = { rgb: c }; }
  const a = cell.alignment;
  if (a) {
    if (a.horizontal && H_TO_UNIVER[a.horizontal]) s.ht = H_TO_UNIVER[a.horizontal];
    if (a.vertical && V_TO_UNIVER[a.vertical]) s.vt = V_TO_UNIVER[a.vertical];
    if (a.wrapText) s.tb = 3;
  }
  const b = cell.border;
  if (b) {
    const bd: Dict = {};
    for (const [k, side] of [['t', 'top'], ['r', 'right'], ['b', 'bottom'], ['l', 'left']] as const) {
      const e: any = (b as any)[side];
      if (e?.style && BORDER_TO_UNIVER[e.style]) bd[k] = { s: BORDER_TO_UNIVER[e.style], cl: { rgb: toRgb(e.color?.argb) ?? '#000000' } };
    }
    if (Object.keys(bd).length) s.bd = bd;
  }
  const fmt = cell.numFmt;
  if (fmt && fmt !== 'General') s.n = { pattern: fmt };
  else if (isDate) s.n = { pattern: 'yyyy-mm-dd' };
  return Object.keys(s).length ? s : undefined;
}

export async function xlsxToUniver(buf: ArrayBuffer | Uint8Array, name = 'Workbook'): Promise<UniverWorkbook> {
  const wb = new ExcelJS.Workbook();
  await wb.xlsx.load(buf as any);
  const styles: Dict = {}; const styleIds = new Map<string, string>();
  const styleId = (s?: Dict) => { if (!s) return undefined; const k = JSON.stringify(s); if (!styleIds.has(k)) { const id = 's' + (styleIds.size + 1); styleIds.set(k, id); styles[id] = s; } return styleIds.get(k); };
  const sheets: Dict = {}; const sheetOrder: string[] = [];
  wb.eachSheet((ws, idx) => {
    const id = 'sheet-' + idx; sheetOrder.push(id);
    const cellData: Dict = {}; const rowData: Dict = {}; const columnData: Dict = {};
    let maxR = 0, maxC = 0;
    ws.eachRow({ includeEmpty: false }, (row, r) => {
      if (row.height) rowData[r - 1] = { h: Math.round(row.height * 4 / 3), hd: 0 };
      row.eachCell({ includeEmpty: false }, (cell, c) => {
        let v: any = cell.value; let f: string | undefined; let isDate = false;
        if (v instanceof Date) { v = serialOfDate(v); isDate = true; }
        else if (v && typeof v === 'object') {
          if ('formula' in v || 'sharedFormula' in v) { f = '=' + ((v as any).formula ?? cell.formula ?? ''); v = (v as any).result; if (v instanceof Date) { v = serialOfDate(v); isDate = true; } if (v && typeof v === 'object' && 'error' in v) v = (v as any).error; }
          else if ('richText' in v) v = (v as any).richText.map((t: any) => t.text).join('');
          else if ('hyperlink' in v) v = (v as any).text ?? (v as any).hyperlink;
          else if ('error' in v) v = (v as any).error;
          else v = String(v);
        }
        const out: Dict = {};
        if (v !== null && v !== undefined) { out.v = typeof v === 'boolean' ? (v ? 1 : 0) : v; out.t = typeof v === 'number' ? 2 : typeof v === 'boolean' ? 3 : 1; }
        if (f) out.f = f;
        const sid = styleId(styleOf(cell, isDate)); if (sid) out.s = sid;
        if (Object.keys(out).length) { (cellData[r - 1] ||= {})[c - 1] = out; maxR = Math.max(maxR, r); maxC = Math.max(maxC, c); }
      });
    });
    ws.columns?.forEach((col, i) => { if (col && col.width) columnData[i] = { w: colPx(col.width) }; maxC = Math.max(maxC, i + 1); });
    const merges: any[] = ((ws.model as any).merges ?? []).map((m: string) => { const [a, b] = m.split(':'); const A = ws.getCell(a), B = ws.getCell(b ?? a); return { startRow: Number(A.row) - 1, endRow: Number(B.row) - 1, startColumn: Number(A.col) - 1, endColumn: Number(B.col) - 1 }; });
    const view: any = ws.views?.[0]; const freeze = view?.state === 'frozen' ? { xSplit: view.xSplit ?? 0, ySplit: view.ySplit ?? 0, startRow: view.ySplit ?? 0, startColumn: view.xSplit ?? 0 } : undefined;
    sheets[id] = { id, name: ws.name, rowCount: Math.max(100, maxR + 50), columnCount: Math.max(26, maxC + 5), cellData, rowData, columnData, mergeData: merges, ...(freeze ? { freeze } : {}) };
  });
  if (!sheetOrder.length) { sheetOrder.push('sheet-1'); sheets['sheet-1'] = { id: 'sheet-1', name: 'Sheet1', rowCount: 100, columnCount: 26, cellData: {} }; }
  return { id: 'wb-' + Math.random().toString(36).slice(2, 10), name, appVersion: '1.0.4', locale: 'enUS', styles, sheetOrder, sheets };
}

export async function univerToXlsx(data: UniverWorkbook): Promise<ArrayBuffer> {
  const wb = new ExcelJS.Workbook();
  const styleOfCell = (cell: Dict): Dict | undefined => (typeof cell.s === 'string' ? data.styles?.[cell.s] : cell.s) ?? undefined;
  for (const id of data.sheetOrder?.length ? data.sheetOrder : Object.keys(data.sheets)) {
    const sh = data.sheets[id]; if (!sh) continue;
    const ws = wb.addWorksheet(String(sh.name ?? id).slice(0, 31).replace(/[\\/?*[\]:]/g, '_') || 'Sheet');
    const frz = sh.freeze; if (frz && (frz.xSplit || frz.ySplit)) ws.views = [{ state: 'frozen', xSplit: frz.xSplit || 0, ySplit: frz.ySplit || 0 }];
    for (const [ci, col] of Object.entries<any>(sh.columnData ?? {})) if (col?.w) ws.getColumn(Number(ci) + 1).width = pxToChars(col.w);
    for (const [ri, row] of Object.entries<any>(sh.rowData ?? {})) if (row?.h) ws.getRow(Number(ri) + 1).height = row.h * 0.75;
    for (const [ri, cols] of Object.entries<any>(sh.cellData ?? {})) for (const [ci, cell] of Object.entries<any>(cols ?? {})) {
      if (!cell) continue;
      const c = ws.getCell(Number(ri) + 1, Number(ci) + 1);
      const st = styleOfCell(cell); const pattern = st?.n?.pattern as string | undefined;
      let v: any = cell.v;
      if (cell.t === 3 || typeof v === 'boolean') v = v === true || v === 1 || v === '1' || v === 'TRUE';
      else if (typeof v === 'string' && cell.t === 2 && v.trim() !== '' && !Number.isNaN(Number(v))) v = Number(v);
      const asDate = pattern && DATE_FMT.test(pattern.replace(/\[[^\]]*\]|"[^"]*"|\\./g, '')) && typeof v === 'number' && !/^[0#?.,%\s$]*$/.test(pattern);
      const val = asDate ? dateOfSerial(v) : v;
      if (cell.f) c.value = { formula: String(cell.f).replace(/^=/, ''), result: val } as any;
      else if (val !== undefined && val !== null) c.value = val;
      if (!st) continue;
      const font: Dict = {};
      if (st.ff) font.name = st.ff; if (st.fs) font.size = st.fs; if (st.bl) font.bold = true; if (st.it) font.italic = true;
      if (st.ul?.s) font.underline = true; if (st.st?.s) font.strike = true;
      const fc = toArgb(st.cl?.rgb); if (fc) font.color = { argb: fc };
      if (Object.keys(font).length) c.font = font;
      const bg = toArgb(st.bg?.rgb); if (bg) c.fill = { type: 'pattern', pattern: 'solid', fgColor: { argb: bg } };
      const al: Dict = {}; if (H_FROM_UNIVER[String(st.ht)]) al.horizontal = H_FROM_UNIVER[String(st.ht)]; if (V_FROM_UNIVER[String(st.vt)]) al.vertical = V_FROM_UNIVER[String(st.vt)]; if (st.tb === 3) al.wrapText = true;
      if (Object.keys(al).length) c.alignment = al;
      if (st.bd) { const b: Dict = {}; for (const [k, side] of [['t', 'top'], ['r', 'right'], ['b', 'bottom'], ['l', 'left']] as const) { const e = st.bd[k]; if (e && BORDER_FROM_UNIVER[String(e.s)]) b[side] = { style: BORDER_FROM_UNIVER[String(e.s)], color: { argb: toArgb(e.cl?.rgb) ?? 'FF000000' } }; } if (Object.keys(b).length) c.border = b; }
      if (pattern) c.numFmt = pattern;
    }
    for (const m of sh.mergeData ?? []) { try { ws.mergeCells(m.startRow + 1, m.startColumn + 1, m.endRow + 1, m.endColumn + 1); } catch { /* overlapping merge: keep the first */ } }
  }
  const out = await wb.xlsx.writeBuffer();
  return (out as any).buffer ? (out as any).buffer.slice((out as any).byteOffset, (out as any).byteOffset + (out as any).byteLength) : (out as ArrayBuffer);
}
