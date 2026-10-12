'use client';
import { useEffect, useState } from 'react';
import { usePathname } from 'next/navigation';
import Link from 'next/link';
import { Nav } from './nav';

type Item={href:string;label:string;group:string};
export function HubShell({items,person,staffId,position,division,signout,children}:{
 items:Item[];person:string;staffId:string;position:string;division?:string|null;
 signout:React.ReactNode;children:React.ReactNode;
}){
 const [open,setOpen]=useState(false);
 const pathname=usePathname();
 useEffect(()=>{setOpen(false);},[pathname]);
 useEffect(()=>{
  if(!open)return;
  const onKey=(e:KeyboardEvent)=>{if(e.key==='Escape')setOpen(false);};
  window.addEventListener('keydown',onKey);
  return ()=>window.removeEventListener('keydown',onKey);
 },[open]);
 return <div className="hub-app">
  <button aria-label="Close navigation" className={'hub-scrim'+(open?' is-visible':'')} onClick={()=>setOpen(false)} tabIndex={open?0:-1}/>
  <aside id="hub-sidebar" className={'hub-sidebar'+(open?' is-open':'')} aria-label="Primary navigation">
   <div className="hub-brand"><span className="hub-mark" aria-hidden="true">A</span><span><strong>ADA Hub</strong><small>Institutional workspace</small></span><button className="hub-close" aria-label="Close menu" onClick={()=>setOpen(false)}>×</button></div>
   <div className="hub-side-caption">WORKSPACE</div>
   <Nav items={items}/>
   <div className="hub-side-footer"><div className="hub-avatar">{person.trim().charAt(0).toUpperCase()||'A'}</div><div className="hub-side-person"><strong>{person}</strong><span>{position}{division?' · '+division:''}</span><small>{staffId}</small></div><div className="hub-signout">{signout}</div></div>
  </aside>
  <div className="hub-workspace">
   <header className="hub-topbar">
    <div className="hub-topbar-left"><button aria-label="Open navigation" aria-controls="hub-sidebar" aria-expanded={open} className="hub-menu" onClick={()=>setOpen(true)}><span>☰</span></button><Link href="/dashboard" className="hub-mobile-wordmark">ADA <b>Hub</b></Link><div className="hub-breadcrumb"><span>ADA / Workspace</span><strong>{items.find(i=>pathname===i.href||pathname.startsWith(i.href+'/'))?.label||'Overview'}</strong></div></div>
    <div className="hub-topbar-actions"><Link href="/search" className="hub-search-link"><span aria-hidden="true">⌕</span> <span>Search everything</span><kbd>ADA</kbd></Link><span className="hub-top-avatar" aria-label={'Signed in as '+person}>{person.trim().charAt(0).toUpperCase()||'A'}</span></div>
   </header>
   <main className="hub-main" id="main-content"><div className="hub-main-inner">{children}</div></main>
  </div>
 </div>;
}
