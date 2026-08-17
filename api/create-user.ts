const url = process.env.VITE_SUPABASE_URL || process.env.SUPABASE_URL || '';
const service = process.env.SUPABASE_SERVICE_ROLE_KEY || '';
const anon = process.env.VITE_SUPABASE_ANON_KEY || '';

async function parseResponse(r:Response){
 const text=await r.text();
 if(!text)return null;
 try{return JSON.parse(text)}catch{return {raw:text}}
}
async function db(path:string, init:RequestInit={}){
 const r=await fetch(`${url}/rest/v1/${path}`,{...init,headers:{apikey:service,Authorization:`Bearer ${service}`,'Content-Type':'application/json',...(init.headers||{})}});
 const d=await parseResponse(r);
 if(!r.ok) throw new Error(typeof d==='string'?d:(d?.message||d?.error||d?.hint||d?.details||`Database error ${r.status}`));
 return d;
}

export default async function handler(req:any,res:any){
 if(req.method!=='POST') return res.status(405).json({error:'Method not allowed'});
 if(!url||!service||!anon) return res.status(500).json({error:'Supabase server environment variables are missing.'});
 try{
  const auth=req.headers.authorization||'';
  if(!auth.startsWith('Bearer ')) return res.status(401).json({error:'Unauthorized'});
  const token=auth.slice(7);
  const me=await fetch(`${url}/auth/v1/user`,{headers:{apikey:anon,Authorization:`Bearer ${token}`}});
  const meData=await parseResponse(me);
  if(!me.ok) return res.status(401).json({error:'Invalid session'});

  const rows=await db(`profiles?select=id,role,sector_id&id=eq.${encodeURIComponent(meData.id)}&limit=1`);
  const actor=rows?.[0];
  if(!actor||!['site_admin','priest','secretary','servant'].includes(actor.role)) return res.status(403).json({error:'ليس لديك صلاحية إنشاء حسابات.'});

  const {full_name,email,password,role='member',sector_id=null,class_id=null}=req.body||{};
  if(!full_name||!email||!password) return res.status(400).json({error:'البيانات الأساسية ناقصة.'});
  if(!['site_admin','priest','secretary','servant','member'].includes(role)) return res.status(400).json({error:'نوع الحساب غير صحيح.'});
  const allowed:Record<string,string[]>={site_admin:['priest','secretary','servant','member'],priest:['secretary','servant','member'],secretary:['servant','member'],servant:['member']};
  if(!allowed[actor.role]?.includes(role)) return res.status(403).json({error:'لا يمكنك إنشاء هذا النوع من الحسابات.'});

  if(role==='servant' && !sector_id) return res.status(400).json({error:'يجب تحديد قطاع الخادم.'});
  if(actor.role==='servant' && sector_id!==actor.sector_id) return res.status(403).json({error:'الخادم لا يمكنه إنشاء حساب خارج قطاعه.'});

  let classRow:any=null;
  if(role==='member'){
   if(!class_id) return res.status(400).json({error:'يجب اختيار فصل للمخدوم.'});
   const cr=await db(`classes?select=id,sector_id,servant_id& id=eq.${encodeURIComponent(class_id)}&limit=1`.replace(' &','&'));
   classRow=cr?.[0];
   if(!classRow) return res.status(400).json({error:'الفصل المختار غير موجود.'});
   if(sector_id && sector_id!==classRow.sector_id) return res.status(400).json({error:'القطاع لا يطابق قطاع الفصل.'});
   if(actor.role==='servant' && classRow.sector_id!==actor.sector_id) return res.status(403).json({error:'لا يمكنك إضافة مخدوم إلى فصل خارج قطاعك.'});
   if(actor.role==='servant' && classRow.servant_id && classRow.servant_id!==actor.id) return res.status(403).json({error:'هذا الفصل مسند إلى خادم آخر.'});
  }

  const finalSector=sector_id || classRow?.sector_id || null;
  const cr=await fetch(`${url}/auth/v1/admin/users`,{method:'POST',headers:{apikey:service,Authorization:`Bearer ${service}`,'Content-Type':'application/json'},body:JSON.stringify({email,password,email_confirm:true,user_metadata:{full_name}})});
  const user=await parseResponse(cr);
  if(!cr.ok) return res.status(cr.status).json({error:user?.msg||user?.message||user?.error_description||'فشل إنشاء حساب الدخول'});

  try{
   await db('profiles',{method:'POST',headers:{Prefer:'return=minimal'},body:JSON.stringify({id:user.id,full_name,username:email,email,role,sector_id:finalSector,class_id:role==='member'?class_id:null,active:true})});
  }catch(profileError:any){
   // Best effort cleanup so a failed profile insert does not leave an orphan Auth user.
   await fetch(`${url}/auth/v1/admin/users/${encodeURIComponent(user.id)}`,{method:'DELETE',headers:{apikey:service,Authorization:`Bearer ${service}`} }).catch(()=>{});
   throw profileError;
  }
  return res.status(200).json({id:user.id});
 }catch(e:any){return res.status(500).json({error:e.message||'Unexpected error'})}
}
