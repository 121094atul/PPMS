# PPMS Project Documentation + User Manual (Hindi)

## 1) Project me abhi kya-kya bana hua hai

### 1.1 Architecture
- `src/API/PPMS.Api` -> ASP.NET Core Web API
- `src/API/PPMS.Application` -> business services/contracts
- `src/API/PPMS.Infrastructure` -> Dapper repositories + DB access
- `src/API/PPMS.Domain` -> domain models
- `src/Client/PPMS.Client.Web` -> Razor based web client
- `Database/` -> DDL, Seed, Stored Procedures

### 1.2 Authentication aur Session
- JWT login (`/api/auth/login`)
- Refresh token (`/api/auth/refresh`)
- Logout (`/api/auth/logout`)
- Dynamic menu by role (`/api/menus/my`)
- Session based web login flow (client side)

### 1.3 Dashboard
- KPI dashboard available:
  - Total Sales
  - Today Sales
  - Total Expenses
  - Today Expenses
  - Outstanding
  - Open Shifts
  - Recent Sales
  - Top Outstanding Parties

### 1.4 Functional Modules (UI + API integrated)
- Pump Management
- Product Management
- Nozzle Management
- Tank Management
- Party Management
- Shift Open/Close
- Sales + Receipt Print
- Tank Stock Transactions
- Party Ledger
- Purchase
- Stock Reconciliation
- Cashbook
- Expenses
- Day Book Report
- Outstanding Report
- Pump Comparison Report
- Fleet Contracts
- Coupon Books + Coupon Transactions
- Users Management
- Roles Management

### 1.5 Database
- Relational SQL Server schema (`PUMP` schema)
- Users, Roles, Menus, UserRoles, RoleMenus implemented
- Master + transaction tables implemented
- Seed scripts available for owner, pump, roles, users, menus
- Stored procedures implemented across auth/master/operations

### 1.6 Latest Development Update (Recent Work Done)
- Product save flow improve kiya (API + service + repository + UI wiring)
- Nozzle save flow improve kiya (API + service + repository + UI wiring)
- Pump save flow improve kiya (API + service + repository + UI wiring)
- User save flow improve kiya (API + service + repository + UI wiring)
- Shift module enhancement (repository/service + SP update + API wiring + UI updates)
- Sales module enhancement (repository/service + SP update + API wiring + UI updates)
- Expense module enhancement (contracts + repository + SP update + API wiring + UI updates)
- Multiple SP scripts local DB par execute kiye gaye:
  - `Database/03_SP/004_sp_shift_management.sql`
  - `Database/03_SP/005_sp_sales_receipt_management.sql`
  - `Database/03_SP/010_sp_cash_expense_report.sql`
- Role-wise menu seeding refine ki gayi (different users ko different menu)
- Login diagnostics improve kiye gaye (invalid credentials vs API unreachable messages)

---

## 2) Sabse pehle login kaun karega? (Important)

Sabse pehle **OwnerAdmin** login kare:
- Username: `owneradmin`
- Password: `admin@123`

Kyun?
- OwnerAdmin ke paas full access hota hai.
- Pehle system verification, role/menu validation, aur initial setup OwnerAdmin karega.
- Uske baad PumpManager/Accountant/SalesOperator/Auditor users ko operation handover hoga.

---

## 3) First-Time Setup aur Login Manual (Step-by-Step)

## Step 1: Database scripts run karo
- Script order follow karo: `Database/README.md`
- Mandatory:
  1. DDL scripts
  2. `Database/02_Seed/001_seed_master_data.sql`
  3. `Database/02_Seed/002_seed_user_role_menu.sql`
  4. SP scripts

## Step 2: API run karo
- Command:
```powershell
dotnet run --project .\src\API\PPMS.Api\PPMS.Api.csproj
```
- API URL verify: `http://localhost:5258`

## Step 3: Client run karo
- Command:
```powershell
dotnet run --project .\src\Client\PPMS.Client.Web\PPMS.Client.Web.csproj
```
- Client config check:
  - `src/Client/PPMS.Client.Web/appsettings.json`
  - `Api:BaseUrl` should point to API (default `http://localhost:5258`)

