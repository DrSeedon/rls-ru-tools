const fs=require('fs'),path=require('path');
const {parse,compileTemplate,compileScript}=require('@vue/compiler-sfc');
const acorn=require('acorn');
const root=process.argv[2]; const out={};
function walk(d){for(const f of fs.readdirSync(d)){const p=path.join(d,f);const s=fs.statSync(p);if(s.isDirectory())walk(p);else if(/\.(vue|js)$/.test(f))check(p)}}
function check(p){const src=fs.readFileSync(p,'utf8');let err=null;
 try{ if(p.endsWith('.vue')){const {descriptor,errors}=parse(src,{filename:p}); if(errors.length) throw errors[0];
   if(descriptor.template){const r=compileTemplate({source:descriptor.template.content,filename:p,id:'x'}); if(r.errors.length) throw r.errors[0];}
   if(descriptor.script||descriptor.scriptSetup){compileScript(descriptor,{id:'x'});}
 } else { try{acorn.parse(src,{ecmaVersion:'latest',sourceType:'module'})}catch(e){acorn.parse(src,{ecmaVersion:'latest',sourceType:'script'})} }
 }catch(e){err=String(e.message||e).slice(0,160)}
 out[path.relative(root,p)]=err;}
walk(root); fs.writeFileSync(process.argv[3],JSON.stringify(out,null,0));
const bad=Object.entries(out).filter(([k,v])=>v); console.log('files',Object.keys(out).length,'errors',bad.length); bad.slice(0,5).forEach(b=>console.log(b[0],b[1]));
