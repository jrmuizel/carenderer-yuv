test: main.mm
	MACOSX_DEPLOYMENT_TARGET=10.15 clang++ main.mm -framework Cocoa -framework OpenGL -framework QuartzCore -framework IOSurface -framework Metal -o test
