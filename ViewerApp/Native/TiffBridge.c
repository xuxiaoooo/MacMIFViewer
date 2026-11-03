#include "TiffBridge.h"
#include <tiffio.h>
#include <stdlib.h>
#include <string.h>

#define BLOCK_LIMIT (32u * 1024u * 1024u)
#define EXPORT_TILE 256u

static int silent(TIFF *tif, void *data, const char *module, const char *fmt, va_list args) {
    return 1;
}

static TIFF *open_file(const char *path, const char *mode) {
    TIFFOpenOptions *options = TIFFOpenOptionsAlloc();
    if (!options) return NULL;
    TIFFOpenOptionsSetMaxSingleMemAlloc(options, BLOCK_LIMIT);
    TIFFOpenOptionsSetMaxCumulatedMemAlloc(options, BLOCK_LIMIT * 3);
    TIFFOpenOptionsSetErrorHandlerExtR(options, silent, NULL);
    TIFFOpenOptionsSetWarningHandlerExtR(options, silent, NULL);
    TIFF *file = TIFFOpenExt(path, mode, options);
    TIFFOpenOptionsFree(options);
    return file;
}

void *mf_tiff_open(const char *path) { return open_file(path, "rOm"); }
void *mf_tiff_create(const char *path) { return open_file(path, "w8"); }
void mf_tiff_close(void *file) { TIFFClose(file); }
uint32_t mf_tiff_pages(void *file) { return TIFFNumberOfDirectories(file); }
int mf_tiff_codec(uint16_t codec) { return TIFFIsCODECConfigured(codec); }

static int select_page(TIFF *file, uint32_t ifd, int sub) {
    if (!TIFFSetDirectory(file, ifd)) return 0;
    if (sub < 0) return 1;
    uint16_t count = 0;
    uint64_t *offsets = NULL;
    return TIFFGetField(file, TIFFTAG_SUBIFD, &count, &offsets) &&
           sub < count && TIFFSetSubDirectory(file, offsets[sub]);
}

int mf_tiff_page(void *opaque, uint32_t ifd, int sub, MFPage *page) {
    TIFF *file = opaque;
    if (!select_page(file, ifd, sub)) return 0;
    memset(page, 0, sizeof *page);
    if (!TIFFGetField(file, TIFFTAG_IMAGEWIDTH, &page->width) ||
        !TIFFGetField(file, TIFFTAG_IMAGELENGTH, &page->height) ||
        !TIFFGetField(file, TIFFTAG_PHOTOMETRIC, &page->photometric)) return 0;
    TIFFGetFieldDefaulted(file, TIFFTAG_BITSPERSAMPLE, &page->bits);
    TIFFGetFieldDefaulted(file, TIFFTAG_SAMPLESPERPIXEL, &page->samples);
    TIFFGetFieldDefaulted(file, TIFFTAG_SAMPLEFORMAT, &page->sample_format);
    TIFFGetFieldDefaulted(file, TIFFTAG_ORIENTATION, &page->orientation);
    TIFFGetFieldDefaulted(file, TIFFTAG_COMPRESSION, &page->codec);
    uint64_t *offsets = NULL;
    TIFFGetField(file, TIFFTAG_SUBIFD, &page->sub_count, &offsets);
    page->decoded_block_bytes = TIFFIsTiled(file) ? TIFFTileSize64(file) : TIFFStripSize64(file);
    uint16_t unit = 1;
    float x = 0, y = 0;
    TIFFGetFieldDefaulted(file, TIFFTAG_RESOLUTIONUNIT, &unit);
    TIFFGetField(file, TIFFTAG_XRESOLUTION, &x);
    TIFFGetField(file, TIFFTAG_YRESOLUTION, &y);
    double scale = unit == RESUNIT_INCH ? 25400 : unit == RESUNIT_CENTIMETER ? 10000 : 0;
    if (x > 0) page->mpp_x = scale / x;
    if (y > 0) page->mpp_y = scale / y;
    return 1;
}

const char *mf_tiff_description(void *opaque) {
    TIFF *file = opaque;
    char *value = NULL;
    if (!select_page(file, 0, -1)) return NULL;
    return TIFFGetField(file, TIFFTAG_IMAGEDESCRIPTION, &value) ? value : NULL;
}

