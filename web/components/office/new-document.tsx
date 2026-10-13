'use client';
import { useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import { createDocument } from '@/app/(irm)/documents/actions';
import { kindOfName, saveVersion, type Kind } from '@/lib/office/store';
import { univerToXlsx } from '@/lib/office/xlsx';
import { jsonToDocx } from '@/lib/office/docx';

const TYPES = [['report', 'Report'], ['proposal', 'Proposal'], ['requirements', 'Requirements'], ['contract', 'Contract'], ['correspondence', 'Correspondence'], ['deliverable', 'Deliverable'], ['minutes', 'Minutes'], ['policy', 'Policy'], ['legal', 'Legal'], ['invoice', 'Invoice copy'], ['other', 'Other']];

export default function NewDocument({ divisions, defaultDivision, link }: { divisions: { id: string; name: string }[]; defaultDivision?: string; link?: string }) {
  const router = useRouter();
  const [how, setHow] = useState<'docx' | 'xlsx' | 'upload'>('docx');
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [ready, setReady] = useState(false);          // the form is live only once the page's scripts are running (a plain browser submit would lose the file)
  useEffect(() => setReady(true), []);

  async function submit(e: React.FormEvent<HTMLFormElement>) {
    e.preventDefault(); setErr(null); setBusy(true);
    const f = new FormData(e.currentTarget);
    try {
      let bytes: ArrayBuffer; let kind: Kind; let filename: string;
      const title = String(f.get('title') ?? '').trim();
      if (how === 'upload') {
        const file = f.get('file') as File | null; const k = file ? kindOfName(file.name) : null;
        if (!file || !file.size || !k) { setErr('Choose a Word (.docx), Excel (.xlsx) or PDF file.'); return; }
        if (file.size > 50 * 1024 * 1024) { setErr('That file is larger than 50 MB.'); return; }
        bytes = await file.arrayBuffer(); kind = k; filename = file.name;
      } else if (how === 'docx') { bytes = await jsonToDocx({ type: 'doc', content: [{ type: 'paragraph' }] }); kind = 'docx'; filename = `${title || 'Document'}.docx`; }
      else { bytes = await univerToXlsx({ id: 'new', name: title, appVersion: '1.0.4', locale: 'enUS', styles: {}, sheetOrder: ['sheet-1'], sheets: { 'sheet-1': { id: 'sheet-1', name: 'Sheet1', rowCount: 100, columnCount: 26, cellData: {} } } }); kind = 'xlsx'; filename = `${title || 'Spreadsheet'}.xlsx`; }
      const made = await createDocument({ title, type: String(f.get('type')), division: String(f.get('division')), link: String(f.get('link') ?? '') || null });
      if (!made.ok) { setErr(made.error); return; }
      const saved = await saveVersion(made.id, bytes, kind, filename, how === 'upload' ? 'Uploaded' : 'Created in ADA Hub');
      if (!saved.ok) { setErr(`The document record was created but its file was not stored: ${saved.error}`); return; }
      router.push(`/documents/${made.id}`);
    } catch { setErr('Something went wrong. Nothing was lost; please try again.'); }
    finally { setBusy(false); }
  }
  return (
    <form onSubmit={submit} className="card form" data-testid="new-document" data-ready={ready}>
      {err && <div className="flash error" role="alert">{err}</div>}
      <fieldset className="office-choice"><legend>What do you want to do?</legend>
        <label><input type="radio" name="how" checked={how === 'docx'} onChange={() => setHow('docx')} /> Write a new Word document</label>
        <label><input type="radio" name="how" checked={how === 'xlsx'} onChange={() => setHow('xlsx')} /> Start a new Excel spreadsheet</label>
        <label><input type="radio" name="how" checked={how === 'upload'} onChange={() => setHow('upload')} /> Upload a file I already have (Word, Excel or PDF)</label>
      </fieldset>
      <label>Title<input name="title" required minLength={2} maxLength={200} placeholder="e.g. Acme website agreement" /></label>
      <label>Type<select name="type" defaultValue="report">{TYPES.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select></label>
      <label>Division<select name="division" required defaultValue={defaultDivision}>{divisions.map((d) => <option key={d.id} value={d.id}>{d.name}</option>)}</select></label>
      <label>Attach to a record (optional)<input name="link" defaultValue={link} placeholder="A client, project or invoice ID, e.g. ADA-CLI-2026-0001" /></label>
      {how === 'upload' && <label>File<input type="file" name="file" accept=".docx,.xlsx,.pdf" required /></label>}
      <button className="primary" type="submit" disabled={busy || !ready}>{busy ? 'Creating…' : how === 'upload' ? 'Upload' : 'Create and open'}</button>
    </form>
  );
}
