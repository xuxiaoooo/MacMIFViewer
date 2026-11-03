#pragma once
#include <stddef.h>
#include <stdint.h>

typedef struct {
    uint32_t width, height;
    uint16_t bits, samples, sample_format, photometric, orientation, codec;
    uint16_t sub_count;
    double mpp_x, mpp_y;
    uint64_t decoded_block_bytes;
} MFPage;

void *mf_tiff_open(const char *path);
void mf_tiff_close(void *file);
uint32_t mf_tiff_pages(void *file);
int mf_tiff_page(void *file, uint32_t ifd, int sub, MFPage *page);
const char *mf_tiff_description(void *file);
int mf_tiff_codec(uint16_t codec);
int mf_tiff_read(void *file, uint32_t ifd, int sub,
                 uint32_t x, uint32_t y, uint32_t w, uint32_t h, void *destination, size_t size);
void *mf_tiff_create(const char *path);
int mf_tiff_begin(void *file, uint32_t width, uint32_t height, uint16_t bits, uint16_t samples,
                  const char *description, double mpp_x, double mpp_y);
int mf_tiff_write(void *file, uint32_t x, uint32_t y, void *buffer, size_t size);
int mf_tiff_finish(void *file);

int mf_mrxs_jpeg_rgb(const void *source, size_t length, uint32_t width, uint32_t height,
                     void *destination, size_t size);
