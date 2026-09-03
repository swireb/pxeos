#
# Makefile for the pxeos initrd binaries
#
#
all: pxeosmbrfix pxeosfatgrow
pxeosmbrfix:
	$(CXX) $(CXXFLAGS) -o pxeosmbrfix pxeosmbrfix.cpp
pxeosfatgrow: pxeosfatgrow.c
	$(CC) $(CFLAGS) $(LDFLAGS) -o pxeosfatgrow pxeosfatgrow.c -lparted-fs-resize -lparted
clean:
	rm -f *.o pxeosmbrfix pxeosfatgrow
