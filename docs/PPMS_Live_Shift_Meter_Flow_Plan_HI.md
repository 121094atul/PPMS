# PPMS Live Practical Plan (Shift + Meter Based Operations)

## 1) Exact answer: kitne forms change honge?

Live practical petrol pump flow (rush cash + machine slip model) ke liye total **12 forms/screens** impact honge.

### A) Major functional changes (8 forms)
1. `Shifts`  
   - Operator assignment  
   - Nozzle opening meter capture  
   - Nozzle closing meter capture  
   - Auto liters/value/variance summary at close
2. `Sales`  
   - Default mode: optional/manual billing only  
   - Credit/customer receipt mode separate guidance  
   - Rush cash ke liye per-customer mandatory entry hataana
3. `Nozzles`  
   - Nozzle metadata (active/inactive, optional calibration reference)
4. `Cashbook`  
   - Shift-based cash reconciliation (expected vs actual)
5. `Expenses`  
   - Shift/operator tag strong validation
6. `DayBook`  
   - Shift-wise liters/amount/operator summary
7. `Reports`  
   - Shift productivity report + operator report
8. `Dashboard`  
   - Open shifts, active operators, today liters, sales by pump/nozzle

### B) Supporting/admin changes (4 forms)
9. `Users`  
   - Operator identity and active assignment readiness
10. `Roles`  
   - Shift operator permissions (open/close + meter only)
11. `Pump Comparison`  
   - Meter-derived sales accuracy alignment
12. `ReceiptPrint`  
   - Optional: show shift/operator/nozzle summary for manual bills

---

## 2) Practical flow (final target)

1. Shift open with selected pump + operator.
2. Each nozzle opening meter feed.
3. Shift run (machine handles cash slips, system per-customer optional).
4. Shift close with closing meter.
5. System calculates:
   - liters sold (`closing - opening`)
   - amount (`liters * rate`)
   - operator/pump/nozzle totals
6. Cash, expense, variance reconciliation.

---

## 3) Backend/DB changes required

### Database (mandatory)
- `PUMP.ShiftHeaders`:
  - `OperatorUserId BIGINT NULL` (or mandatory as per policy)
- New table:
  - `PUMP.ShiftNozzleReadings`
  - columns: `ShiftId, NozzleId, ProductId, OpeningReading, ClosingReading, Rate, SoldQty, SoldAmount, VarianceQty, Notes`
- SP updates/new:
  - `sp_Shift_Open` (operator + opening readings)
  - `sp_Shift_Close` (closing readings + auto calc)
  - `sp_Shift_List` (operator name + totals)
  - report SPs for operator-wise/pump-wise summary

### API/Application
- `OpenShiftRequest`, `CloseShiftRequest`, `ShiftDto` extend
- Shift service/repository logic update
- New DTOs for nozzle reading rows
- Sales flow switch: optional receipt entry mode

### Client
- Shift page grid for nozzle readings at open/close
- Sales page UX changed to non-mandatory bulk rush mode
- Reports/dashboard widgets update

---

## 4) Implementation strategy (safe for live rollout)

### Phase 1 (core operations, go-live blocker) - mandatory first
- Shifts + nozzle opening/closing + auto liters/value
- Operator assignment
- Shift close reconciliation

### Phase 2 (controls and reporting)
- Dashboard + DayBook + Reports aligned with meter flow
- Cashbook/Expense shift linkage validation

### Phase 3 (optional/manual sales hardening)
- Sales page as optional manual/credit billing mode
- Receipt and audit refinements

---

## 5) What changes right now should be done first?

Live जाने से पहले **minimum mandatory**:
1. Shift + meter entry model
2. Operator mapping in shift
3. Auto liters/value calculation
4. Shift close reconciliation report

Without above, project operationally practical nahi rahega for real pump rush workload.
