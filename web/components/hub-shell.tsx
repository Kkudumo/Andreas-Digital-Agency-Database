'use client';
import { useEffect, useRef, useState } from 'react';
import { usePathname } from 'next/navigation';
import Link from 'next/link';
import { Nav } from './nav';
import { NavProgress } from './nav-progress';

type Item={href:string;label:string;group:string};
export function HubShell({items,person,staffId,position,division,signout,children}:{
 items:Item[];person:string;staffId:string;position:string;division?:string|null;
 signout:React.ReactNode;children:React.ReactNode;
}){
 const [open,setOpen]=useState(false);
 const closeRef=useRef<HTMLButtonElement>(null);
 const menuRef=useRef<HTMLButtonElement>(null);
 const sidebarRef=useRef<HTMLElement>(null);
 const pathname=usePathname();
 const links=[{href:'/dashboard',label:'Home',icon:'⌂'},{href:'/search',label:'Search',icon:'⌕'},{href:'/projects',label:'Projects',icon:'▣'},{href:'/clients',label:'Clients',icon:'◈'}].filter(x=>items.some(i=>i.href===x.href));
 const active=(href:string)=>pathname===href||pathname.startsWith(href+'/');
 useEffect(()=>{setOpen(false);},[pathname]);
 useEffect(()=>{
  if(!open)return;
  const previousOverflow=document.body.style.overflow;
  document.body.style.overflow='hidden';
  closeRef.current?.focus();
  const onKey=(e:KeyboardEvent)=>{
   if(e.key==='Escape'){e.preventDefault();setOpen(false);return;}
   if(e.key!=='Tab')return;
   const controls=sidebarRef.current?.querySelectorAll<HTMLElement>('a[href],button:not([disabled]),input:not([disabled])');
   if(!controls?.length)return;
   const first=controls[0],last=controls[controls.length-1];
   if(e.shiftKey&&document.activeElement===first){e.preventDefault();last.focus();}
   else if(!e.shiftKey&&document.activeElement===last){e.preventDefault();first.focus();}
  };
  window.addEventListener('keydown',onKey);
  return ()=>{window.removeEventListener('keydown',onKey);document.body.style.overflow=previousOverflow;menuRef.current?.focus();};
 },[open]);
 return <div className="hub-app">
  <NavProgress/>
  <button aria-label="Close navigation" className={'hub-scrim'+(open?' is-visible':'')} onClick={()=>setOpen(false)} tabIndex={open?0:-1}/>
  <aside ref={sidebarRef} id="hub-sidebar" className={'hub-sidebar'+(open?' is-open':'')} aria-label="Primary navigation">
   <div className="hub-brand"><span><Link href="/dashboard" className="hub-brand-link"><strong><b>ADA</b>Hub / Core</strong></Link><small>Technology. Systems. Growth.</small></span><button ref={closeRef} className="hub-close" aria-label="Close menu" onClick={()=>setOpen(false)}>×</button></div>
   <div className="hub-side-caption">WORKSPACE</div>
   <Nav items={items}/>
   <div className="hub-side-footer"><div className="hub-avatar">{person.trim().charAt(0).toUpperCase()||'A'}</div><div className="hub-side-person"><strong>{person}</strong><span>{position}{division?' · '+division:''}</span><small>{staffId}</small></div><div className="hub-signout">{signout}</div></div>
  </aside>
  <div className="hub-workspace">
   <a href="#main-content" className="hub-skip-link">Skip to main content</a>
   <header className="hub-topbar">
    <div className="hub-topbar-left"><button aria-label="Open navigation" aria-controls="hub-sidebar" aria-expanded={open} ref={menuRef} className="hub-menu" onClick={()=>setOpen(true)}><span>☰</span></button><Link href="/dashboard" className="hub-mobile-wordmark">ADA <b>Hub</b></Link><div className="hub-breadcrumb"><span>Andreas Digital Agency</span><strong>Administrative Control Centre</strong></div></div>
    <div className="hub-topbar-actions"><div className="hub-admin-user"><span>{person}</span><small>{position}{division?' · '+division:''}</small></div><Link href="/search" aria-label="Search ADA Hub" className="hub-search-link"><span aria-hidden="true">⌕</span> <span>Search everything</span><kbd>ADA</kbd></Link><span className="hub-top-avatar" aria-label={'Signed in as '+person}>{person.trim().charAt(0).toUpperCase()||'A'}</span></div>
   </header>
   <main className="hub-main" id="main-content"><div className="hub-main-inner">{children}</div></main>
   <nav className="hub-bottom-nav" aria-label="Mobile quick navigation">
    {links.map(link=><Link key={link.href} href={link.href} aria-current={active(link.href)?'page':undefined}><span aria-hidden="true" className="hub-bottom-icon">{link.icon}</span><span>{link.label}</span></Link>)}
    <button type="button" aria-label="Open all navigation" aria-controls="hub-sidebar" aria-expanded={open} onClick={()=>setOpen(true)}><span aria-hidden="true" className="hub-bottom-icon">☰</span><span>More</span></button>
   </nav>
  </div>
 </div>;
}
