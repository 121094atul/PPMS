/*  PPMS service worker
 *  ─────────────────────────────────────────────────────────────────────────
 *  Iska kaam sirf itna hai: app ko home screen se khulne layak banana, aur
 *  internet na hone par saaf sandesh dikhana (browser ka bhadda dinosaur page
 *  nahi).
 *
 *  >>> LOGIN KE BAAD KA KOI PAGE CACHE NAHI HOTA. <<<
 *
 *  Ye jaanbujh kar hai, do wajah se:
 *    1. Har page us tenant ka apna data dikhata hai. Pump par ek hi phone kai
 *       log istemaal karte hain — cache me pada page agle aadmi ko dikh jaata.
 *    2. Rate, stock, udhaar ka balance — ye purane dikhe to galat faisle honge.
 *       Isse achha hai saaf keh dena "internet nahi hai".
 *
 *  Sirf wo cheezein cache hoti hain jo har kisi ke liye ek jaisi hain: CSS,
 *  JS, icon, font. Unme kisi ka data nahi hota.
 */

// Ye number badalte hi purana cache khud saaf ho jaata hai. CSS/JS badlein to
// yahan bhi badal dein, warna user ko purani file mil sakti hai.
const CACHE = 'ppms-static-v1';

const OFFLINE_URL = '/offline.html';

// Shuru me hi rakh lene wali cheezein — inke bina offline page bhi bhadda dikhega.
const PRECACHE = [
    OFFLINE_URL,
    '/css/site.css',
    '/js/site.js',
    '/lib/bootstrap/dist/css/bootstrap.min.css',
    '/lib/bootstrap/dist/js/bootstrap.bundle.min.js',
    '/lib/jquery/dist/jquery.min.js',
    '/images/icon-192.png',
    '/images/icon-512.png',
    '/favicon.ico'
];

self.addEventListener('install', (event) => {
    event.waitUntil((async () => {
        const cache = await caches.open(CACHE);
        // Ek bhi file na mile to poora install fail na ho — isliye ek-ek karke.
        await Promise.all(PRECACHE.map(async (url) => {
            try { await cache.add(new Request(url, { cache: 'reload' })); }
            catch (e) { /* wo file nahi hai to chhod do */ }
        }));
        self.skipWaiting();          // naya worker turant chale
    })());
});

self.addEventListener('activate', (event) => {
    event.waitUntil((async () => {
        const names = await caches.keys();
        await Promise.all(names.map((n) => (n === CACHE ? null : caches.delete(n))));
        await self.clients.claim();
    })());
});

// Kya ye file har kisi ke liye ek jaisi hai? (matlab cache karna surakshit hai)
function isStaticAsset(url) {
    return url.origin === self.location.origin
        && /^\/(css|js|lib|images)\//.test(url.pathname);
}

self.addEventListener('fetch', (event) => {
    const req = event.request;

    // GET ke alawa kuch bhi chhuo mat — save/delete hamesha seedha server par.
    if (req.method !== 'GET') { return; }

    const url = new URL(req.url);

    // Doosri site ki cheezein hamare kaam ki nahi.
    if (url.origin !== self.location.origin) { return; }

    // Login/logout kabhi cache nahi — session ka mamla hai.
    if (/^\/Account\//i.test(url.pathname)) { return; }

    // ---- File download ko BILKUL haath mat lagao ----
    // CSV/Excel ka link dabane par browser use 'navigate' maanta hai. Neeche
    // wala navigate wala hissa uspar respondWith() laga deta tha — aur jaise hi
    // service worker kisi navigation ka jawab khud deta hai, Chrome us download
    // ko radd kar deta hai. Nateeja: Export dabao, kuch hota hi nahi.
    //
    // Ye PWA aur normal browser DONO me hota tha (service worker dono jagah
    // chalta hai), bas installed app me zyada dikhta tha.
    //
    // Content-Disposition to fetch ke BAAD hi pata chalta hai, isliye URL se
    // pehchante hain. Aise raaste par hum kuch nahi karte — browser khud
    // sambhal leta hai, aur download theek chalta hai.
    if (/(^\/[^?]*\/Export)|(\.csv|\.xlsx|\.xls|\.pdf)(\?|$)/i.test(url.pathname + url.search)
        || /export/i.test(url.pathname)) {
        return;
    }

    // ---- Static file: pehle cache, phir network ----
    if (isStaticAsset(url)) {
        event.respondWith((async () => {
            const cached = await caches.match(req);
            if (cached) { return cached; }
            try {
                const res = await fetch(req);
                if (res && res.ok) {
                    const cache = await caches.open(CACHE);
                    cache.put(req, res.clone());
                }
                return res;
            } catch (e) {
                return cached || Response.error();
            }
        })());
        return;
    }

    // ---- Page (HTML): HAMESHA server se ----
    // Cache karna hota to yahan karte — par upar likhi wajah se nahi karte.
    // Net na ho to offline page dikha dete hain.
    if (req.mode === 'navigate' || (req.headers.get('accept') || '').includes('text/html')) {
        event.respondWith((async () => {
            try {
                return await fetch(req);
            } catch (e) {
                const cache = await caches.open(CACHE);
                const offline = await cache.match(OFFLINE_URL);
                return offline || new Response(
                    '<h1>No internet</h1><p>Please check your connection and try again.</p>',
                    { status: 503, headers: { 'Content-Type': 'text/html' } });
            }
        })());
    }

    // Baaki sab (API call waghairah) ko haath nahi lagate.
});
