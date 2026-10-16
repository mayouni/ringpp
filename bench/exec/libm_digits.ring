# THE MATHS BUILTINS ARE THE C LIBRARY'S, to the last digit.
#
# Ring's sin, cos, exp, log, pow ... are the C runtime's (math_e.c), so on
# each platform they answer that platform's libm, digit for digit. Ring++
# used Zig's implementations -- accurate, and not the same functions: at 17
# decimals exp(1.8326) was ...049772 on glibc and ...049683 in Zig, and
# pow(1.1, 7.3) differed on Windows. A network trained on data made with
# sin and cos (numeric_embedding) turned that last bit into an assertion
# Ring passes and Ring++ failed on Linux, three runs of three. On Linux the
# functions are taken from libm.so.6 by name, because Zig's compiler-rt
# defines exp, sin and log inside the binary and the link picked those.
# Run on both platforms: bench/exec.py and bench/exec_wsl.py. 2026-09-28.
decimals(17)
for k = 1 to 12
	t = k * 0.2617993877991494
	? "" + k + " sin " + sin(t) + " cos " + cos(t) + " exp " + exp(t) + " log " + log(t + 1) + " sqrt " + sqrt(t)
next
? "tan " + tan(1.2) + " atan " + atan(0.7) + " atan2 " + atan2(0.7, -1.3) + " pow " + pow(1.1, 7.3)
? "asin " + asin(0.3) + " acos " + acos(0.3) + " sinh " + sinh(1.7) + " cosh " + cosh(1.7) + " tanh " + tanh(0.4)
? "log10 " + log10(7.77) + " exp(-3.1) " + exp(-3.1) + " pow(2.5, -1.7) " + pow(2.5, -1.7)
