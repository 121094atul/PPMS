# PPMS Current Functional Process Document (Hindi)

## 1) Document Purpose
Ye document current software ke practical usage flow ko define karta hai:
- Kaun sa user kya kaam karega
- Kaun sa module kis module par depend karta hai
- Kis form ka data kis dusre form/report ko impact karta hai

## 2) Current User Roles aur Primary Responsibility

| Role | Login | Main Kaam |
|---|---|---|
| OwnerAdmin | owneradmin / admin@123 | Full setup, masters, monitoring, audit decisions |
| PumpManager | pumpmanager / manager@123 | Daily operations control, shift supervision, stock/cash review |
| Accountant | accountant / account@123 | Cashbook, expenses, ledger, salary register, financial cleanup |
| SalesOperator | salesop / sales@123 | Shift open/close input, sales entry (where required), field operations |
| Auditor | auditor / audit@123 | Read-only validation, reports review |

## 3) High-Level End-to-End Process (Daily)
1. OwnerAdmin/PumpManager initial readiness check kare.
2. Employee/operator mapping verify ho (Employees form).
3. Shift open ho: pump, operator, opening cash, nozzle opening readings.
4. Sales runtime chale: cash/manual/credit entries as per process.
5. Tank stock/purchase/reconcile updates kiye jayein.
6. Cashbook + expenses + ledger updates karein.
7. Shift close ho: closing cash + nozzle closing readings.
8. DayBook/Reports se reconciliation verify karein.
9. Salary month-end me Salary Register se post ho.

## 4) Module Dependency Map (What must exist first)

| Module/Form | Depends On |
|---|---|
| Users | Roles |
| Employees | Pumps, Users (optional mapping) |
| Products | Pumps |
| Nozzles | Pumps, Products |
| Tanks | Pumps, Products |
| Parties | Pumps |
| Shift | Pumps, Employees (operator), Nozzles, Products |
| Sales | Shift (open), Products, Nozzles, Parties (for credit) |
| Purchase | Pumps, Vendors, Products, Tanks |
| Tank Stock | Tanks |
| Stock Reconcile | Tanks, Tank Stock history |
| Cashbook | Pumps, optional Shift |
| Expenses | Pumps, Expense Heads, optional Shift |
| Party Ledger | Parties |
| Salary Register | Employees |
| DayBook/Reports | Sales + Cashbook + Expenses + Shift + Ledger + Stock |

## 5) Form-to-Form Data Impact (Important)

### 5.1 Pump form impact
- Pump create/update hone par: Products, Nozzles, Tanks, Parties, Shift, Sales, Purchase, Cashbook, Expenses sab me pump selector data badalta hai.

### 5.2 Product form impact
- Product rate change hone par Sales line default rate, Shift nozzle rate snapshot, purchase item mapping impact hota hai.

### 5.3 Nozzle form impact
- Shift opening/closing nozzle reading rows nozzle master se bante hain.
- Sales me nozzle selection isi list se aata hai.

### 5.4 Employees form impact
- Shift open operator dropdown employee-user mapping se fill hota hai.
- Salary Register employee list yahin se aati hai.

### 5.5 Shift form impact
- Open shift ke bina Sales entry allowed nahi honi chahiye.
- Shift close readings se sold qty/sold amount summary banti hai.
- DayBook aur dashboard shift totals use karte hain.

### 5.6 Sales form impact
- Party credit sale hone par Party current balance aur Party Ledger impact hota hai.
- Sales totals dashboard, reports, daybook me reflect hote hain.

### 5.7 Purchase/Tank Stock/Reconcile impact
- Tank stock levels aur variance report directly affect hote hain.
- Reports me stock movement aur mismatch visible hota hai.

### 5.8 Cashbook + Expenses impact
- Daily cash position aur daybook entries direct impact.
- Shift cash variance analysis me indirect contribution.

### 5.9 Salary Register impact
- Accountant month-wise salary payment track karta hai.
- Employee cost monitoring reports ke liye source banta hai.

## 6) Current Menu Visibility (Latest Mapping)
- OwnerAdmin: all active menus
- PumpManager: operations + employees
- Accountant: accounts + reports + employees + salary
- SalesOperator: dashboard + shift + sales
- Auditor: read-only reports set

## 7) Critical Business Rules (Current + Recommended)
1. Shift close tab tak allow na ho jab tak required nozzle closing readings na aayen.
2. Closing reading opening se kam ho to reject karo.
3. Duplicate employee code same pump par reject karo.
4. Salary same employee-month par duplicate insert ki jagah update/upsert ho.
5. API me owner/pump filter strict rahe.

## 8) First-Time Setup Sequence (Mandatory)
1. DDL scripts (including 013 and 014).
2. Seed scripts (001 then 002).
3. SP scripts (including 004, 005, 010, 014).
4. API run.
5. Client run.
6. OwnerAdmin se smoke test:
- Employees save
- Shift open/close
- Sales save
- Expense save
- Salary save

## 9) Role-Wise Practical Usage

### 9.1 OwnerAdmin
- Masters maintain kare, user-role governance kare, daily exception review kare.

### 9.2 PumpManager
- Pump operation run kare, shifts monitor kare, stock/cash discrepancies escalate kare.

### 9.3 Accountant
- Cashbook, expenses, party ledger, salary register maintain kare.

### 9.4 SalesOperator
- Shift opening/closing operational fields fill kare.
- Sales entry only where manual system requirement hai.

### 9.5 Auditor
- Reports, daybook, outstanding, stock variance verify kare.

## 10) Known Current Gaps (Before Full Live Rollout)
- Menu seed me standalone upsert logic sab new routes ke liye ensure karna.
- Shift hard-validation (all nozzles mandatory close) DB+API me hard enforce karna.
- API startup health check me required table/SP readiness verify karna.
- Process lock-safe dev run script standardize karna.

## 11) Recommended Operational SOP
1. Day start: shift open + operator assignment + opening readings.
2. Day run: sales/purchase/expense/cash entries as required.
3. Day end: shift close + closing readings + cash close.
4. Accountant close: daybook + ledger + salary (month-end).
5. Manager review: variance + outstanding + stock alerts.

---
Ye document current implemented behavior + practical operation alignment ke liye banaya gaya hai.
