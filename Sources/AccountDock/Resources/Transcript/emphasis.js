'use strict';
window.installKoreanEmphasis = md => {
 // Keep markdown-it's delimiter pairing, nesting, escaping and code handling.
 // Only relax a closing ** boundary between punctuation and a Korean suffix.
 md.inline.ruler.before('emphasis','korean_quoted_strong',(state,silent)=>{
  const pos=state.pos;
  if(silent || !state.src.startsWith('**',pos))return false;
  const run=state.scanDelims(pos,true);
  if(run.length!==2 || run.can_close || pos===0)return false;
  const previous=state.src[pos-1],next=state.src[pos+2]||'';
  if(!/[\p{P}]/u.test(previous) || !/[\u1100-\u11ff\u3130-\u318f\uac00-\ud7a3]/u.test(next))return false;
  for(let i=0;i<2;i++){
   const token=state.push('text','',0);token.content='*';
   state.delimiters.push({marker:42,length:2,token:state.tokens.length-1,end:-1,open:run.can_open,close:true});
  }
  state.pos+=2;return true;
 });
};
