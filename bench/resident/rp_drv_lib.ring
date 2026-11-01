# RUNG 3 from the driver: `rnxc resident rp_drv_lib.ring rp_drv_v2.ring
# --replace rp_drv_v2.ring --replace rp_drv_none.ring` (bench/resident.py)
? "drv lib: " + Bill(5)

func Tax n
	return n * 2

func Bill n
	return "bill " + Tax(n)
