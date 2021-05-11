// % MACOSX_DEPLOYMENT_TARGET=10.9 clang++ main.mm -framework Cocoa -framework OpenGL -framework QuartzCore -framework IOSurface -o test && ./test
// clang-format on


// ffmpeg -i chip-chart-1080.mp4 -pix_fmt nv12 -f segment -segment_time 0.001   chip-chart-%d.yuv
// ffmpeg -i chip-chart-1080.mp4 -pix_fmt yuyv422 -f segment -segment_time 0.001   chip-chart-%d.yuv
#define GL_SILENCE_DEPRECATION

#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <OpenGL/gl.h>
#import <Metal/Metal.h>

int SCENE_INDEX;

@protocol MOZCARendererToImage
- (NSImage*)imageByRenderingLayer:(CALayer*)layer
                  intoSceneOfSize:(NSSize)size
                        withScale:(CGFloat)scale;
/*- (void)renderLayer:(CALayer*)layer
      intoImageData:(uint8_t*)data
             ofSize:(NSSize)size
          withScale:(CGFloat)scale;*/
@end

@interface MOZCARendererToImageOpenGL : NSObject <MOZCARendererToImage> {
  NSOpenGLContext* context_;
  CARenderer* renderer_;
}
+ (instancetype)renderer;
- (instancetype)init;
- (NSImage*)imageByRenderingLayer:(CALayer*)layer
                  intoSceneOfSize:(NSSize)size
                        withScale:(CGFloat)scale;
- (void)renderLayer:(CALayer*)layer
      intoImageData:(uint8_t*)data
             ofSize:(NSSize)size
          withScale:(CGFloat)scale;
@end

@interface MOZCARendererToImageMetal : NSObject <MOZCARendererToImage> {
  id<MTLDevice> device_;
  id<MTLCommandQueue> queue_;
  CARenderer* renderer_;
}
+ (instancetype)renderer;
- (instancetype)init;
- (NSImage*)imageByRenderingLayer:(CALayer*)layer
                  intoSceneOfSize:(NSSize)size
                        withScale:(CGFloat)scale;
- (void)renderLayer:(CALayer*)layer
      intoImageData:(uint8_t*)data
             ofSize:(NSSize)size
          withScale:(CGFloat)scale
        bytesPerRow:(size_t)bytesPerRow;
@end

@interface NSImage (ImageWithDataWriteCallback)
+ (NSImage*)imageWithDataWriteCallback:(void (^)(uint8_t* data, NSSize size,
                                                 size_t bytesPerRow))callback
                               andSize:(NSSize)size;
@end

@interface IOSurface (SurfaceWithSizeAndDrawingHandler)
+ (IOSurface*)ioSurfaceRGB;
+ (IOSurface*)ioSurfaceYUV;
+ (IOSurface*)ioSurfaceYUV422;
@end

@interface RunLoopThread : NSThread
- (void)runSyncBlock:(void (^)())block;
- (void)runAsyncBlock:(void (^)())block;
@end

@interface CALayer (SetContentsOpaque)
- (void)setContentsOpaque:(BOOL)opaque;
@end

@interface CALayer (AppendLayerAddition)
- (void)appendLayerWithSurface:(IOSurface*)surface
                          size:(CGSize)size
                      position:(CGPoint)position
                      clipRect:(CGRect)clipRect
                      contentsScale:(CGFloat)contentsScale;
@end

@implementation CALayer (AppendLayerAddition)

