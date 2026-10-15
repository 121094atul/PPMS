# -*- coding: utf-8 -*-
"""datetime-local wale box par asp-format lagao.

asp-for khud yyyy-MM-ddTHH:mm wala format tabhi lagata hai jab type wo KHUD
tay kare. Yahan type haath se likha hua hai, isliye value culture ke default
roop me chhapti thi ("09/08/2026 00:00:00") jise browser datetime-local ke
liye galat maanta hai — box KHAALI reh jaata tha.

Khaali box + non-nullable DateTime = "field is required" validation, aur form
chupchap ruk jaata tha. Yahi Dip Testing par ho raha tha.
"""
import io, re

FILES = [
    'Views/Operations/Cashbook.cshtml',
    'Views/Operations/CouponBooks.cshtml',
    'Views/Operations/Expenses.cshtml',
    'Views/Operations/Sales.cshtml',
    'Views/Operations/TankStock.cshtml',
]
RE = re.compile(r'(<input\s+asp-for="[^"]+"\s+)type="datetime-local"')

for f in FILES:
    s = io.open(f, encoding='utf-8').read()
    if 'asp-format' in s and 'datetime-local' in s:
        pass
    new, n = RE.subn(lambda m: m.group(1) + 'type="datetime-local" asp-format="{0:yyyy-MM-ddTHH:mm}"', s)
    if n:
        io.open(f, 'w', encoding='utf-8', newline='').write(new)
    print('%-42s %d' % (f, n))
