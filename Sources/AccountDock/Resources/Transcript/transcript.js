'use strict';
const md=window.markdownit({html:false,linkify:false,typographer:false});
window.installTranscriptMath(md);
window.installKoreanEmphasis(md);
// Conversation content cannot execute HTML or load external resources.
md.renderer.rules.image=(tokens,i)=>md.utils.escapeHtml('[이미지: '+tokens[i].content+']');
const host=document.getElementById('messages'),ask=document.getElementById('ask');
const latest=document.getElementById('latest');
function updateLatest(){latest.hidden=document.documentElement.scrollHeight-innerHeight-window.scrollY<80;}
latest.addEventListener('click',()=>{window.scrollTo({top:document.documentElement.scrollHeight,behavior:'auto'});updateLatest();});
window.addEventListener('scroll',updateLatest,{passive:true});
window.addEventListener('resize',updateLatest);
let selection=null;
window.setMessages=(items,older)=>{
 const height=document.documentElement.scrollHeight,top=window.scrollY;
 host.replaceChildren();ask.hidden=true;
 for(const item of items){
  const article=document.createElement('article');article.dataset.id=item.id;
  if(item.role==='userMessage')article.className='user';
  const label=document.createElement('header');label.textContent=item.role==='userMessage'?'나':'Codex';
  const content=document.createElement('div');content.className='content';content.innerHTML=md.render(item.text);
  for(const table of content.querySelectorAll('table')){const wrap=document.createElement('div');wrap.className='table-wrap';table.replaceWith(wrap);wrap.append(table);}
  article.append(label,content);host.append(article);
 }
 if(older)window.scrollTo(0,top+document.documentElement.scrollHeight-height);
 else window.scrollTo(0,document.documentElement.scrollHeight);
 updateLatest();
};
function updateSelection(){
 const s=window.getSelection();ask.hidden=true;selection=null;
 if(!s||s.isCollapsed||!s.rangeCount)return;
 const r=s.getRangeAt(0),node=r.commonAncestorContainer;
 const content=(node.nodeType===1?node:node.parentElement).closest('.content');
 if(!content)return;
 const text=s.toString().trim();if(!text||text.length>16000)return;
 selection={id:content.parentElement.dataset.id,text};
 const rect=r.getBoundingClientRect();ask.hidden=false;
 ask.style.left=Math.max(8,Math.min(innerWidth-ask.offsetWidth-8,rect.left))+'px';
 ask.style.top=Math.max(8,Math.min(innerHeight-ask.offsetHeight-8,rect.bottom+6))+'px';
}
document.addEventListener('mouseup',e=>{if(e.target!==ask)updateSelection()});
document.addEventListener('keyup',updateSelection);
window.addEventListener('scroll',()=>{ask.hidden=true},{passive:true});
ask.addEventListener('mousedown',e=>e.preventDefault());
ask.addEventListener('click',()=>{if(selection)window.webkit.messageHandlers.sideChat.postMessage(selection);ask.hidden=true;});
