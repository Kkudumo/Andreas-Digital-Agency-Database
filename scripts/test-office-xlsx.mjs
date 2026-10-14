// Round-trip test of the Excel converter: build a workbook with values, formulas, formats, styles, merges, widths, freeze and two sheets; convert to the editor's
// data and back; the content must survive. (Pure Node: no browser, no database.)  Run: node --experimental-strip-types scripts/test-office-xlsx.mjs
import ExcelJS from '../web/node_modules/exceljs/lib/exceljs.nodejs.js';
import { xlsxToUniver, univerToXlsx } from '../web/lib/office/xlsx.ts';
let failed = 0; const ok = (n, c, d = '') => { console.log(`  ${c ? 'ok  ' : 'FAIL'}  ${n}${c ? '' : ' ' + d}`); if (!c) failed++; };

const wb = new ExcelJS.Workbook();
const a = wb.addWorksheet('Quote');
a.columns = [{ width: 30 }, { width: 12 }, { width: 14 }];
a.getCell('A1').value = 'Item'; a.getCell('A1').font = { bold: true, size: 14, color: { argb: 'FF1F4FD8' } }; a.getCell('A1').fill = { type: 'pattern', pattern: 'solid', fgColor: { argb: 'FFEEEEEE' } };
a.getCell('B1').value = 'Qty'; a.getCell('C1').value = 'Price';
a.getCell('A2').value = 'Security website'; a.getCell('B2').value = 1; a.getCell('C2').value = 3000; a.getCell('C2').numFmt = '"N$"#,##0.00';
a.getCell('A3').value = 'Mini market website'; a.getCell('B3').value = 2; a.getCell('C3').value = 2500;
a.getCell('A5').value = 'Total'; a.getCell('C5').value = { formula: 'SUMPRODUCT(B2:B3,C2:C3)', result: 8000 };
a.getCell('C5').border = { top: { style: 'thin', color: { argb: 'FF000000' } }, bottom: { style: 'double', color: { argb: 'FF000000' } } };
a.getCell('A6').value = new Date(Date.UTC(2026, 9, 13)); a.getCell('A6').numFmt = 'yyyy-mm-dd';
a.getCell('B6').value = true; a.getCell('A7').value = 'wrapped text here'; a.getCell('A7').alignment = { wrapText: true, horizontal: 'center', vertical: 'middle' };
a.mergeCells('A9:C9'); a.getCell('A9').value = 'Merged note'; a.getRow(2).height = 30;
a.views = [{ state: 'frozen', ySplit: 1 }];
wb.addWorksheet('Second').getCell('B2').value = 'hello';
const original = Buffer.from(await wb.xlsx.writeBuffer());

const u = await xlsxToUniver(original, 'Quote');
const s1 = u.sheets[u.sheetOrder[0]];
ok('two sheets with their names', u.sheetOrder.length === 2 && s1.name === 'Quote' && u.sheets[u.sheetOrder[1]].name === 'Second');
ok('values and numbers', s1.cellData[1][0].v === 'Security website' && s1.cellData[1][2].v === 3000 && s1.cellData[1][2].t === 2);
ok('formula keeps its text and last result', s1.cellData[4][2].f === '=SUMPRODUCT(B2:B3,C2:C3)' && s1.cellData[4][2].v === 8000);
ok('bold header style, size and colour', (() => { const st = u.styles[s1.cellData[0][0].s]; return st.bl === 1 && st.fs === 14 && st.cl.rgb === '#1f4fd8' && st.bg.rgb === '#eeeeee'; })());
ok('currency number format', u.styles[s1.cellData[1][2].s].n.pattern === '"N$"#,##0.00');
ok('date becomes a serial with a date format', Math.round(s1.cellData[5][0].v) === 46308 && /yyyy/.test(u.styles[s1.cellData[5][0].s].n.pattern));
ok('merge, freeze, row height, column width', s1.mergeData.length === 1 && s1.mergeData[0].endColumn === 2 && s1.freeze.ySplit === 1 && s1.rowData[1].h === 40 && s1.columnData[0].w > 200);

// edit in the "editor": change a number and add a cell, then export
s1.cellData[1][2].v = 3500; s1.cellData[10] = { 0: { v: 'added in the browser', t: 1 } };
const out = await univerToXlsx(u);
const back = new ExcelJS.Workbook(); await back.xlsx.load(out);
const b = back.getWorksheet('Quote');
ok('edited number saved', b.getCell('C2').value === 3500);
ok('added cell saved', b.getCell('A11').value === 'added in the browser');
ok('formula survives with its text', b.getCell('C5').value.formula === 'SUMPRODUCT(B2:B3,C2:C3)');
ok('bold, size and colour survive', b.getCell('A1').font.bold === true && b.getCell('A1').font.size === 14 && b.getCell('A1').font.color.argb === 'FF1F4FD8');
ok('fill survives', b.getCell('A1').fill.fgColor.argb === 'FFEEEEEE');
ok('currency format survives', b.getCell('C2').numFmt === '"N$"#,##0.00');
ok('borders survive', b.getCell('C5').border.top.style === 'thin' && b.getCell('C5').border.bottom.style === 'double');
ok('date is a real date again', b.getCell('A6').value instanceof Date && b.getCell('A6').value.toISOString().startsWith('2026-10-13'));
ok('boolean, wrap and alignment survive', b.getCell('B6').value === true && b.getCell('A7').alignment.wrapText === true && b.getCell('A7').alignment.horizontal === 'center' && b.getCell('A7').alignment.vertical === 'middle');
ok('merge, freeze and second sheet survive', (b.model.merges ?? []).includes('A9:C9') && b.views[0].state === 'frozen' && b.views[0].ySplit === 1 && back.getWorksheet('Second').getCell('B2').value === 'hello');
ok('column width and row height survive', Math.abs(b.getColumn(1).width - 30) < 0.2 && Math.abs(b.getRow(2).height - 30) < 0.2);
ok('an empty file still opens as one blank sheet', await (async () => { const e = new ExcelJS.Workbook(); e.addWorksheet('Only'); const r = await xlsxToUniver(Buffer.from(await e.xlsx.writeBuffer())); return r.sheetOrder.length === 1; })());
ok('a corrupt file is rejected, not half-read', await xlsxToUniver(Buffer.from('not a spreadsheet')).then(() => false, () => true));
console.log(failed ? `\n${failed} FAILED` : '\nall passed'); process.exit(failed ? 1 : 0);
