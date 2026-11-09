#include "WebPAnimBridge.h"
#include <webp/demux.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
  uint8_t *bytes;
  size_t size;
  WebPData data;
  WebPAnimDecoder *decoder;
  WebPAnimInfo info;
  int last_timestamp;
} QCWebPAnimHandle;

void *QCWebPAnimOpen(const char *path) {
  if (!path) return NULL;
  FILE *f = fopen(path, "rb");
  if (!f) return NULL;
  if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return NULL; }
  long length = ftell(f);
  if (length <= 0) { fclose(f); return NULL; }
  rewind(f);

  QCWebPAnimHandle *h = (QCWebPAnimHandle *)calloc(1, sizeof(QCWebPAnimHandle));
  if (!h) { fclose(f); return NULL; }
  h->size = (size_t)length;
  h->bytes = (uint8_t *)malloc(h->size);
  if (!h->bytes) { fclose(f); free(h); return NULL; }
  if (fread(h->bytes, 1, h->size, f) != h->size) {
    fclose(f); free(h->bytes); free(h); return NULL;
  }
  fclose(f);

  h->data.bytes = h->bytes;
  h->data.size = h->size;

  WebPAnimDecoderOptions options;
  if (!WebPAnimDecoderOptionsInit(&options)) {
    free(h->bytes); free(h); return NULL;
  }
  options.color_mode = MODE_bgrA;
  options.use_threads = 1;

  h->decoder = WebPAnimDecoderNew(&h->data, &options);
  if (!h->decoder || !WebPAnimDecoderGetInfo(h->decoder, &h->info)) {
    if (h->decoder) WebPAnimDecoderDelete(h->decoder);
    free(h->bytes); free(h); return NULL;
  }
  h->last_timestamp = 0;
  return h;
}

void QCWebPAnimClose(void *handle) {
  QCWebPAnimHandle *h = (QCWebPAnimHandle *)handle;
  if (!h) return;
  if (h->decoder) WebPAnimDecoderDelete(h->decoder);
  free(h->bytes);
  free(h);
}

int QCWebPAnimWidth(void *handle) {
  QCWebPAnimHandle *h = (QCWebPAnimHandle *)handle;
  return h ? (int)h->info.canvas_width : 0;
}

int QCWebPAnimHeight(void *handle) {
  QCWebPAnimHandle *h = (QCWebPAnimHandle *)handle;
  return h ? (int)h->info.canvas_height : 0;
}

int QCWebPAnimFrameCount(void *handle) {
  QCWebPAnimHandle *h = (QCWebPAnimHandle *)handle;
  return h ? (int)h->info.frame_count : 0;
}

void QCWebPAnimReset(void *handle) {
  QCWebPAnimHandle *h = (QCWebPAnimHandle *)handle;
  if (!h || !h->decoder) return;
  WebPAnimDecoderReset(h->decoder);
  h->last_timestamp = 0;
}

CGImageRef QCWebPAnimCopyNextFrame(void *handle, int *duration_ms) {
  QCWebPAnimHandle *h = (QCWebPAnimHandle *)handle;
  if (!h || !h->decoder) return NULL;

  if (!WebPAnimDecoderHasMoreFrames(h->decoder)) {
    WebPAnimDecoderReset(h->decoder);
    h->last_timestamp = 0;
  }

  uint8_t *buf = NULL;
  int timestamp = 0;
  if (!WebPAnimDecoderGetNext(h->decoder, &buf, &timestamp) || !buf) return NULL;

  int duration = timestamp - h->last_timestamp;
  h->last_timestamp = timestamp;
  if (duration <= 0) duration = 100;
  if (duration_ms) *duration_ms = duration;

  const size_t width = h->info.canvas_width;
  const size_t height = h->info.canvas_height;
  const size_t stride = width * 4;
  const size_t byte_count = stride * height;

  CFDataRef data = CFDataCreate(kCFAllocatorDefault, buf, (CFIndex)byte_count);
  if (!data) return NULL;
  CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);
  CFRelease(data);
  if (!provider) return NULL;

  CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  if (!cs) { CGDataProviderRelease(provider); return NULL; }

  CGBitmapInfo info = kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst;
  CGImageRef image = CGImageCreate(width, height, 8, 32, stride, cs, info,
                                   provider, NULL, false, kCGRenderingIntentDefault);
  CGColorSpaceRelease(cs);
  CGDataProviderRelease(provider);
  return image;
}
