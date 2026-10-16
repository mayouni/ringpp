func F1()
    write("_fio_test.txt", "hello world")
    return fexists("_fio_test.txt")

func F2()
    return fexists("_no_such_file_here.txt")

func F3()
    write("_fio_test.txt", "abcdefghij")
    c = read("_fio_test.txt")
    return len(c)

func F4()
    write("_fio_test.txt", "RING")
    c = read("_fio_test.txt")
    return ascii(c[1]) + ascii(c[4])
