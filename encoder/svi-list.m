#define GL_SILENCE_DEPRECATION
#import <Cocoa/Cocoa.h>
#import <Syphon/Syphon.h>

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        // Service the run loop a few times to pick up distributed notifications
        for (int i = 0; i < 20; i++) {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                     beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.25]];
        }
        NSArray *servers = [[SyphonServerDirectory sharedDirectory] servers];
        if (servers.count == 0) {
            printf("No Syphon servers found.\n");
            return 1;
        }
        printf("Found %lu Syphon server(s):\n", (unsigned long)servers.count);
        for (NSDictionary *s in servers) {
            printf("  Name: '%s'  App: '%s'  UUID: '%s'\n",
                   [[s objectForKey:SyphonServerDescriptionNameKey] UTF8String] ?: "(null)",
                   [[s objectForKey:SyphonServerDescriptionAppNameKey] UTF8String] ?: "(null)",
                   [[s objectForKey:SyphonServerDescriptionUUIDKey] UTF8String] ?: "(null)");
        }
    }
    return 0;
}
