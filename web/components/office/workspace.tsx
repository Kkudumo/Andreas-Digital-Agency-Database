'use client';
import dynamic from 'next/dynamic';
import { useCallback, useEffect, useRef, useState } from 'react';
import { useRouter } from 'next/navigation';
import { openDocument } from '@/app/(irm)/documents/actions';
import { kindOfName, saveVersion, type Kind } from '@/lib/office/store';
import { xlsxToUniver, univerToXlsx } from '@/lib/office/xlsx';
import { docxToHtml, jsonToDocx } from '@/lib/office/docx';
import type { SheetHandle } from './sheet-editor';
import type { DocHandle } from './doc-editor';

const SheetEditor = dynamic(() => import('./sheet-editor'), { ssr: false, loading: () => <p className="muted">Loading spreadsheet editor…</p> });
const DocEditor = dynamic(() => import('./doc-editor'), { ssr: false, loading: () => <p className="muted">Loading document editor…</p> });

type Version = { version_no: number; state: string; label: string | null; original_filename: string | null; uploaded_at: string; size_bytes: number | null };
type Loaded = { kind: Kind; version: number; filename: string; sheet?: any; html?: string; notes?: string[]; pdfUrl?: string };

export default function DocumentWorkspace({ doc, title, versions, canEdit }: { doc: string; title: string; versions: Version[]; canEdit: boolean }) {
  const router = useRouter();
  const latest = versions.length ? Math.max(...versions.map((v) => v.version_no)) : 0;
  const [want, setWant] = useState<number | undefined>(undefined);       // undefined = the latest version
  const [loaded, setLoaded] = useState<Loaded | null>(null);
  const [msg, setMsg] = useState<{ kind: 'ok' | 'err' | 'info'; text: string } | null>(latest ? { kind: 'info', text: 'Opening…' } : null);
  const [busy, setBusy] = useState(false);
  const [dirty, setDirty] = useState(false);
  const sheet = useRef<SheetHandle | null>(null);
  const word = useRef<DocHandle | null>(null);
  const onSheet = useCallback((h: SheetHandle) => { sheet.current = h; }, []);
  const onWord = useCallback((h: DocHandle) => { word.current = h; }, []);
  const viewingOld = want !== undefined && want !== latest;

  useEffect(() => {
    if (!latest) return;
    let live = true; setLoaded(null); sheet.current = null; word.current = null; setDirty(false); setMsg({ kind: 'info', text: 'Opening…' });
    (async () => {
      const o = await openDocument(doc, 'read', want);
      if (!live) return;
      if (!o.ok) { setMsg({ kind: 'err', text: o.error }); return; }
      const kind = kindOfName(o.filename) ?? (o.mime.includes('spreadsheet') ? 'xlsx' : o.mime.includes('word') ? 'docx' : o.mime.includes('pdf') ? 'pdf' : null);
      if (!kind) { setMsg({ kind: 'err', text: 'This file type cannot be opened here. Download it instead.' }); return; }
      try {
        if (kind === 'pdf') { setLoaded({ kind, version: o.version, filename: o.filename, pdfUrl: o.url }); setMsg(null); return; }
        const r = await fetch(o.url); if (!r.ok) throw new Error('fetch');
        const bytes = await r.arrayBuffer();
        if (!live) return;
        if (kind === 'xlsx') setLoaded({ kind, version: o.version, filename: o.filename, sheet: await xlsxToUniver(bytes, title) });
        else { const { html, notes } = await docxToHtml(bytes); setLoaded({ kind, version: o.version, filename: o.filename, html, notes }); }
        setMsg(null);
      } catch (e) { console.error('open failed', e); if (live) setMsg({ kind: 'err', text: 'The file could not be read. It may be damaged; download it to check.' }); }
    })();
    return () => { live = false; };
  }, [doc, want, latest, title]);

  async function save() {
    if (!loaded || busy) return;
    setBusy(true); setMsg({ kind: 'info', text: 'Saving a new version…' });
    try {
      let bytes: ArrayBuffer;
      if (loaded.kind === 'xlsx') { const d = sheet.current?.getData(); if (!d) throw new Error('empty'); bytes = await univerToXlsx(d); }
      else if (loaded.kind === 'docx') { const j = word.current?.getJSON(); if (!j) throw new Error('empty'); bytes = await jsonToDocx(j); }
      else return;
      const name = loaded.filename.replace(/\.[a-z]+$/i, '') + '.' + loaded.kind;
      const r = await saveVersion(doc, bytes, loaded.kind, name, 'Edited in ADA Hub');
      if (r.ok) { setMsg({ kind: 'ok', text: `Saved as version ${r.version}.` }); setDirty(false); setWant(undefined); router.refresh(); }
      else setMsg({ kind: 'err', text: r.error });
    } catch { setMsg({ kind: 'err', text: 'Nothing could be saved. Please try again.' }); }
    finally { setBusy(false); }
  }

  async function download(version?: number) {
    const o = await openDocument(doc, 'download', version);
    if (!o.ok) { setMsg({ kind: 'err', text: o.error }); return; }
    const a = document.createElement('a'); a.href = o.url; a.download = o.filename; document.body.appendChild(a); a.click(); a.remove();
  }

  if (!latest) return <p className="muted">This document has no file yet.</p>;
  const editable = canEdit && !viewingOld && loaded && loaded.kind !== 'pdf';
  return (
    <div data-testid="workspace" onInput={() => setDirty(true)} onKeyDown={() => setDirty(true)}>
      <div className="office-bar">
        <label>Version <select value={want ?? latest} onChange={(e) => setWant(Number(e.target.value) === latest ? undefined : Number(e.target.value))} aria-label="Version">
          {versions.slice().sort((a, b) => b.version_no - a.version_no).map((v) => <option key={v.version_no} value={v.version_no}>v{v.version_no}{v.version_no === latest ? ' (latest)' : ''} · {new Date(v.uploaded_at).toLocaleDateString('en-GB')}{v.label ? ' · ' + v.label : ''}</option>)}
        </select></label>
        {editable && <button type="button" className="primary" onClick={save} disabled={busy} data-testid="save-version">{busy ? 'Saving…' : 'Save as a new version'}</button>}
        <button type="button" onClick={() => download(want)} data-testid="download">Download</button>
        {dirty && editable && <span className="muted small">Unsaved changes</span>}
        {viewingOld && <span className="badge warn">Viewing an earlier version, read only</span>}
        {!canEdit && loaded?.kind !== 'pdf' && <span className="badge">Read only for you</span>}
      </div>
      {msg && <div className={'flash ' + (msg.kind === 'err' ? 'error' : msg.kind === 'ok' ? 'ok' : '')} role={msg.kind === 'err' ? 'alert' : 'status'}>{msg.text}</div>}
      {loaded?.notes?.length ? <p className="muted small">Some Word features were simplified when opening: {loaded.notes.join(' · ')}</p> : null}
      {loaded?.kind === 'xlsx' && <SheetEditor key={`${doc}-${loaded.version}`} data={loaded.sheet} readOnly={!editable} onReady={onSheet} />}
      {loaded?.kind === 'docx' && <DocEditor key={`${doc}-${loaded.version}`} html={loaded.html ?? ''} readOnly={!editable} onReady={onWord} />}
      {loaded?.kind === 'pdf' && <iframe title={title} src={loaded.pdfUrl} className="office-pdf" data-testid="pdf-view" />}
      <p className="muted small" style={{ marginTop: '.6rem' }}>Each save creates a new version; earlier versions stay available. Opening and downloading are recorded.
        Charts, images, macros and complex page layout are not preserved when a file is edited here: download the original to keep them. PDFs can be read, printed and downloaded, not edited.</p>
    </div>
  );
}