static uint32_t minimum(uint32_t a, uint32_t b) { return a < b ? a : b; }
static uint32_t maximum(uint32_t a, uint32_t b) { return a > b ? a : b; }

int mf_tiff_read(void *opaque, uint32_t ifd, int sub, uint32_t x, uint32_t y,
                 uint32_t w, uint32_t h, void *destination, size_t size) {
    TIFF *file = opaque;
    MFPage page;
    if (!mf_tiff_page(file, ifd, sub, &page)) return 0;
    if (!w || !h || x >= page.width || y >= page.height || w > page.width - x ||
        h > page.height - y || page.samples != 1 || page.sample_format != SAMPLEFORMAT_UINT ||
        (page.bits != 8 && page.bits != 16)) return 0;
    size_t bpp = page.bits / 8;
    uint64_t block_bytes = page.decoded_block_bytes;
    if (!block_bytes || block_bytes > BLOCK_LIMIT || w > 512 || h > 512 ||
        (size_t)w * h * bpp != size) return 0;

    int tiled = TIFFIsTiled(file);
    uint32_t bw = page.width, bh = 0;
    if (tiled) {
        TIFFGetField(file, TIFFTAG_TILEWIDTH, &bw);
        TIFFGetField(file, TIFFTAG_TILELENGTH, &bh);
    } else {
        TIFFGetFieldDefaulted(file, TIFFTAG_ROWSPERSTRIP, &bh);
        bh = minimum(bh, page.height);
    }
    if (!bw || !bh || (uint64_t)bw * bh > block_bytes / bpp) return 0;

    uint8_t *buffer = malloc((size_t)block_bytes);
    if (!buffer) return 0;
    int success = 1;
    for (uint64_t by = y / bh * bh; by < y + h && success; by += bh) {
        for (uint64_t bx = x / bw * bw; bx < x + w; bx += bw) {
            tmsize_t got = tiled ?
                TIFFReadEncodedTile(file, TIFFComputeTile(file, (uint32_t)bx, (uint32_t)by, 0, 0),
                                    buffer, (tmsize_t)block_bytes) :
                TIFFReadEncodedStrip(file, TIFFComputeStrip(file, (uint32_t)by, 0),
                                     buffer, (tmsize_t)block_bytes);
            uint32_t x0 = maximum(x, (uint32_t)bx);
            uint32_t x1 = (uint32_t)(bx + bw < (uint64_t)x + w ? bx + bw : (uint64_t)x + w);
            uint32_t y0 = maximum(y, (uint32_t)by);
            uint32_t y1 = (uint32_t)(by + bh < (uint64_t)y + h ? by + bh : (uint64_t)y + h);
            size_t end = ((size_t)(y1 - 1 - by) * bw + (size_t)(x1 - bx)) * bpp;
            if (got < 0 || (uint64_t)got < end) {
                success = 0;
                break;
            }
            for (uint32_t row = y0; row < y1; ++row) {
                size_t from = ((size_t)(row - by) * bw + (size_t)(x0 - bx)) * bpp;
                size_t to = ((size_t)(row - y) * w + (size_t)(x0 - x)) * bpp;
                memcpy((uint8_t *)destination + to, buffer + from, (x1 - x0) * bpp);
            }
        }
    }
    free(buffer);
    return success;
}

int mf_tiff_begin(void *opaque, uint32_t width, uint32_t height, uint16_t bits, uint16_t samples,
                  const char *description, double mpp_x, double mpp_y) {
    TIFF *file = opaque;
    if (!TIFFSetField(file, TIFFTAG_IMAGEWIDTH, width) ||
        !TIFFSetField(file, TIFFTAG_IMAGELENGTH, height) ||
        !TIFFSetField(file, TIFFTAG_BITSPERSAMPLE, bits) ||
        !TIFFSetField(file, TIFFTAG_SAMPLESPERPIXEL, samples) ||
        !TIFFSetField(file, TIFFTAG_SAMPLEFORMAT, SAMPLEFORMAT_UINT) ||
        !TIFFSetField(file, TIFFTAG_ORIENTATION, ORIENTATION_TOPLEFT) ||
        !TIFFSetField(file, TIFFTAG_PHOTOMETRIC, samples == 1 ? PHOTOMETRIC_MINISBLACK : PHOTOMETRIC_RGB) ||
        !TIFFSetField(file, TIFFTAG_PLANARCONFIG, PLANARCONFIG_CONTIG) ||
        !TIFFSetField(file, TIFFTAG_COMPRESSION, COMPRESSION_ADOBE_DEFLATE) ||
        !TIFFSetField(file, TIFFTAG_TILEWIDTH, EXPORT_TILE) ||
        !TIFFSetField(file, TIFFTAG_TILELENGTH, EXPORT_TILE)) return 0;
    if (description && !TIFFSetField(file, TIFFTAG_IMAGEDESCRIPTION, description)) return 0;
    if (mpp_x > 0 && mpp_y > 0) {
        if (!TIFFSetField(file, TIFFTAG_RESOLUTIONUNIT, RESUNIT_CENTIMETER) ||
            !TIFFSetField(file, TIFFTAG_XRESOLUTION, 10000 / mpp_x) ||
            !TIFFSetField(file, TIFFTAG_YRESOLUTION, 10000 / mpp_y)) return 0;
    }
    return 1;
}

