# Block comments do not nest -- reported Feb 2021, "added to my To-Do
# list". Run this file: the outer comment ends at the INNER */, so the
# line below it is parsed as code and the file fails to compile.

? "before"
/*
    /* an inner comment, already there as documentation */
    ? "this line is inside the outer comment and must not run"
*/
? "after"
