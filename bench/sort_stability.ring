# A multi-key sort, the way every business report is built:
# sort by the SECONDARY key first, then by the PRIMARY key.
# This is correct if and only if the sort is STABLE.

aStaff = [
    ["Sales",  "Ali"  ],
    ["Eng",    "Zoe"  ],
    ["Sales",  "Bob"  ],
    ["Eng",    "Amy"  ],
    ["Sales",  "Cid"  ],
    ["Eng",    "Mo"   ]
]

# pass 1: by name (column 2)
aP1 = sort(aStaff, 2)
? "after pass 1 (by name):"
for r in aP1 ? "   " + r[1] + " / " + r[2] next

# pass 2: by department (column 1). A STABLE sort keeps names ordered
# inside each department.
aP2 = sort(aP1, 1)
? ""
? "after pass 2 (by department) -- names must still be A-Z inside each dept:"
for r in aP2 ? "   " + r[1] + " / " + r[2] next
