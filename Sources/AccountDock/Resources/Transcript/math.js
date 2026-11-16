'use strict';
// Parse TeX before Markdown consumes backslashes, underscores, or line breaks.
// Code spans/fences keep their normal Markdown rules and are never rendered as math.
window.installTranscriptMath = md => {
 const escape = md.utils.escapeHtml;
 function render(tex,display){
  try {
   if(tex.length>16000)throw new Error('formula too long');
   return window.katex.renderToString(tex,{displayMode:display,throwOnError:true,
    trust:false,strict:'ignore',maxExpand:300,maxSize:20,output:'htmlAndMathml'});
  } catch (_) { return '<code class="math-fallback">'+escape(tex)+'</code>'; }
 }
 function endAt(src,close,from){
  for(let i=src.indexOf(close,from);i>=0;i=src.indexOf(close,i+close.length)){
   let slashes=0;for(let j=i-1;j>=0&&src[j]==='\\';j--)slashes++;
   if(slashes%2===0)return i;
  }
  return -1;
 }
 md.inline.ruler.before('escape','transcript_math',(state,silent)=>{
  const src=state.src,pos=state.pos;
  let open,close,display=false;
  if(src.startsWith('\\(',pos)){open='\\(';close='\\)';}
  else if(src.startsWith('\\[',pos)){open='\\[';close='\\]';display=true;}
  else if(src.startsWith('$$',pos)){open=close='$$';display=true;}
  else if(src[pos]==='$'){open=close='$';}
  else return false;
  const start=pos+open.length,end=endAt(src,close,start);
  if(end<=start)return false;
  if(open==='$' && (/\s/.test(src[start]) || /\s/.test(src[end-1]) || /\d/.test(src[end+1]||'') || src.slice(start,end).includes('\n')))return false;
  if(!silent){const token=state.push('transcript_math','',0);token.content=src.slice(start,end);token.meta={display};}
  state.pos=end+close.length;return true;
 });
 md.block.ruler.before('fence','transcript_math_block',(state,start,end,silent)=>{
  if(state.sCount[start]-state.blkIndent>=4)return false;
  const first=state.src.slice(state.bMarks[start]+state.tShift[start],state.eMarks[start]);
  const open=first.startsWith('\\[')?'\\[':first.startsWith('$$')?'$$':null;
  if(!open)return false;
  const close=open==='$$'?'$$':'\\]';let body=first.slice(open.length),line=start;
  while(true){
   const stop=endAt(body,close,0);
   if(stop>=0){
    if(body.slice(stop+close.length).trim())return false;
    if(silent)return true;
    const token=state.push('transcript_math','',0);token.block=true;token.content=body.slice(0,stop);token.meta={display:true};token.map=[start,line+1];
    state.line=line+1;return true;
   }
   line++;if(line>=end || (state.tShift[line]<state.blkIndent && state.src.slice(state.bMarks[line],state.eMarks[line]).trim()))return false;
   body+='\n'+state.src.slice(state.bMarks[line]+state.tShift[line],state.eMarks[line]);
   if(body.length>20000)return false;
  }
 },{alt:['paragraph','reference','blockquote','list']});
 md.renderer.rules.transcript_math=(tokens,i)=>render(tokens[i].content,tokens[i].meta.display)+(tokens[i].block?'\n':'');
};