- (void)appendLayerWithSurface:(IOSurface*)surface
                          size:(CGSize)size
                      position:(CGPoint)position
                      clipRect:(CGRect)clipRect
                      contentsScale:(CGFloat)contentsScale {

  CALayer* wrappingCALayer = [[CALayer layer] retain];
  wrappingCALayer.position = CGPointMake(clipRect.origin.x / contentsScale, clipRect.origin.y / contentsScale);
  wrappingCALayer.bounds = CGRectMake(0, 0, clipRect.size.width, clipRect.size.height);
  wrappingCALayer.masksToBounds = YES;
  wrappingCALayer.anchorPoint = NSZeroPoint;
  wrappingCALayer.contentsGravity = kCAGravityTopLeft;
  CALayer* contentCALayer = [[CALayer layer] retain];
  contentCALayer.position = CGPointMake((position.x - clipRect.origin.x) / contentsScale, (position.y - clipRect.origin.y) / contentsScale);
  contentCALayer.anchorPoint = NSZeroPoint;
  contentCALayer.contentsGravity = kCAGravityTopLeft;
  contentCALayer.contentsScale = 1;
  contentCALayer.bounds = CGRectMake(0, 0, size.width / contentsScale, size.height / contentsScale);
  contentCALayer.contents = (id)surface;
  contentCALayer.contentsScale = contentsScale;
  [wrappingCALayer addSublayer:contentCALayer];
  [self addSublayer:wrappingCALayer];
}

@end

@interface MOZRenderToImageView : NSView {
  NSImage* img_;
  NSObject<MOZCARendererToImage>* renderer_;
  RunLoopThread* thread_;
}

@end

@implementation MOZRenderToImageView

- (id)initWithFrame:(NSRect)aFrame {
  if (self = [super initWithFrame:aFrame]) {
     renderer_ = [[MOZCARendererToImageOpenGL renderer] retain];
     //renderer_ = [[MOZCARendererToImageMetal renderer] retain];
    img_ = nil;
    thread_ = [RunLoopThread new];
    [thread_ start];
    [self performSelector:@selector(renderScenes) onThread:thread_ withObject:nil waitUntilDone:NO];
  }
  return self;
}

- (void)dealloc {
  [renderer_ release];
  [img_ release];
  [thread_ cancel];
  [thread_ release];
  [super dealloc];
}

- (BOOL)isFlipped {
  return YES;
}

// This has to happen on a non-main thread because of the special "implicit transaction" behavior
// that exists on the main thread: On the main thread, there is always an implicit CATransaction,
// controlled by the run loop. Any explicit transactions that you create on the main thread are just
// nested transactions within the implicit transaction. Commiting an explicit transaction on the
// main thread does *not* have synchronous effects. This is usually not a big deal because in the
// regular case you want your CALayers to be displayed by the window server, and you can't
// synchronously wait for the effects of such a commit-to-WindowServer anyway. But if you want to
// draw your CALayer tree synchronously using CARenderer, the implicit transaction causes trouble:
// The changes to your CALayer tree will only become visible to CARenderer after a trip through the
// event loop, once the implicit transaction has been committed. As a result, synchronous rendering
// with CARenderer on the main thread is not really viable. On background threads, there is no
// implicit transaction by default (unless you mutate CALayers outside an explicit transaction, at
// least), so your CATransaction commits have synchronous effects, and the CALayer changes can
// synchronously become visible to CARenderer.
- (void)renderScenes {
  if ([NSThread isMainThread]) {
    NSLog(@"Can't commit CATransactions synchronously on the main thread");
    abort();
  }
  img_ = [[self imageByRenderingSceneIndex:SCENE_INDEX withRenderer:renderer_] retain];
  [self setNeedsDisplay:YES];
}

+ (CALayer*)makeScene:(int)sceneIndex scale:(CGFloat)scale {
  CALayer* layer = [CALayer layer];
  layer.backgroundColor = [[NSColor cyanColor] CGColor];
  layer.anchorPoint = CGPointZero;
  layer.position = CGPointMake(100, 100);
  layer.bounds = CGRectMake(0, 0, 1920/2, 1080/2);

  printf("SCENE: %d\n", sceneIndex);
  switch (sceneIndex) {
    case 0: layer.contents = [IOSurface ioSurfaceRGB]; break;
    case 1: layer.contents = [IOSurface ioSurfaceYUV]; break;
    case 2: layer.contents = [IOSurface ioSurfaceYUV422]; break;
  }
  CFShow([layer.contents allAttachments]);
  layer.contentsScale = 1;
  return layer;
}

