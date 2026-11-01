# RUNG 5 OF THE RESIDENT VM: Ring's getter for an attribute (F-73) when the
# getter's NAME came into the program before the attribute's. The class tables
# grow with each admission (rnxc.zig, growClassTables), so a name new in a
# later file must still find the `get<name>` the program already had -- this
# host never spells the attribute itself. Run with `rnxc resident
# ac_host.ring`; oracle_accessor.ring is Ring's answer.
? "admit painter: " + admitfile("ac_painter.ring")
? "painter: " + MakePainter().getColor()
? "admit box: " + admitfile("ac_box.ring")
b = MakeBox()
? "box colour through its getter: " + BoxColour(b)
PaintBox(b, "blue")
? "box colour set through its setter: " + BoxColour(b)