## Step 4: OwnerAdmin se login karo
- Open: `/Account/Login`
- Enter:
  - Username: `owneradmin`
  - Password: `admin@123`
- Successful login ke baad dashboard open hoga.

## Step 5: Role-wise access verify karo
- Logout karo
- Niche diye users se login karke dekho:
  - `pumpmanager / manager@123`
  - `accountant / account@123`
  - `salesop / sales@123`
  - `auditor / audit@123`
- Har user ko alag menu aur limited access dikhna chahiye.

---

## 4) Demo Users aur unka kaam

## 4.1 OwnerAdmin
- Credentials: `owneradmin / admin@123`
- Kaam:
  - Full system control
  - User/Role setup
  - Masters + operations + reports
  - Initial configuration aur monitoring

## 4.2 PumpManager
- Credentials: `pumpmanager / manager@123`
- Kaam:
  - Pump level operations manage karna
  - Shift, Sales, Stock, Purchase, Party operations
  - Daily execution and supervision

## 4.3 Accountant
- Credentials: `accountant / account@123`
- Kaam:
  - Cashbook, Expenses, Ledger, Purchase reconciliation
  - Financial reports monitor karna
  - Outstanding follow-up support

## 4.4 SalesOperator
- Credentials: `salesop / sales@123`
- Kaam:
  - Shift open/close
  - Sales entry
  - Daily transaction execution

## 4.5 Auditor
- Credentials: `auditor / audit@123`
- Kaam:
  - Read-only verification
  - Reports, stock/ledger/audit review
  - No create/edit/delete

---

## 5) Daily Operating Sequence (Recommended)

1. `OwnerAdmin/PumpManager` pump and day readiness verify kare.
2. `SalesOperator` shift open kare.
3. `SalesOperator` sales entry kare, receipt print kare.
4. `Accountant` cashbook/expenses/ledger update kare.
5. `PumpManager` stock reconcile aur exceptions check kare.
6. `Auditor` reports validate kare.
7. Day end pe shift close, dashboard KPIs verify.

---

## 6) Common issues aur quick fix

## Login error: `API unreachable`
- API run nahi hai ya port mismatch hai.
- `Api:BaseUrl` verify karo.

## Login error: `Invalid username or password`
- Seed script rerun karo:
  - `002_seed_user_role_menu.sql`
- Ye script demo users ko `IsActive=1` aur expected password pe reset karta hai.

## Same menu sabko dikh raha hai
- Latest updated `002_seed_user_role_menu.sql` rerun karo.
- Isme role-wise menu matrix rebuild hota hai.

---

## 7) Security note (Current state)

- Demo credentials development/testing ke liye hain.
- Production me:
  - Strong passwords
  - Password rotation
  - User-wise secure onboarding
  - Strict DB + API hardening mandatory.

---

## 8) Technical Change Log (Summary from Latest Implementation)

## Backend/API
- `/api/products`, `/api/nozzles`, `/api/pumps`, `/api/users`, `/api/shifts`, `/api/sales`, `/api/expenses` flows me contract-service-repository chain align ki gayi.
- Program endpoint mappings me updates kiye gaye to support latest module behavior.
- Sales aur shift related business/service integration strengthen hua.

## Infrastructure/Repository
- Product, Nozzle, Pump, User repositories me save/list behavior adjustments.
- Sales repository me query/operation level improvements.
- Shift repository me API/SP compatibility related adjustments.
- Expense repository aur contracts me practical update.

## Database Stored Procedures
- `004_sp_shift_management.sql` update + execute
- `005_sp_sales_receipt_management.sql` update + execute
- `010_sp_cash_expense_report.sql` update + execute

## Client/UI
- `PPMSApiClient` me related module calls update.
- `OperationsController` me Product/Nozzle/Pump/User/Shift/Sales/Expense actions update.
- Views updated:
  - `Products.cshtml`
  - `Nozzles.cshtml`
  - `Pumps.cshtml`
  - `Users.cshtml`
  - `Shifts.cshtml`
  - `Sales.cshtml`
  - `Expenses.cshtml`

## Notes
- Changes se project functional coverage kaafi improve hua hai, especially operations modules.
- Role-wise menu and login behavior ko bhi aligned kiya gaya hai taaki real usage flow smooth rahe.
