# PPMS — Petrol Pump Management System

**Sabse pehle [HANDOFF.md](HANDOFF.md) padho.** Usme hai ki kaam kahan tak pahucha aur
agla step kya hai (file aur line number ke saath).

Ye project ek petrol pump ka software hai jise **poore India ke liye multi-tenant SaaS**
banaya ja raha hai. Abhi ek pump par chal raha hai.

---

## Is repo ke niyam

**1. Database ka ek hi source hai — `PPMS-DB-02-08-2026.sql`**

Woh ek complete self-contained build script hai. **Ek baar chalane se poora DB ban
jaata hai** — dobara chalane ki zaroorat nahi (2026-09-05 se; pehle ek chhupa hua
ordering bug tha jiski wajah se do baar chalana padta tha). Dobara chalao to bhi
0 error aur kuch duplicate nahi banta.

Fresh DB me **koi demo data nahi** hota — sirf menus, GST states, subscription plans
aur `superadmin` login.

Purani saari alag-alag SQL scripts jaanbujh ke delete ki gayi thi.

> **Naya SQL likhte waqt dhyan rakhein:** file DO HISSON me hai. PART 2 me bahut se
> column aur table baad me add hote hain (`Owners.ValidUpto`, `ProductRateHistory.EffectiveFrom`,
> soft-delete columns, waghairah). Jo bhi cheez un par nirbhar hai, use **file ke ANT me**
> likhein — PART 1 me likhne par "Invalid column name" milega. Do baar yahi galti ho
> chuki hai (`fn_ProductRateOnDate` aur bootstrap block).

**Naya SQL kaam bhi isi file me jodna hai — alag script mat banana.**

```bash
sqlcmd -S <server> -U <user> -P <password> -I -i "PPMS-DB-02-08-2026.sql" -o build-log.txt
```

`-I` flag zaroori hai (filtered indexes ko `QUOTED_IDENTIFIER ON` chahiye). Log ke aakhir me
HEALTH CHECK report hai.

**2. Ye folder git repo NAHI hai**

Koi version history nahi. Har badlav se pehle backup lo — undo ka koi rasta nahi hai.

**3. Test sach me chalake karo, sirf code padh kar nahi**

Is project me bug padhne se nahi milte. Asli run se mile: missing `udt_RoleMenuType` type,
`sp_Shift_Collection_Summary` ka DTO mismatch (endpoint hamesha 500 de raha tha), aur
`sp_Auth_Login` me extra column daalne se login toot jaana.

- **DB test**: `(localdb)\MSSQLLocalDB` — SQL Server 2025, full rights hain.
  `.\SQLEXPRESS` par `CREATE DATABASE` ka permission nahi hai, wahan test mat karna.
- **API test**: built dll seedha chalao, env vars ke saath:
  `dotnet bin\Debug\net8.0\PPMS.Api.dll`
- Test ke baad test DB aur `PPMSUser` login drop kar dena.

**4. Local par app kaise chalayen (2026-09-03 se)**

Pehle `appsettings.Development.json` me production server (`103.235.104.111`) ki
connection string padi thi, isliye `dotnet run` khatarnaak tha. **Ab wo LocalDB par
point karti hai**, to local par chalana surakshit hai:

```bash
dotnet run --project src/API/PPMS.Api/PPMS.Api.csproj          # http://localhost:5258
dotnet run --project src/Client/PPMS.Client.Web/PPMS.Client.Web.csproj  # http://localhost:5131
```

Login: `superadmin` / `password123`.

**(2026-09-05 se DB me koi demo data nahi hai.)** Pehle script "Vikash Filling Center"
wala poora demo pump bana deti thi. Ab fresh DB me sirf menus, GST states,
subscription plans aur ek `superadmin` login hota hai — aur kuch nahi.

Pehla pump khud banana padta hai:

1. `superadmin` / `password123` se login karein
2. **Super Admin → Create Tenant** — owner ka naam, admin username aur password dein
   (ya login page par "7 din free trial" wala self-signup)
3. Ye `sp_Owner_Create` chalata hai, jo owner + Admin role + admin user + RoleMenus +
   pehla pump ek saath bana deta hai
4. Us naye admin se login karke dashboard ki "Set up your pump" checklist follow karein

`superadmin` ka password pehle login ke baad turant badal dein.

- Local DB `(localdb)\MSSQLLocalDB` par `PPMSDB` naam se bana hua hai. SSMS me dekhna
  ho to Server name me `(localdb)\MSSQLLocalDB` likhein.
- `localhost\SQLEXPRESS` par DB **nahi** ban sakta — us Windows user ko `CREATE DATABASE`
  ka permission nahi hai (na hi wo local Administrators me hai). SQLEXPRESS par chalana
  ho to IT admin se `HIL\EX-454` ko `dbcreator` ya `sysadmin` role dilwana padega,
  uske baad wahi script wahan chala dena.
- **`appsettings.json` bhi ab LocalDB par hai** (pehle usme production ki connection
  string + plaintext password `[hataya]` pada tha). Production par deploy karte waqt
  server par `ConnectionStrings__DefaultConnection` environment variable set karna
  **zaroori** hai — warna app LocalDB dhoondhega. Env var hamesha file se upar rehta hai.

**5. Dapper + records ka rule**

Har repository Dapper aur stored procedures use karti hai, aur DTOs positional `record` hain.
Dapper record ko constructor se banata hai, isliye **SP ke har column ka DTO me param hona
chahiye** — warna runtime par `InvalidOperationException`. SP me column add karo to DTO bhi
usi waqt update karo.

---

## Structure

```
PPMS-DB-02-08-2026.sql       <- poora database, ek hi file
HANDOFF.md                   <- kaam kahan tak pahucha, agla step
src/API/                     <- PPMS.Api (minimal APIs) + Application / Infrastructure / Domain / Shared
src/Client/                  <- PPMS.Client.Web (MVC + session auth)
docs/                        <- Hindi user manuals
```

Stack: .NET 8, Dapper + stored procedures, SQL Server, Bootstrap/jQuery MVC client.

## Tenant isolation

`OwnerId` **hamesha** JWT claim se aata hai — client ke query string ya request body se kabhi
nahi. `TenantIsolationMiddleware` dono ko clean karta hai; jo endpoints sirf id lete hain un par
`ITenantGuard` ownership check karta hai. Naya endpoint likho to yahi pattern follow karna —
`ResolveOwnerId(user, null)` use karo, aur id-based endpoint ho to guard lagao.
