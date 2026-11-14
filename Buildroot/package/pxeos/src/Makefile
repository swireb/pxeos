#
# Makefile for the pxeos initrd binaries
#
#
all: pxeosmbrfix pxeosfatgrow pxeos-deploy-worker
pxeosmbrfix:
	$(CXX) $(CXXFLAGS) -o pxeosmbrfix pxeosmbrfix.cpp
pxeosfatgrow: pxeosfatgrow.c
	$(CC) $(CFLAGS) $(LDFLAGS) -o pxeosfatgrow pxeosfatgrow.c -lparted-fs-resize -lparted
pxeos-deploy-worker: pxeos-deploy-worker.c
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $<
clean:
	rm -f *.o pxeosmbrfix pxeosfatgrow pxeos-deploy-worker
