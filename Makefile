test: main.mm
	MACOSX_DEPLOYMENT_TARGET=10.15 clang++ main.mm -std=c++17 -framework Cocoa -framework OpenGL -framework QuartzCore -framework IOSurface -framework Metal -o test
