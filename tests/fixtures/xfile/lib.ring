# Defines the function the OTHER file miscalls. The point of this pair:
# until the project layer existed, ringpp check could not see across files
# at all, and this defect was invisible.
func Helper a, b
    return a + b
