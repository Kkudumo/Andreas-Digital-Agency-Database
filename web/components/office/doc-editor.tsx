'use client';
import { useEffect } from 'react';
import { useEditor, EditorContent } from '@tiptap/react';
import StarterKit from '@tiptap/starter-kit';
import { Table, TableRow, TableCell, TableHeader } from '@tiptap/extension-table';

export type DocHandle = { getJSON: () => any; isEmpty: () => boolean };

// The in-browser word processor (TipTap). The Word file is read to HTML by mammoth and written back as a real .docx from this editor's content.
export default function DocEditor({ html, readOnly, onReady }: { html: string; readOnly: boolean; onReady: (h: DocHandle) => void }) {
  const editor = useEditor({
    extensions: [StarterKit.configure({ heading: { levels: [1, 2, 3] }, link: { openOnClick: false } }), Table.configure({ resizable: false }), TableRow, TableHeader, TableCell],
    content: html,
    editable: !readOnly,
    immediatelyRender: false,
    editorProps: { attributes: { class: 'office-page', 'data-testid': 'doc-page' } },
  });
  useEffect(() => { if (editor) onReady({ getJSON: () => editor.getJSON(), isEmpty: () => editor.isEmpty }); }, [editor, onReady]);
  if (!editor) return <div className="muted">Loading editor…</div>;
  const B = ({ label, on, active, title }: { label: string; on: () => void; active?: boolean; title: string }) =>
    <button type="button" title={title} aria-label={title} aria-pressed={active} className={'office-btn' + (active ? ' on' : '')} onClick={on} disabled={readOnly}>{label}</button>;
  const c = () => editor.chain().focus();
  return (
    <div className="office-doc">
      <div className="office-toolbar" role="toolbar" aria-label="Formatting">
        <B label="¶" title="Normal text" on={() => c().setParagraph().run()} active={editor.isActive('paragraph')} />
        <B label="H1" title="Heading 1" on={() => c().toggleHeading({ level: 1 }).run()} active={editor.isActive('heading', { level: 1 })} />
        <B label="H2" title="Heading 2" on={() => c().toggleHeading({ level: 2 }).run()} active={editor.isActive('heading', { level: 2 })} />
        <B label="H3" title="Heading 3" on={() => c().toggleHeading({ level: 3 }).run()} active={editor.isActive('heading', { level: 3 })} />
        <span className="office-sep" />
        <B label="B" title="Bold" on={() => c().toggleBold().run()} active={editor.isActive('bold')} />
        <B label="I" title="Italic" on={() => c().toggleItalic().run()} active={editor.isActive('italic')} />
        <B label="U" title="Underline" on={() => c().toggleUnderline().run()} active={editor.isActive('underline')} />
        <B label="S" title="Strikethrough" on={() => c().toggleStrike().run()} active={editor.isActive('strike')} />
        <span className="office-sep" />
        <B label="• List" title="Bulleted list" on={() => c().toggleBulletList().run()} active={editor.isActive('bulletList')} />
        <B label="1. List" title="Numbered list" on={() => c().toggleOrderedList().run()} active={editor.isActive('orderedList')} />
        <B label="❝" title="Quote" on={() => c().toggleBlockquote().run()} active={editor.isActive('blockquote')} />
        <B label="Link" title="Link" on={() => { const href = window.prompt('Link address (https://…)'); if (href) c().setLink({ href }).run(); else if (href === '') c().unsetLink().run(); }} active={editor.isActive('link')} />
        <span className="office-sep" />
        <B label="Table" title="Insert a 3×3 table" on={() => c().insertTable({ rows: 3, cols: 3, withHeaderRow: true }).run()} />
        <B label="+Row" title="Add a row below" on={() => c().addRowAfter().run()} />
        <B label="+Col" title="Add a column right" on={() => c().addColumnAfter().run()} />
        <B label="−Table" title="Delete the table" on={() => c().deleteTable().run()} />
        <span className="office-sep" />
        <B label="↶" title="Undo" on={() => c().undo().run()} />
        <B label="↷" title="Redo" on={() => c().redo().run()} />
      </div>
      <EditorContent editor={editor} />
    </div>
  );
}
