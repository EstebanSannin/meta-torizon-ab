# Build fix for jq on current meta-oe (scarthgap HEAD).
#
# jq's Makefile ships a rule that prints "NOT building parser.c!" and does
# nothing when maintainer-mode is off, assuming the pre-generated src/parser.c
# is present in the BUILD tree. In an out-of-tree build (B != S, the OE default)
# it is only in the SOURCE tree, so `gcc -c src/parser.c` fails with
# "src/parser.c: No such file or directory". Build in-tree so the shipped
# parser.c/lexer.c are found.
#
# NOTE: build-host workaround; drop once meta-oe's jq builds out-of-tree again
# (or the layer is pinned to a revision where it does).
B = "${S}"