- (NSImage*)imageByRenderingSceneIndex:(int)sceneIndex
                          withRenderer:(id<MOZCARendererToImage>)renderer {
  if ([NSThread isMainThread]) {
    NSLog(@"Can't commit CATransactions synchronously on the main thread");
    abort();
  }
  [NSAnimationContext beginGrouping];
  [CATransaction setDisableActions:YES];
  CALayer* layer = [MOZRenderToImageView makeScene:sceneIndex scale:1.0];
  self.wantsLayer = YES;
  // [[self layer] addSublayer:layer];
  layer.geometryFlipped = NO;
  [NSAnimationContext endGrouping];
  // return nil;
  return [renderer imageByRenderingLayer:layer intoSceneOfSize:NSMakeSize(3026, 1822) withScale:1.0];
}

- (void)drawRect:(NSRect)rect {
  [img_ drawInRect:[self bounds]];
}

@end

@interface MOZLayerView : NSView

@end

@implementation MOZLayerView

- (id)initWithFrame:(NSRect)aFrame {
  self = [super initWithFrame:aFrame];
  self.wantsLayer = YES;
  return self;
}

- (void)dealloc {
  [super dealloc];
}

- (BOOL)isFlipped {
  return YES;
}

- (BOOL)wantsUpdateLayer {
  return YES;
}

- (void)updateLayer {
  CALayer* layer = [MOZRenderToImageView makeScene:SCENE_INDEX scale:1.0];
  self.layer.sublayers = @[layer];
}

@end

@interface TerminateOnClose : NSObject <NSWindowDelegate>
@end

@implementation TerminateOnClose
- (void)windowWillClose:(NSNotification*)notification {
  [NSApp terminate:self];
}
@end

int main(int argc, char** argv) {
  if (argc > 1) {
    if (!strcmp(argv[1], "rgb")) {
      SCENE_INDEX = 0;
    } else if (!strcmp(argv[1], "yuv")) {
      SCENE_INDEX = 1;
    } else if (!strcmp(argv[1], "yuv422")) {
      SCENE_INDEX = 2;
    }
  }

  NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];

  [NSApplication sharedApplication];
  [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
  [(NSMutableDictionary*)[[NSBundle mainBundle] infoDictionary]
      setObject:@YES
         forKey:@"NSSupportsAutomaticGraphicsSwitching"];

  int style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable |
              NSWindowStyleMaskMiniaturizable;
  // NSTitledWindowMask | NSClosableWindowMask | NSResizableWindowMask | NSMiniaturizableWindowMask;
  NSRect contentRect = NSMakeRect(0, 0, 1920, 1080);
  NSWindow* window = [[NSWindow alloc] initWithContentRect:contentRect
                                                 styleMask:style
                                                   backing:NSBackingStoreBuffered
                                                     defer:NO];

  NSView* view = [[MOZLayerView alloc]
      initWithFrame:NSMakeRect(0, 0, contentRect.size.width, contentRect.size.height)];

  [window setContentView:view];
  [window setDelegate:[[TerminateOnClose alloc] autorelease]];
  [NSApp activateIgnoringOtherApps:YES];
  [window makeKeyAndOrderFront:window];

  [NSApp run];

  [pool release];

  return 0;
}

@implementation NSImage (ImageWithDataWriteCallback)

static void Uint8ArrayDelete(void* info, const void* data, size_t size) { delete[](uint8_t*) info; }

+ (NSImage*)imageWithDataWriteCallback:(void (^)(uint8_t* data, NSSize size,
                                                 size_t bytesPerRow))callback
                               andSize:(NSSize)size {
  int w = (int)size.width;
  int h = (int)size.height;
  size_t dataLength = w * 4 * h;
  uint8_t* data = new uint8_t[dataLength];

  callback(data, size, w * 4);

  CGDataProviderRef dataProvider =
      CGDataProviderCreateWithData(data, data, dataLength, Uint8ArrayDelete);
  CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
  CGImageRef ref = CGImageCreate(w, h, 8, 4 * 8, w * 4, colorSpace,
                                 kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host,
                                 dataProvider, nullptr, false, kCGRenderingIntentDefault);
  CGColorSpaceRelease(colorSpace);
  CGDataProviderRelease(dataProvider);

  NSImage* img = [[NSImage alloc] initWithCGImage:ref size:size];
  CGImageRelease(ref);
  return [img autorelease];
}
@end