int mf_tiff_write(void *opaque, uint32_t x, uint32_t y, void *buffer, size_t size) {
    TIFF *file = opaque;
    if (size != TIFFTileSize64(file)) return 0;
    return TIFFWriteEncodedTile(file, TIFFComputeTile(file, x, y, 0, 0),
                                buffer, (tmsize_t)size) == (tmsize_t)size;
}

int mf_tiff_finish(void *file) { return TIFFWriteDirectory(file); }

#include <jpeglib.h>
#include <setjmp.h>

struct jpeg_failure {
    struct jpeg_error_mgr manager;
    jmp_buf jump;
};

static void jpeg_failure(j_common_ptr info) {
    struct jpeg_failure *failure = (struct jpeg_failure *)info->err;
    longjmp(failure->jump, 1);
}

static void jpeg_warning(j_common_ptr info, int level) {
    if (level < 0) jpeg_failure(info);
}

int mf_mrxs_jpeg_rgb(const void *source, size_t length, uint32_t width, uint32_t height,
                     void *destination, size_t size) {
    if (!source || !destination || !length || !width || !height ||
        width > 512 || height > 512 || size != (size_t)width * height * 3) return 0;
    struct jpeg_decompress_struct *jpeg = calloc(1, sizeof *jpeg);
    if (!jpeg) return 0;
    struct jpeg_failure failure;
    jpeg->err = jpeg_std_error(&failure.manager);
    failure.manager.error_exit = jpeg_failure;
    failure.manager.emit_message = jpeg_warning;
    if (setjmp(failure.jump)) {
        jpeg_destroy_decompress(jpeg);
        free(jpeg);
        return 0;
    }
    jpeg_create_decompress(jpeg);
    jpeg_mem_src(jpeg, source, length);
    jpeg_save_markers(jpeg, JPEG_COM, 64);
    jpeg_read_header(jpeg, TRUE);
    const char marker[] = "Intel(R) IPP JPEG encoder";
    int legacy = 0;
    for (jpeg_saved_marker_ptr comment = jpeg->marker_list; comment; comment = comment->next) {
        if (comment->marker == JPEG_COM && comment->data_length >= sizeof marker - 1 &&
            memcmp(comment->data, marker, sizeof marker - 1) == 0) legacy = 1;
    }
    int valid = legacy && jpeg->image_width == width && jpeg->image_height == height &&
                jpeg->data_precision == 8 && jpeg->num_components == 3 &&
                jpeg->saw_Adobe_marker && jpeg->Adobe_transform == 0;
    for (int i = 0; valid && i < 3; ++i) {
        valid = jpeg->comp_info[i].h_samp_factor == 1 && jpeg->comp_info[i].v_samp_factor == 1;
    }
    if (valid) {
        // The three stored components are fluorescence planes. Avoid a YCbCr transform.
        jpeg->jpeg_color_space = JCS_RGB;
        jpeg->out_color_space = JCS_RGB;
        jpeg_start_decompress(jpeg);
        while (jpeg->output_scanline < height) {
            JSAMPROW row = (uint8_t *)destination + (size_t)jpeg->output_scanline * width * 3;
            if (jpeg_read_scanlines(jpeg, &row, 1) != 1) jpeg_failure((j_common_ptr)jpeg);
        }
        jpeg_finish_decompress(jpeg);
    }
    jpeg_destroy_decompress(jpeg);
    free(jpeg);
    return valid;
}
