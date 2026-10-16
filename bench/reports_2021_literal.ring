# Where does Ring say an unclosed literal is?
# The quote opens on line 9. Ring reports the LAST line of the file.
? "line 1"
? "line 2"
? "line 3"
? "line 4"
? "line 5"
? "line 6"
? "line 7"
# The quote below OPENS on line 9 and is never closed.
? "unclosed here
? "line 11"
? "line 12"
? "line 13"