@implementation MOZCARendererToImageOpenGL

+ (instancetype)renderer {
  return [[[MOZCARendererToImageOpenGL alloc] init] autorelease];
}

- (instancetype)init {
  self = [super init];
  NSOpenGLPixelFormatAttribute attribs[] = {NSOpenGLPFAAllowOfflineRenderers, 0};
  NSOpenGLPixelFormat* format = [[NSOpenGLPixelFormat alloc] initWithAttributes:attribs];
  context_ = [[NSOpenGLContext alloc] initWithFormat:format shareContext:nullptr];
  [format release];
  CFMutableDictionaryRef options = CFDictionaryCreateMutable(
      kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks,
      &kCFTypeDictionaryValueCallBacks);
  /*CFDictionaryAddValue(options, kCARendererColorSpace, 
        //CGColorSpaceCreateWithName(kCGColorSpaceSRGB));
        CGColorSpaceCreateWithName(kCGColorSpaceAdobeRGB1998));
  */
  renderer_ = [[CARenderer rendererWithCGLContext:[context_ CGLContextObj] options:CFBridgingRelease(options)] retain];

  return self;
}

- (void)dealloc {
  [renderer_ release];
  [context_ release];
  [super dealloc];
}

- (void)renderLayer:(CALayer*)layer
      intoImageData:(uint8_t*)data
             ofSize:(NSSize)size
          withScale:(CGFloat)scale {
  NSOpenGLContext* oldContext = [NSOpenGLContext currentContext];

  int w = size.width;

  [context_ makeCurrentContext];
  GLuint tex;
  glGenTextures(1, &tex);
  glBindTexture(GL_TEXTURE_RECTANGLE_ARB, tex);
  glTexParameteri(GL_TEXTURE_RECTANGLE_ARB, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
  glTexParameteri(GL_TEXTURE_RECTANGLE_ARB, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
  glTexImage2D(GL_TEXTURE_RECTANGLE_ARB, 0, GL_RGBA, size.width, size.height, 0, GL_BGRA,
               GL_UNSIGNED_INT_8_8_8_8_REV, nullptr);
  glBindTexture(GL_TEXTURE_RECTANGLE_ARB, 0);

  GLuint fbo;
  glGenFramebuffersEXT(1, &fbo);
  glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, fbo);
  glFramebufferTexture2DEXT(GL_FRAMEBUFFER_EXT, GL_COLOR_ATTACHMENT0_EXT, GL_TEXTURE_RECTANGLE_ARB,
                            tex, 0);

  GLenum fboStatus = glCheckFramebufferStatusEXT(GL_FRAMEBUFFER_EXT);
  if (fboStatus != GL_FRAMEBUFFER_COMPLETE_EXT) {
    NSLog(@"framebuffer not complete");
    abort();
  }
  glViewport(0.0, 0.0, size.width, size.height);
  glMatrixMode(GL_PROJECTION);
  glLoadIdentity();
  glOrtho(0.0, size.width / scale, 0.0, size.height / scale, -1, 1);

  glClearColor(0.0, 0.0, 0.0, 0.0);
  glClear(GL_COLOR_BUFFER_BIT);

  [NSAnimationContext beginGrouping];
  [CATransaction setDisableActions:YES];
  renderer_.layer = layer;
  [NSAnimationContext endGrouping];

  double caTime = CACurrentMediaTime();
  renderer_.bounds = CGRectMake(0, 0, size.width / scale, size.height / scale);
  [renderer_ beginFrameAtTime:caTime timeStamp:nullptr];
  // [renderer_ addUpdateRect:CGRectMake(0, 0, size.width, size.height)];
  [renderer_ render];
  [renderer_ endFrame];

  glPixelStorei(GL_PACK_ALIGNMENT, 1);
  glPixelStorei(GL_PACK_ROW_LENGTH, 0);
  glPixelStorei(GL_PACK_SKIP_ROWS, 0);
  glPixelStorei(GL_PACK_SKIP_PIXELS, 0);

  glReadPixels(0.0f, 0.0f, size.width, size.height, GL_BGRA, GL_UNSIGNED_BYTE, data);
  glDeleteFramebuffers(1, &fbo);
  glDeleteTextures(1, &tex);

  [oldContext makeCurrentContext];

  [NSAnimationContext beginGrouping];
  [CATransaction setDisableActions:YES];
  renderer_.layer = nil;
  [NSAnimationContext endGrouping];
}

- (NSImage*)imageByRenderingLayer:(CALayer*)layer
                  intoSceneOfSize:(NSSize)size
                        withScale:(CGFloat)scale {
  return [NSImage
      imageWithDataWriteCallback:^(uint8_t* data, NSSize size, size_t bytesPerRow) {
        [self renderLayer:layer intoImageData:data ofSize:size withScale:scale];
      }
                         andSize:size];
}

@end

@implementation MOZCARendererToImageMetal

+ (instancetype)renderer {
  return [[[MOZCARendererToImageMetal alloc] init] autorelease];
}

- (instancetype)init {
  self = [super init];

  device_ = [MTLCreateSystemDefaultDevice() retain];
  queue_ = [[device_ newCommandQueue] retain];
  MTLTextureDescriptor* textureDescriptor =
      [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                         width:100
                                                        height:100
                                                     mipmapped:NO];
  textureDescriptor.usage =
      MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget;
  id<MTLTexture> texture = [device_ newTextureWithDescriptor:textureDescriptor];
  renderer_ = [[CARenderer rendererWithMTLTexture:texture
                                          options:@{kCARendererMetalCommandQueue : queue_}] retain];

  return self;
}

- (void)dealloc {
  [renderer_ release];
  [queue_ release];
  [device_ release];
  [super dealloc];
}

- (void)renderLayer:(CALayer*)layer
      intoImageData:(uint8_t*)data
             ofSize:(NSSize)size
          withScale:(CGFloat)scale
        bytesPerRow:(size_t)bytesPerRow {
  MTLTextureDescriptor* textureDescriptor =
      [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                         width:size.width
                                                        height:size.height
                                                     mipmapped:NO];
  textureDescriptor.usage =
      MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget;
  id<MTLTexture> texture = [device_ newTextureWithDescriptor:textureDescriptor];
  [renderer_ setDestination:texture];

  [NSAnimationContext beginGrouping];
  [CATransaction setDisableActions:YES];
  renderer_.layer = layer;
  [NSAnimationContext endGrouping];

  double caTime = CACurrentMediaTime();
  renderer_.bounds = CGRectMake(0, 0, size.width, size.height);
  [renderer_ beginFrameAtTime:caTime timeStamp:nullptr];
  // [renderer_ addUpdateRect:CGRectMake(0, 0, size.width, size.height)];
  [renderer_ render];
  [renderer_ endFrame];

  // TODO: read back

  id<MTLCommandBuffer> blitCommandBuffer = [queue_ commandBuffer];
  id<MTLBlitCommandEncoder> blitCommandEncoder = [blitCommandBuffer blitCommandEncoder];
  [blitCommandEncoder synchronizeTexture:texture slice:0 level:0];
  [blitCommandEncoder endEncoding];
  [blitCommandBuffer commit];
  [blitCommandBuffer waitUntilCompleted];

  [texture getBytes:data
        bytesPerRow:bytesPerRow
      bytesPerImage:0
         fromRegion:MTLRegionMake2D(0, 0, size.width, size.height)
        mipmapLevel:0
              slice:0];

  [NSAnimationContext beginGrouping];
  [CATransaction setDisableActions:YES];
  renderer_.layer = nil;
  [NSAnimationContext endGrouping];
}

- (NSImage*)imageByRenderingLayer:(CALayer*)layer
                  intoSceneOfSize:(NSSize)size
                        withScale:(CGFloat)scale {
  return [NSImage
      imageWithDataWriteCallback:^(uint8_t* data, NSSize size, size_t bytesPerRow) {
        [self renderLayer:layer
            intoImageData:data
                   ofSize:size
                withScale:scale
              bytesPerRow:bytesPerRow];
      }
                         andSize:size];
}

@end

@implementation RunLoopThread

- (void)main {
  NSAutoreleasePool* pool = [NSAutoreleasePool new];

  NSRunLoop* runloop = [NSRunLoop currentRunLoop];
  [runloop addPort:[NSMachPort port] forMode:NSDefaultRunLoopMode];

  while (!self.cancelled) {
    [runloop runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]];
  }

  [pool release];
}

