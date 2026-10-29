// Runs the real application renderers with isolated sample data. No backend writes.
import assert from 'node:assert/strict';
import { readFileSync,writeFileSync,mkdirSync } from 'node:fs';
import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { resolve } from 'node:path';

const original=readFileSync('dist/assets/app.js','utf8');
assert.ok(original.endsWith('initAuth();\n')||original.trimEnd().endsWith('initAuth();'));
const fixtures=`
session={user:{id:'qa-user',email:'preview@example.test'}};
userProfile={full_name:'Amaya Perera',platform_role:'system_admin'};
currentMembership={role:'owner'};
currentOrg={id:'qa-org',name:'Hich Studio',business_type:'salon',industry:'salon',booking_slug:'preview',email:'hello@example.test'};
orgSettings={currency:'LKR',enabled_modules:Object.keys(renderers),preferences:{onboarding_completed:true,opening_time:'08:00',closing_time:'18:00'}};
state=structuredClone(defaults);
state.employees=state.employees.map((person,i)=>({...person,id:'staff-'+i,bookable:true,employmentStatus:'active',department:person.dept,location_id:'branch',salary:person.salary||120000}));
state.products=state.products.map((product,i)=>({...product,id:'product-'+i,location_id:'branch'}));
salonLocations=[{id:'branch',name:'Colombo Studio',city:'Colombo',active:true,is_primary:true,employee_login_slug:'preview'}];
retailCustomers=[{id:'customer',name:'Nethmi Silva',customer_code:'CUS-1048',phone:'0771234567',email:'nethmi@example.test',city:'Colombo',address:'24 Flower Road',loyalty_balance:1250,total_spent:84500,visits:8,tags:['Regular client'],marketing_consent:true,created_at:new Date().toISOString()}];
salonServices=[{id:'cut',name:'Haircut & styling',category:'Hair',price:4500,duration_minutes:60,active:true},{id:'facial',name:'Signature facial',category:'Beauty',price:6500,duration_minutes:90,active:true}];salonAllServices=salonServices;
const today=new Date();today.setHours(10,0,0,0);
salonAppointments=[{id:'booking',staff_id:'staff-0',staff_name:'Amaya Perera',customer_name:'Nethmi Silva',customer_phone:'0771234567',service_id:'cut',service_name:'Haircut & styling',price:4500,starts_at:today.toISOString(),ends_at:new Date(+today+3600000).toISOString(),status:'confirmed',workflow_stage:'confirmed',location_id:'branch',source:'public_booking'}];
posRecentOrders=Array.from({length:10},(_,i)=>({id:'order-'+i,customer_id:'customer',customer_name:'Nethmi Silva',receipt_number:'POS-'+(1048-i),created_at:new Date(Date.now()-i*86400000).toISOString(),total:4500+i*1200,subtotal:4500+i*1200,payment_method:'cash',payment_status:'paid',status:'completed',location_id:'branch',items:[]}));
systemAdminOrganizations=[{id:'qa-org',name:'Hich Studio',business_type:'salon',account_status:'active',subscription_status:'paid',created_at:today.toISOString(),plan_name:'Business',user_count:8,location_count:1}];
canManagePayroll=true;
$('#marketingSite').classList.add('hidden');$('#authShell').classList.add('hidden');$('#appShell').classList.remove('hidden');
$('.workspace-switcher strong').textContent='Hich Studio';$('.workspace-switcher small').textContent='Colombo workspace';
$('.user-copy strong').textContent='Amaya Perera';$('.user-copy small').textContent='Administrator';
$('.sidebar-account-name').textContent='Amaya Perera';$('.sidebar-account-role').textContent='Administrator';
window.themeQA={
 route(name){closeModal();$('#marketingSite').classList.add('hidden');$('#authShell').classList.add('hidden');$('#appShell').classList.remove('hidden');currentOrg.business_type=name==='automotive'?'automotive':name==='pharmacy'?'pharmacy':name==='pos'||name==='inventory'?'retail_grocery':'salon';render(name)},
 customer(){showCustomerProfile(retailCustomers[0])},
 auth(){showAuth('signin')},
 marketing(){showMarketing()},
 booking(){return showPublicBooking('preview')},
 routes:Object.keys(renderers).filter(name=>name!=='module')
};
render('home');
`;
const mock=`const qaBooking={org_id:'qa-org',salon:{name:'Hich Studio',address:'Colombo',phone:'0771234567'},salon_name:'Hich Studio',name:'Hich Studio',capacity:2,booking_slug:'preview',locations:[{id:'branch',name:'Colombo Studio',active:true}],services:[{id:'cut',name:'Haircut & styling',category:'Hair',price:4500,duration_minutes:60,active:true}],preferences:{opening_time:'08:00',closing_time:'18:00'}};
const qaQuery=new Proxy({},{get(_,key){if(key==='then')return resolve=>resolve({data:[],error:null});return ()=>qaQuery}});
const supabase={from:()=>qaQuery,rpc:async()=>({data:qaBooking,error:null}),auth:{signOut:async()=>({})}};`;
const script=original.replace(/^import .*?;\s*/,mock+'\n').replace(/initAuth\(\);\s*$/,fixtures);
const html=readFileSync('dist/index.html','utf8');
const server=createServer((req,res)=>{
 const path=new URL(req.url,'http://localhost').pathname;
 if(path==='/assets/app.bundle.js'){res.writeHead(200,{'content-type':'text/javascript'});res.end(script);return}
 if(['/assets/styles.css','/assets/schedule-reference.css','/assets/system-theme.css'].includes(path)){res.writeHead(200,{'content-type':'text/css'});res.end(readFileSync('dist'+path));return}
 res.writeHead(200,{'content-type':'text/html'});res.end(html);
});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
mkdirSync('.chrome-qa/theme',{recursive:true});
const browser=spawn('C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',['--headless=new','--disable-gpu','--no-first-run','--no-default-browser-check','--remote-debugging-port=9251',`--user-data-dir=${resolve('.chrome-qa/theme/browser')}`,'about:blank'],{windowsHide:true,stdio:'ignore'});
const delay=ms=>new Promise(resolve=>setTimeout(resolve,ms));
let socket;const errors=[];const reports=[];
try{
 let tabs;for(let i=0;i<80;i++){try{tabs=await(await fetch('http://127.0.0.1:9251/json')).json();break}catch{await delay(100)}}
 assert.ok(tabs,'Chrome did not start');
 socket=new WebSocket(tabs.find(tab=>tab.type==='page').webSocketDebuggerUrl);
 await new Promise(resolve=>socket.addEventListener('open',resolve,{once:true}));
 const pending=new Map();let nextId=0;
 socket.onmessage=event=>{const message=JSON.parse(event.data);if(message.id){pending.get(message.id)?.(message);pending.delete(message.id)}else if(message.method==='Runtime.exceptionThrown')errors.push(message.params.exceptionDetails.exception?.description||message.params.exceptionDetails.text)};
 const send=(method,params={})=>new Promise((resolve,reject)=>{const id=++nextId;pending.set(id,message=>message.error?reject(new Error(message.error.message)):resolve(message.result));socket.send(JSON.stringify({id,method,params}))});
 const evaluate=async expression=>{const response=await send('Runtime.evaluate',{expression,returnByValue:true,awaitPromise:true});if(response.exceptionDetails)throw new Error(response.exceptionDetails.exception?.description||response.exceptionDetails.text);return response.result.value};
 const shot=async name=>writeFileSync(`.chrome-qa/theme/${name}.png`,Buffer.from((await send('Page.captureScreenshot',{format:'png',captureBeyondViewport:false})).data,'base64'));
 await send('Runtime.enable');await send('Page.enable');
 await send('Emulation.setDeviceMetricsOverride',{width:1440,height:1100,deviceScaleFactor:1,mobile:false});
 await send('Page.navigate',{url:`http://127.0.0.1:${server.address().port}`});
 for(let i=0;i<80;i++){if(await evaluate('Boolean(window.themeQA)'))break;await delay(100)}
 assert.ok(await evaluate('Boolean(window.themeQA)'),errors.join('\n')||'Application did not initialize');
 await evaluate('document.fonts.ready');
 const routes=await evaluate('themeQA.routes');
 for(const route of routes){
  await evaluate(`themeQA.route(${JSON.stringify(route)})`);await delay(80);
  const result=await evaluate(`({route:location.hash||'home',width:innerWidth,scroll:document.documentElement.scrollWidth,background:getComputedStyle(document.querySelector('.main-area')).backgroundColor,primary:document.querySelector('#page .btn.primary')?getComputedStyle(document.querySelector('#page .btn.primary')).backgroundColor:null,text:document.querySelector('#page').innerText.length})`);
  assert.ok(result.text>20,route+' failed to render');assert.ok(result.scroll<=result.width+1,route+' desktop overflow');assert.equal(result.background,'rgb(255, 255, 255)',route+' background');
  if(result.primary)assert.equal(result.primary,'rgb(29, 81, 71)',route+' primary action');
  reports.push({route,desktop:true});
  if(['home','people','customers','finance','pos','salon','settings','system_admin','services'].includes(route))await shot(route+'-desktop');
 }
 await evaluate('themeQA.route("customers");themeQA.customer()');await delay(250);
 const drawer=await evaluate(`(()=>{const b=document.querySelector('.customer-profile-modal').getBoundingClientRect();return {left:b.left,right:b.right,width:b.width,viewport:innerWidth}})()`);
 assert.ok(Math.abs(drawer.viewport-drawer.right-18)<2,'Customer drawer is not right aligned');await shot('customer-drawer-desktop');
 await evaluate('document.querySelector("[data-close-modal]").click()');
 assert.ok(await evaluate('!document.querySelector("#modalLayer").classList.contains("open")'));
 await evaluate('themeQA.route("people");document.querySelector("[data-people-tab=departments]").click()');
 assert.ok(await evaluate('document.querySelector("[data-people-tab=departments]").classList.contains("active")'));
 for(const width of [390,768]){
  await send('Emulation.setDeviceMetricsOverride',{width,height:844,deviceScaleFactor:1,mobile:true});await delay(250);
  for(const route of ['home','people','customers','finance','pos','salon','settings','services','access_control','system_admin']){
   await evaluate(`themeQA.route(${JSON.stringify(route)})`);await delay(80);
   const layout=await evaluate('({scroll:document.documentElement.scrollWidth,width:innerWidth,sidebar:document.querySelector(".sidebar").getBoundingClientRect().right})');
   assert.ok(layout.scroll<=width+1,`${route} overflows at ${width}px: ${JSON.stringify(layout)}`);assert.ok(layout.sidebar<=1,'Mobile sidebar covers content');
   if(width===390&&['home','people','pos','salon'].includes(route))await shot(route+'-mobile');
  }
 }
 await evaluate('document.querySelector("#openNav").click()');await delay(250);
 assert.ok(await evaluate('document.querySelector(".sidebar").getBoundingClientRect().left>=-1'),'Mobile navigation failed to open');
 await evaluate('document.querySelector("#closeNav").click()');
 await send('Emulation.setDeviceMetricsOverride',{width:1440,height:1100,deviceScaleFactor:1,mobile:false});
 await evaluate('themeQA.auth()');await shot('signin-desktop');
 assert.equal(await evaluate('getComputedStyle(document.querySelector(".auth-submit")).backgroundColor'),'rgb(29, 81, 71)');
 await evaluate('themeQA.marketing()');await shot('public-home-desktop');
 await send('Emulation.setDeviceMetricsOverride',{width:390,height:844,deviceScaleFactor:1,mobile:true});await delay(250);
 assert.ok(await evaluate('document.documentElement.scrollWidth<=innerWidth+1'),'Public home mobile overflow');await shot('public-home-mobile');
 await evaluate('themeQA.booking()');
 await delay(500);
 assert.ok(await evaluate('Boolean(document.querySelector("#publicBookingForm"))'),'Public booking form did not render');
 assert.ok(await evaluate('document.documentElement.scrollWidth<=innerWidth+1'),'Public booking mobile overflow');await shot('booking-mobile');
 await send('Emulation.setDeviceMetricsOverride',{width:1440,height:1100,deviceScaleFactor:1,mobile:false});await delay(250);await shot('booking-desktop');
 assert.equal(errors.length,0,errors.join('\n'));
 writeFileSync('.chrome-qa/theme/results.json',JSON.stringify({routes:reports,mobileWidths:[390,768],drawer:true,tabs:true,navigation:true,authentication:true,publicHome:true,uncaughtErrors:errors},null,2));
 console.log(`Passed ${reports.length} real module renderers, desktop/mobile layout, primary action colors, customer drawer, employee tabs, mobile navigation, sign-in, and public home. No backend writes.`);
 await send('Browser.close');
}finally{socket?.close();browser.kill();server.close()}
