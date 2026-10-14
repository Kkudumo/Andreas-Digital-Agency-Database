'use client';
import { useEffect, useRef } from 'react';
import '@univerjs/preset-sheets-core/lib/index.css';

export type SheetHandle = { getData: () => any };

// The in-browser spreadsheet (Univer). Loaded only when a spreadsheet is opened. The parent receives a handle to read the current workbook for saving.
export default function SheetEditor({ data, readOnly, onReady }: { data: any; readOnly: boolean; onReady: (h: SheetHandle) => void }) {
  const box = useRef<HTMLDivElement>(null);
  useEffect(() => {
    let dispose: (() => void) | undefined; let cancelled = false;
    (async () => {
      const [{ createUniver, LocaleType, mergeLocales }, { UniverSheetsCorePreset }, en] = await Promise.all([
        import('@univerjs/presets'), import('@univerjs/preset-sheets-core'), import('@univerjs/preset-sheets-core/locales/en-US'),
      ]);
      if (cancelled || !box.current) return;
      const { univer, univerAPI } = createUniver({
        locale: LocaleType.EN_US,
        locales: { [LocaleType.EN_US]: mergeLocales((en as any).default) },
        presets: [UniverSheetsCorePreset({ container: box.current })],
      });
      const wb = univerAPI.createWorkbook(data);
      if (readOnly) wb.setEditable(false);
      onReady({ getData: () => univerAPI.getActiveWorkbook()?.save() });
      dispose = () => { try { univerAPI.dispose(); } catch { univer.dispose(); } };
    })();
    return () => { cancelled = true; dispose?.(); };
    // the workbook is opened once; a different version remounts this component
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);
  return <div ref={box} className="office-sheet" data-testid="sheet-editor" />;
}