- (void)runBlock:(void (^)())block {
  block();
}

- (void)runSyncBlock:(void (^)())block {
  [self performSelector:@selector(runBlock:) onThread:self withObject:block waitUntilDone:YES];
}

- (void)runAsyncBlock:(void (^)())block {
  [self performSelector:@selector(runBlock:) onThread:self withObject:block waitUntilDone:NO];
}

@end

@implementation IOSurface (SurfaceWithSizeAndDrawingHandler)
+ (IOSurface*)ioSurfaceWithSize:(NSSize)size
                        flipped:(BOOL)drawingHandlerShouldBeCalledWithFlippedContext
                 drawingHandler:(void (^)(NSRect dstRect))drawingHandler {
  IOSurface* surface = [[IOSurface alloc] initWithProperties:@{
    IOSurfacePropertyKeyWidth : @(size.width),
    IOSurfacePropertyKeyHeight : @(size.height),
    IOSurfacePropertyKeyPixelFormat : @(kCVPixelFormatType_32BGRA),
    IOSurfacePropertyKeyBytesPerElement : @(4),
  }];
  [surface setAttachment:@"kCGColorSpaceAdobeRGB1998" forKey: @"IOSurfaceColorSpace"];
  [surface lockWithOptions:0 seed:nil];

  CGColorSpaceRef rgb = CGColorSpaceCreateDeviceRGB();
  CGContextRef cg = CGBitmapContextCreate(
      surface.baseAddress, surface.width, surface.height, 8, surface.bytesPerRow, rgb,
      kCGBitmapByteOrder32Host | kCGImageAlphaPremultipliedFirst);
  CGColorSpaceRelease(rgb);
  NSGraphicsContext* oldContext = [NSGraphicsContext currentContext];
  [NSGraphicsContext
      setCurrentContext:
          [NSGraphicsContext
              graphicsContextWithCGContext:cg
                                   flipped:drawingHandlerShouldBeCalledWithFlippedContext]];

  drawingHandler(NSMakeRect(0, 0, surface.width, surface.height));

  [NSGraphicsContext setCurrentContext:oldContext];
  CGContextRelease(cg);

  [surface unlockWithOptions:0 seed:nil];

  return [surface autorelease];
}
+ (IOSurface*)ioSurfaceYUV {
  int width = 1920;
  int height = 1080;
  id planeInfoY = @{
    IOSurfacePropertyKeyPlaneWidth : @(width),
    IOSurfacePropertyKeyPlaneHeight : @(height),
    IOSurfacePropertyKeyPlaneBytesPerRow : @(width),
    IOSurfacePropertyKeyPlaneOffset : @(0),
    IOSurfacePropertyKeyPlaneSize: @(1920*1080),
    IOSurfacePropertyKeyBytesPerElement: @(1)
  };
    id planeInfoUV =  @{
    IOSurfacePropertyKeyPlaneWidth : @(width/2),
    IOSurfacePropertyKeyPlaneHeight : @(height/2),
    IOSurfacePropertyKeyPlaneBytesPerRow : @(width),
    IOSurfacePropertyKeyPlaneOffset : @(1920*1080),
    IOSurfacePropertyKeyPlaneSize: @(1920*1080/2),
    IOSurfacePropertyKeyBytesPerElement: @(2)
  };

  IOSurface* surface = [[IOSurface alloc] initWithProperties:@{
    IOSurfacePropertyKeyWidth : @(width),
    IOSurfacePropertyKeyHeight : @(height),
    IOSurfacePropertyKeyPixelFormat : @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
    IOSurfacePropertyKeyBytesPerElement : @(4),
    IOSurfacePropertyKeyAllocSize : @(1920*1080 + 1920*1080/2),
    IOSurfacePropertyKeyPlaneInfo : @[planeInfoY, planeInfoUV]
  }];
  assert(surface);
 // [surface setAttachment:@"ITU_R_601_4" forKey: @"IOSurfaceYCbCrMatrix"];
  [surface setAttachment:@"ITU_R_709_2" forKey: @"IOSurfaceYCbCrMatrix"];
  //[surface setAttachment:@"kCGColorSpaceAdobeRGB1998" forKey: @"IOSurfaceColorSpace"];
  [surface lockWithOptions:0 seed:nil];
  FILE *f = fopen("chip-chart.yuv", "r");
  int off = fread(surface.baseAddress, 1, 1920*1080 + 1920*1080/2, f);
  printf("%d\n", off);
  fclose(f);
  [surface unlockWithOptions:0 seed:nil];

  return [surface autorelease];
}
+ (IOSurface*)ioSurfaceYUV422 {
  int width = 1920;
  int height = 1080;
  IOSurface* surface = [[IOSurface alloc] initWithProperties:@{
    IOSurfacePropertyKeyWidth : @(width),
    IOSurfacePropertyKeyHeight : @(height),
    //IOSurfacePropertyKeyPixelFormat : @(kCVPixelFormatType_422YpCbCr8FullRange),
    IOSurfacePropertyKeyPixelFormat : @(kCVPixelFormatType_422YpCbCr8_yuvs),
    IOSurfacePropertyKeyBytesPerElement : @(2),
    IOSurfacePropertyKeyAllocSize : @(1920*1080 + 1920*1080),
  }];
  assert(surface);
  auto colorSpace = CGDisplayCopyColorSpace(CGMainDisplayID());
  NSData* colorData = (NSData*)CGColorSpaceCopyICCProfile(colorSpace);

  NSError* error = nil;

  NSData* ntscData = [NSData dataWithContentsOfFile:@"video.icc"  options:0 error:&error];

  //[surface setAttachment:@"kCGColorSpaceAdobeRGB1998" forKey: @"IOSurfaceColorSpace"];
  //[surface setAttachment: @"kCGColorSpaceSRGB" forKey: @"IOSurfaceColorSpace"];
  //[surface setAttachment:@"ITU_R_601_4" forKey: @"IOSurfaceYCbCrMatrix"];
  [surface setAttachment:@"ITU_R_709_2" forKey: @"IOSurfaceYCbCrMatrix"];
  [surface lockWithOptions:0 seed:nil];
  FILE *f = fopen("chip-chart-422.yuv", "r");
  int off = fread(surface.baseAddress, 1, 1920*1080 + 1920*1080, f);
  printf("%d\n", off);
  fclose(f);
  [surface unlockWithOptions:0 seed:nil];

  return [surface autorelease];
}
+ (IOSurface*)ioSurfaceRGB {
  int width = 1920;
  int height = 1080;
  IOSurface* surface = [[IOSurface alloc] initWithProperties:@{
    IOSurfacePropertyKeyWidth : @(width),
    IOSurfacePropertyKeyHeight : @(height),
    IOSurfacePropertyKeyPixelFormat : @(kCVPixelFormatType_32ARGB),
    IOSurfacePropertyKeyBytesPerElement : @(4),
    IOSurfacePropertyKeyAllocSize : @(1920*1080*4),
  }];
  assert(surface);
  auto colorSpace = CGDisplayCopyColorSpace(CGMainDisplayID());
  NSData* colorData = (NSData*)CGColorSpaceCopyICCProfile(colorSpace);

  NSError* error = nil;

  //NSData* ntscData = [NSData dataWithContentsOfFile:@"video.icc"  options:0 error:&error];

  //[surface setAttachment:@"kCGColorSpaceAdobeRGB1998" forKey: @"IOSurfaceColorSpace"];
  //[surface setAttachment: @"kCGColorSpaceSRGB" forKey: @"IOSurfaceColorSpace"];
  [surface lockWithOptions:0 seed:nil];
  FILE *f = fopen("chip-chart-rgb.yuv", "r");
  int off = fread(surface.baseAddress, 1, 1920*1080*4, f);
  printf("%d\n", off);
  fclose(f);
  [surface unlockWithOptions:0 seed:nil];

  return [surface autorelease];
}

@end
