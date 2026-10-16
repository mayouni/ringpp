# The plain builtins the estate calls, measured 2026-09-11 on both builds:
# find is strict on type and on strings raises; sort returns a copy, by
# bytes; insert puts the item AFTER position n; isalpha("") is 0; hex is
# lowercase; del is in place. Every case caught, so one file holds them.
a = [10, 20, 30, 20]
try ? "A find: " + find(a, 20) + " " + find(a, 99) + " " + find(a, "20") catch ? "A err " + cCatchError done
h = [ [:k, "x"], [:m, "y"] ]
try ? "B find col: " + find(h, "y", 2) + " " + find(h, :m, 1) catch ? "B err " + cCatchError done
s = [3, 1, 2]
t = sort(s)
try ? "C sort: " + t[1] + t[2] + t[3] + " orig " + s[1] + s[2] + s[3] catch ? "C err " + cCatchError done
w = ["b", "A", "c"]
try u = sort(w) ? "D sort strings: " + u[1] + u[2] + u[3] catch ? "D err " + cCatchError done
try v = reverse(a) ? "E reverse: " + v[1] + " " + v[4] + " orig " + a[1] catch ? "E err " + cCatchError done
try ? "F reverse str: " + reverse("abc") catch ? "F err " + cCatchError done
i = [1, 2, 3]
try insert(i, 1, 9) ? "G insert: " + i[1] + i[2] + i[3] + i[4] catch ? "G err " + cCatchError done
try ? "H isobject: " + isobject(a) + isobject(new K) + isobject(1) catch ? "H err " + cCatchError done
try ? "I isalpha: " + isalpha("a") + isalpha("1") + isalpha("ab") + isalpha("a1") + isalpha("") catch ? "I err " + cCatchError done
try ? "J islower/isupper/isalnum/isdigit: " + islower("ab") + isupper("aB") + isalnum("a1") + isdigit("12") + isdigit("1a") catch ? "J err " + cCatchError done
try ? "K hex/dec: " + hex(255) + " " + hex(0) + " " + dec("ff") + " " + dec("FF") catch ? "K err " + cCatchError done
try ? "L filename: " + filename() catch ? "L err " + cCatchError done
try r = [1, 2, 3, 4]  del(r, 2)  ? "M del: " + r[1] + r[2] + r[3] catch ? "M err " + cCatchError done
try ? "P find in string: " + find("hello", "l") catch ? "P err " + cCatchError done
try n = [ [1,2], [3,4] ]  ? "Q find nested: " + find(n, [3,4]) catch ? "Q err " + cCatchError done
try ? "R sort by col: " + sort(h, 1)[1][1] catch ? "R err " + cCatchError done
z = [1, 2, 3]
try insert(z, 0, 7) ? "S insert at 0: " + z[1] + z[2] catch ? "S err " + cCatchError done
t = clock()
syssleep(120)
? "T syssleep: " + (((clock() - t) * 1000 / clockspersecond()) >= 100)
class K
