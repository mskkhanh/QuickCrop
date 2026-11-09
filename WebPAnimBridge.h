#pragma once
#include <CoreGraphics/CoreGraphics.h>

#ifdef __cplusplus
extern "C" {
#endif

void *QCWebPAnimOpen(const char *path);
void QCWebPAnimClose(void *handle);
int QCWebPAnimWidth(void *handle);
int QCWebPAnimHeight(void *handle);
int QCWebPAnimFrameCount(void *handle);
void QCWebPAnimReset(void *handle);
CGImageRef QCWebPAnimCopyNextFrame(void *handle, int *duration_ms);

#ifdef __cplusplus
}
#endif
